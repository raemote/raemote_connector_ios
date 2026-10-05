import Foundation
import Testing

@testable import Raemote_Connector

/// The root navigation rules behind app presentation.
@MainActor
struct AppRoutingTests {

    @Test func openingAnAppPushesExactlyOneHost() {
        let detail = Server(nodeId: "a", apps: [])

        // From the main list.
        #expect(ContentView.pathAfterOpen(from: []) == [.app])
        // From a server detail: the host sits on top, so back returns there.
        #expect(
            ContentView.pathAfterOpen(from: [.server(detail)])
                == [.server(detail), .app]
        )
        // Already hosting (e.g. a deep link opens another app): never a
        // duplicate destination — only `activeKey` changes.
        let hosting: [Route] = [.server(detail), .app]
        #expect(ContentView.pathAfterOpen(from: hosting) == hosting)
    }
}
