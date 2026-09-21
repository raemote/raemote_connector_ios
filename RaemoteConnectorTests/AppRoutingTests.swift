import Foundation
import Testing

@testable import Raemote_Connector

/// The root navigation rules behind app presentation and the in-app switcher.
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
        // Already hosting: never a duplicate destination.
        let hosting: [Route] = [.server(detail), .app]
        #expect(ContentView.pathAfterOpen(from: hosting) == hosting)
    }

    @Test func switchingCollapsesToASingleHostSoBackReturnsToList() {
        let detail = Server(nodeId: "a", apps: [])

        // Switching from a detail-pushed app collapses to the host: the back
        // gesture then returns to the main list, as specified.
        #expect(
            ContentView.pathAfterSwitch(from: [.server(detail), .app])
                == [.app]
        )
        #expect(ContentView.pathAfterSwitch(from: []) == [.app])
    }

    @Test func switchingWhileAlreadyHostingDoesNotTouchThePath() {
        // The common case (switch from the strip): identical path, so there is
        // no navigation churn at all — only `activeKey` changes.
        let hosting: [Route] = [.app]
        #expect(ContentView.pathAfterSwitch(from: hosting) == hosting)
    }
}
