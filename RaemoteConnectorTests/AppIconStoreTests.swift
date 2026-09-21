import Foundation
import Testing
import UIKit

@testable import Raemote_Connector

/// Records what the store asked the network for, so a test can assert the
/// fetch happened (or did not).
private actor FetchLog {
    private(set) var paths: [String?] = []
    private(set) var count = 0

    func record(_ path: String?) {
        paths.append(path)
        count += 1
    }
}

@MainActor
struct AppIconStoreTests {

    // MARK: - Fixtures

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIconStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePNG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return renderer.pngData { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func app(_ name: String, icon: String? = nil, port: Int = 3000) -> AppInfo {
        AppInfo(name: name, path: "/app/\(name)", port: port, icon: icon)
    }

    // MARK: - Format sniffing

    @Test func acceptsRasterFormatsAndRejectsWhatUIKitCannotDecode() {
        let png = makePNG()
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
            .jpegData(withCompressionQuality: 0.8) { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }

        #expect(AppIconFormat.isRenderableImage(png))
        #expect(AppIconFormat.isRenderableImage(jpeg))
        #expect(AppIconFormat.isRenderableImage(Data("GIF87a".utf8) + Data(repeating: 0, count: 8)))
        #expect(AppIconFormat.isRenderableImage(Data("GIF89a".utf8) + Data(repeating: 0, count: 8)))

        var webp = Data("RIFF".utf8)
        webp.append(Data(repeating: 0, count: 4))
        webp.append(Data("WEBP".utf8))
        #expect(AppIconFormat.isRenderableImage(webp))

        // Rejected: ICO and SVG cannot be rendered by UIImage, and an HTML
        // error page must never be treated as an icon.
        #expect(!AppIconFormat.isRenderableImage(Data([0x00, 0x00, 0x01, 0x00])))
        #expect(!AppIconFormat.isRenderableImage(Data("<svg xmlns=\"http://www.w3.org/2000/svg\">".utf8)))
        #expect(!AppIconFormat.isRenderableImage(Data("<html><body>404</body></html>".utf8)))
        #expect(!AppIconFormat.isRenderableImage(Data()))
    }

    // MARK: - Isolation

    @Test func identicalAppNamesOnTwoServersStayIsolated() async {
        let store = AppIconStore(directory: makeTempDirectory())
        store.register(nodeId: "server-a", apps: [app("jellyfin", icon: "/a.png")])
        store.register(nodeId: "server-b", apps: [app("jellyfin", icon: "/b.png")])

        let log = FetchLog()
        let png = makePNG()
        _ = await store.icon(nodeId: "server-a", app: "jellyfin") { path in
            await log.record(path)
            return png
        }
        _ = await store.icon(nodeId: "server-b", app: "jellyfin") { path in
            await log.record(path)
            return png
        }

        // Each server's own icon path was requested — never the other's.
        #expect(await log.paths == ["/a.png", "/b.png"])
        #expect(store.cached(nodeId: "server-a", app: "jellyfin") != nil)
        #expect(store.cached(nodeId: "server-b", app: "jellyfin") != nil)

        // Forgetting one server's icon leaves the other server's alone.
        store.remove(nodeId: "server-a", app: "jellyfin")
        #expect(store.cached(nodeId: "server-a", app: "jellyfin") == nil)
        #expect(store.cached(nodeId: "server-b", app: "jellyfin") != nil)
    }

    // MARK: - Descriptor handling

    @Test func anAppWithoutADeclaredIconFallsBackToTheDefaultPath() async {
        let store = AppIconStore(directory: makeTempDirectory())
        store.register(nodeId: "n", apps: [app("manual-app")])

        let log = FetchLog()
        _ = await store.icon(nodeId: "n", app: "manual-app") { path in
            await log.record(path)
            return makePNG()
        }

        // `nil` tells `IrohService.fetchIcon` to use `/favicon.ico`.
        #expect(await log.paths == [nil])
    }

    @Test func aChangedPortInvalidatesTheCachedIcon() async {
        let store = AppIconStore(directory: makeTempDirectory())
        store.register(nodeId: "n", apps: [app("app", icon: "/i.png", port: 3000)])
        _ = await store.icon(nodeId: "n", app: "app") { _ in makePNG() }
        #expect(store.cached(nodeId: "n", app: "app") != nil)

        // The app restarted on another port: the cached image is stale.
        store.register(nodeId: "n", apps: [app("app", icon: "/i.png", port: 4000)])
        #expect(store.cached(nodeId: "n", app: "app") == nil)
    }

    // MARK: - De-duplication and negative caching

    @Test func concurrentLoadsOfOneAppFetchOnce() async {
        let store = AppIconStore(directory: makeTempDirectory())
        store.register(nodeId: "n", apps: [app("app", icon: "/i.png")])

        let log = FetchLog()
        let png = makePNG()
        async let first = store.icon(nodeId: "n", app: "app") { path in
            await log.record(path)
            try? await Task.sleep(for: .milliseconds(20))
            return png
        }
        async let second = store.icon(nodeId: "n", app: "app") { path in
            await log.record(path)
            return png
        }
        let results = await [first, second]

        #expect(results.allSatisfy { $0 != nil })
        #expect(await log.count == 1, "the second caller joins the first fetch")
    }

    @Test func aFailureIsNotRetriedImmediately() async {
        let store = AppIconStore(directory: makeTempDirectory())
        store.register(nodeId: "n", apps: [app("app", icon: "/i.png")])

        struct Boom: Error {}
        let log = FetchLog()
        for _ in 0..<3 {
            let image = await store.icon(nodeId: "n", app: "app") { path in
                await log.record(path)
                throw Boom()
            }
            #expect(image == nil)
        }

        #expect(await log.count == 1, "failures are backed off, not hammered")
        #expect(store.cached(nodeId: "n", app: "app") == nil)
    }

    // MARK: - Descriptor changes

    @Test func aNewlyReportedIconPathIsRefetchedAfterAnEarlierFailure() async {
        // The app is known but its icon path is not (an older server, or a
        // catalog fetched before discovery learned about icons): the client
        // falls back to /favicon.ico and that 404s.
        let store = AppIconStore(directory: makeTempDirectory())
        store.register(nodeId: "n", apps: [app("app")])

        let log = FetchLog()
        _ = await store.icon(nodeId: "n", app: "app") { path in
            await log.record(path)
            return Data("<html><body>404</body></html>".utf8)
        }
        #expect(await log.paths == [nil])
        #expect(store.cached(nodeId: "n", app: "app") == nil)

        // The catalog now reports a real icon path. The descriptor changed, so
        // the negative cache is cleared and the icon is fetched again — this is
        // what lets a row recover instead of showing the monogram forever.
        store.register(nodeId: "n", apps: [app("app", icon: "/icon.png")])
        let image = await store.icon(nodeId: "n", app: "app") { path in
            await log.record(path)
            return makePNG()
        }

        #expect(image != nil)
        #expect(await log.paths == [nil, "/icon.png"])
        #expect(store.cached(nodeId: "n", app: "app") != nil)
    }

    @Test func theDescriptorIdentityChangesWithTheIconPathAndPort() {
        let store = AppIconStore(directory: makeTempDirectory())
        store.register(nodeId: "n", apps: [app("app", icon: "/a.png", port: 3000)])
        let first = store.descriptorID(nodeId: "n", app: "app")

        store.register(nodeId: "n", apps: [app("app", icon: "/b.png", port: 3000)])
        #expect(store.descriptorID(nodeId: "n", app: "app") != first)

        store.register(nodeId: "n", apps: [app("app", icon: "/b.png", port: 4000)])
        #expect(store.descriptorID(nodeId: "n", app: "app") != first)
    }

    @Test func nonImageBytesAreRejectedAndNegativelyCached() async {        let store = AppIconStore(directory: makeTempDirectory())
        store.register(nodeId: "n", apps: [app("app", icon: "/i.png")])

        let log = FetchLog()
        let image = await store.icon(nodeId: "n", app: "app") { path in
            await log.record(path)
            return Data("<html><body>not an icon</body></html>".utf8)
        }

        #expect(image == nil)
        #expect(store.cached(nodeId: "n", app: "app") == nil)
        #expect(await log.count == 1)
    }

    // MARK: - Disk persistence

    @Test func aCachedIconSurvivesRelaunchViaDisk() async {
        let directory = makeTempDirectory()
        let png = makePNG()

        let first = AppIconStore(directory: directory)
        first.register(nodeId: "n", apps: [app("app", icon: "/i.png")])
        #expect(await first.icon(nodeId: "n", app: "app") { _ in png } != nil)
        // Let the detached disk write land.
        try? await Task.sleep(for: .milliseconds(100))

        // A fresh store (as after a relaunch) finds it on disk, no network.
        let second = AppIconStore(directory: directory)
        second.register(nodeId: "n", apps: [app("app", icon: "/i.png")])
        let log = FetchLog()
        let image = await second.icon(nodeId: "n", app: "app") { path in
            await log.record(path)
            return png
        }

        #expect(image != nil)
        #expect(await log.count == 0, "served from disk, not the network")
    }
}
