import CryptoKit
import Observation
import UIKit

/// Raster image formats `UIImage` can decode, recognized by their leading
/// bytes.
///
/// Deliberately excludes ICO and SVG: UIKit cannot render either, so accepting
/// them would show a broken image instead of the monogram fallback. A plain
/// `/favicon.ico` that is really a PNG (common) still passes.
nonisolated enum AppIconFormat {
    /// Whether `data` begins with a signature `UIImage` can decode
    /// (PNG, JPEG, GIF or WebP).
    static func isRenderableImage(_ data: Data) -> Bool {
        hasPrefix(data, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG
            || hasPrefix(data, [0xFF, 0xD8, 0xFF]) // JPEG
            || hasPrefix(data, Array("GIF87a".utf8))
            || hasPrefix(data, Array("GIF89a".utf8))
            || isWebP(data)
    }

    private static func hasPrefix(_ data: Data, _ signature: [UInt8]) -> Bool {
        data.count >= signature.count && Array(data.prefix(signature.count)) == signature
    }

    private static func isWebP(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let header = [UInt8](data.prefix(12))
        return Array(header[0..<4]) == Array("RIFF".utf8)
            && Array(header[8..<12]) == Array("WEBP".utf8)
    }
}

/// Caches each app's icon (its favicon) for the app list, the Running list and
/// the in-web-app switcher.
///
/// Keyed by **server node id + app name** (the NodeId-isolation rule): two
/// servers running an identically named app must never share an icon. Where the
/// icon lives (path and port) is registered from the server's catalog; when it
/// is unknown the client falls back to the conventional `/favicon.ico`.
///
/// Icons are small, rarely change and are cheap to re-fetch, so the store keeps
/// an in-memory image for instant paint, a JSON copy on disk for the next
/// launch, and a *negative* cache so a missing icon is not requested on every
/// row render. Concurrent loads of the same key are de-duplicated.
///
/// `@Observable` so a view can depend on an app's *location*: when a catalog
/// refresh finally supplies an icon path, the view re-evaluates and refetches.
@MainActor
@Observable
final class AppIconStore {
    static let shared = AppIconStore()

    /// Where an app's icon lives, from the server's catalog.
    private struct Descriptor: Equatable {
        var path: String?
        var port: Int
    }

    /// A cached icon plus the descriptor it was fetched for.
    private struct Entry {
        var image: UIImage
        var descriptor: Descriptor
        var fetchedAt: Date
    }

    /// A recent failure and when it may be retried.
    private struct Failure {
        var descriptor: Descriptor
        var retryAt: Date
    }

    /// `nonisolated`: encoded/decoded off the main actor by the disk tasks.
    private nonisolated struct DiskEntry: Codable, Sendable {
        var path: String?
        var port: Int
        var fetchedAt: Date
        var data: Data
    }

    private var descriptors: [WebAppSessionKey: Descriptor] = [:]
    private var memory: [WebAppSessionKey: Entry] = [:]
    private var failures: [WebAppSessionKey: Failure] = [:]
    private var inFlight: [WebAppSessionKey: Task<Void, Never>] = [:]

    private let directory: URL?
    private let ttl: TimeInterval
    private let failureBackoff: TimeInterval
    @ObservationIgnored private let clock: () -> Date

    init(
        directory: URL? = AppIconStore.defaultDirectory(),
        ttl: TimeInterval = 7 * 24 * 60 * 60,
        failureBackoff: TimeInterval = 60,
        clock: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.ttl = ttl
        self.failureBackoff = failureBackoff
        self.clock = clock
    }

    // MARK: - Catalog descriptors

    /// Remember where each of `nodeId`'s apps keeps its icon, from a fetched
    /// catalog. An app whose location changed (e.g. a new port) drops any
    /// cached image so it is re-fetched.
    func register(nodeId: String, apps: [AppInfo]) {
        for app in apps {
            let key = WebAppSessionKey(nodeId: nodeId, app: app.name)
            let descriptor = Descriptor(path: app.icon, port: app.port)
            guard descriptors[key] != descriptor else { continue }
            descriptors[key] = descriptor
            memory[key] = nil
            failures[key] = nil
        }
    }

    /// The icon path registered for an app, if any.
    func iconPath(nodeId: String, app: String) -> String? {
        descriptors[WebAppSessionKey(nodeId: nodeId, app: app)]?.path
    }

    /// The app's catalog port (used to version its cached icon), or `0`.
    func port(nodeId: String, app: String) -> Int {
        descriptors[WebAppSessionKey(nodeId: nodeId, app: app)]?.port ?? 0
    }

    /// A stable string describing where an app's icon lives. A view uses it as
    /// its task identity, so a catalog refresh that supplies (or moves) the
    /// icon path refetches instead of silently keeping a stale result.
    func descriptorID(nodeId: String, app: String) -> String {
        let descriptor = descriptor(for: WebAppSessionKey(nodeId: nodeId, app: app))
        return "\(descriptor.path ?? "-")|\(descriptor.port)"
    }

    // MARK: - Reading

    /// The already-loaded icon, when it is still valid for the app's current
    /// location. Memory only: never touches the disk, so it is safe to call
    /// during a view update.
    func cached(nodeId: String, app: String) -> UIImage? {
        let key = WebAppSessionKey(nodeId: nodeId, app: app)
        guard let entry = memory[key] else { return nil }
        guard entry.descriptor == descriptor(for: key) else { return nil }
        guard clock().timeIntervalSince(entry.fetchedAt) < ttl else { return nil }
        return entry.image
    }

    /// Load an app's icon, fetching through `fetch` (which receives the
    /// registered icon path, or `nil` for the `/favicon.ico` fallback) when it
    /// is not already cached. Returns `nil` while a failure is being backed
    /// off, or when the bytes are not a renderable image.
    func icon(
        nodeId: String,
        app: String,
        fetch: @escaping (String?) async throws -> Data
    ) async -> UIImage? {
        let key = WebAppSessionKey(nodeId: nodeId, app: app)
        let descriptor = descriptor(for: key)

        if let image = cached(nodeId: nodeId, app: app) { return image }
        if let failure = failures[key],
           failure.descriptor == descriptor,
           clock() < failure.retryAt {
            return nil
        }
        // De-duplicate: a second view for the same app waits for the first.
        if let task = inFlight[key] {
            await task.value
            return cached(nodeId: nodeId, app: app)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            // A copy from a previous launch needs no network.
            if await self.loadFromDisk(key: key, descriptor: descriptor) != nil { return }
            do {
                let data = try await fetch(descriptor.path)
                guard AppIconFormat.isRenderableImage(data), let image = UIImage(data: data) else {
                    self.recordFailure(key: key, descriptor: descriptor)
                    return
                }
                self.recordSuccess(key: key, descriptor: descriptor, image: image, data: data)
            } catch {
                self.recordFailure(key: key, descriptor: descriptor)
            }
        }
        inFlight[key] = task
        await task.value
        if inFlight[key] == task { inFlight[key] = nil }
        return cached(nodeId: nodeId, app: app)
    }

    // MARK: - Mutation

    private func recordSuccess(
        key: WebAppSessionKey,
        descriptor: Descriptor,
        image: UIImage,
        data: Data
    ) {
        let now = clock()
        memory[key] = Entry(image: image, descriptor: descriptor, fetchedAt: now)
        failures[key] = nil
        guard let url = diskURL(for: key) else { return }
        let entry = DiskEntry(
            path: descriptor.path,
            port: descriptor.port,
            fetchedAt: now,
            data: data
        )
        Task.detached(priority: .utility) {
            guard let encoded = try? JSONEncoder().encode(entry) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? encoded.write(to: url, options: .atomic)
        }
    }

    private func recordFailure(key: WebAppSessionKey, descriptor: Descriptor) {
        failures[key] = Failure(
            descriptor: descriptor,
            retryAt: clock().addingTimeInterval(failureBackoff)
        )
    }

    /// Forget one app's icon (also used by tests).
    func remove(nodeId: String, app: String) {
        let key = WebAppSessionKey(nodeId: nodeId, app: app)
        memory[key] = nil
        failures[key] = nil
        descriptors[key] = nil
        if let url = diskURL(for: key) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Forget every cached icon (also used by tests).
    func removeAll() {
        memory.removeAll()
        failures.removeAll()
        descriptors.removeAll()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Helpers

    private func descriptor(for key: WebAppSessionKey) -> Descriptor {
        descriptors[key] ?? Descriptor(path: nil, port: 0)
    }

    private func loadFromDisk(key: WebAppSessionKey, descriptor: Descriptor) async -> UIImage? {
        guard let url = diskURL(for: key) else { return nil }
        let entry: DiskEntry? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(DiskEntry.self, from: data)
        }.value
        guard let entry,
              entry.path == descriptor.path,
              entry.port == descriptor.port,
              clock().timeIntervalSince(entry.fetchedAt) < ttl,
              let image = UIImage(data: entry.data)
        else { return nil }
        memory[key] = Entry(image: image, descriptor: descriptor, fetchedAt: entry.fetchedAt)
        return image
    }

    /// One file per key, named by a stable digest of the identity string (the
    /// node id and app name may contain characters a filename cannot).
    private func diskURL(for key: WebAppSessionKey) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(key.id.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }

    /// `nonisolated` so it can be used as a default argument.
    private nonisolated static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("AppIcons", isDirectory: true)
    }
}
