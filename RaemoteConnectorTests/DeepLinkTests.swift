import Testing
import Foundation
@testable import Raemote_Connector

struct DeepLinkTests {
    @Test func parsesAnOpenLink() throws {
        let url = URL(string: "raemote://open?node=abc&app=jellyfin&path=%2Fweb")!
        let link = try #require(DeepLink(url: url))
        #expect(link.nodeId == "abc")
        #expect(link.appName == "jellyfin")
        #expect(link.path == "/web")
    }

    @Test func rejectsUnrelatedOrEmptyURLs() {
        #expect(DeepLink(url: URL(string: "https://example.com")!) == nil)
        #expect(DeepLink(url: URL(string: "raemote://open")!) == nil)
        #expect(DeepLink(url: URL(string: "raemote://")!) == nil)
    }

    @Test func roundTripsWithWebShare() throws {
        let url = WebShare.raemoteURL(nodeId: "abc", appName: "jellyfin", path: "/web/a b")
        let link = try #require(DeepLink(url: url))
        #expect(link.nodeId == "abc")
        #expect(link.appName == "jellyfin")
        #expect(link.path == "/web/a b")
    }
}
