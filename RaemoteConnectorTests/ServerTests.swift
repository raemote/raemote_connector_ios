import Testing
import Foundation
@testable import Raemote_Connector

struct ServerTests {
    @Test func displayNamePrefersAliasThenReportedThenId() {
        var server = Server(nodeId: "abcdef0123456789", name: "  ", reportedName: nil)
        #expect(server.displayName == "Server abcdef01")

        server.reportedName = "mac-mini"
        #expect(server.displayName == "mac-mini")

        server.name = "  My Mac  "
        #expect(server.displayName == "My Mac")

        // A blank alias falls back to the reported name.
        server.name = "   "
        #expect(server.displayName == "mac-mini")
    }

    @Test func decodesServersSavedBeforeReportedNameExisted() throws {
        // Shape written by older builds: no `reportedName` key.
        let json = #"[{"id":"11111111-1111-1111-1111-111111111111","nodeId":"abcdef0123456789","name":"Server abcdef01","apps":[]}]"#
        let servers = try JSONDecoder().decode([Server].self, from: Data(json.utf8))
        #expect(servers.count == 1)
        #expect(servers[0].reportedName == nil)
        #expect(servers[0].displayName == "Server abcdef01")
    }

    @Test func roundTripsThroughJSON() throws {
        let original = Server(
            nodeId: "abcdef0123456789",
            name: "Alias",
            reportedName: "mac-mini",
            apps: []
        )
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([Server].self, from: data)
        #expect(decoded[0].name == "Alias")
        #expect(decoded[0].reportedName == "mac-mini")
        #expect(decoded[0].displayName == "Alias")
    }
}
