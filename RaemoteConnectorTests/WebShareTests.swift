import Testing
import Foundation
@testable import Raemote_Connector

struct WebShareTests {
    @Test func classifiesPagesAndFiles() {
        #expect(WebShare.contentKind(mimeType: "text/html") == .webPage)
        #expect(WebShare.contentKind(mimeType: "text/html; charset=utf-8") == .webPage)
        #expect(WebShare.contentKind(mimeType: "application/xhtml+xml") == .webPage)
        #expect(WebShare.contentKind(mimeType: nil) == .webPage)
        #expect(WebShare.contentKind(mimeType: "") == .webPage)

        #expect(WebShare.contentKind(mimeType: "application/pdf") == .file)
        #expect(WebShare.contentKind(mimeType: "video/mp4") == .file)
        #expect(WebShare.contentKind(mimeType: "text/markdown") == .file)
        #expect(WebShare.contentKind(mimeType: "application/octet-stream") == .file)
    }

    @Test func derivesExtensionsFromMime() {
        #expect(WebShare.filenameExtension(forMimeType: "application/pdf") == "pdf")
        #expect(WebShare.filenameExtension(forMimeType: "image/png") == "png")
        #expect(WebShare.filenameExtension(forMimeType: "application/x-not-real") == nil)
        #expect(WebShare.filenameExtension(forMimeType: nil) == nil)
    }

    @Test func sanitizesFileNames() {
        #expect(WebShare.sanitize("My Report") == "My-Report")
        #expect(WebShare.sanitize("a/b:c\\d") == "a-b-c-d")
        #expect(WebShare.sanitize("   ") == "download")
        #expect(WebShare.sanitize(String(repeating: "x", count: 100)).count == 64)
    }

    @Test func pageFilenameUsesTitleThenAppName() {
        #expect(WebShare.pageFilename(title: "Home", appName: "jellyfin") == "Home.pdf")
        #expect(WebShare.pageFilename(title: nil, appName: "jellyfin") == "jellyfin.pdf")
        #expect(WebShare.pageFilename(title: "", appName: "jellyfin") == "jellyfin.pdf")
    }

    @Test func fileFilenameKeepsUrlExtension() {
        let url = URL(string: "http://127.0.0.1:9000/app/report.pdf")!
        #expect(WebShare.fileFilename(url: url, appName: "jellyfin", mimeType: "application/pdf") == "report.pdf")
    }

    @Test func fileFilenameFallsBackToMimeExtension() {
        let url = URL(string: "http://127.0.0.1:9000/app/download")!
        #expect(WebShare.fileFilename(url: url, appName: "jellyfin", mimeType: "application/pdf") == "download.pdf")
    }

    @Test func fileFilenameFallsBackToAppName() {
        let url = URL(string: "http://127.0.0.1:9000/")!
        #expect(WebShare.fileFilename(url: url, appName: "jellyfin", mimeType: nil) == "jellyfin")
    }

    @Test func raemoteURLRoundTripsQuery() throws {
        let url = WebShare.raemoteURL(nodeId: "abc", appName: "jellyfin", path: "/server/a b")
        #expect(url.scheme == "raemote")
        #expect(url.host == "open")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        #expect(items["node"] == "abc")
        #expect(items["app"] == "jellyfin")
        #expect(items["path"] == "/server/a b")
    }
}
