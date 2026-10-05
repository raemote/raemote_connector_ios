import Testing
@testable import Raemote_Connector

/// The hidden diagnosis buffer: per-server filtering (NodeId-isolation), the
/// ring cap, export, and the monitor's transition capture.
@MainActor
struct ConnectionLogTests {
    @Test func filtersByNodeAndKeepsGlobalEntries() {
        let log = ConnectionLog(capacity: 50)
        log.append("for a", nodeId: "node-a")
        log.append("for b", nodeId: "node-b")
        log.append("endpoint-wide")

        // Server A sees itself plus the endpoint-wide events — never B's.
        #expect(log.entries(for: "node-a").map(\.message) == ["for a", "endpoint-wide"])
        #expect(log.entries(for: "node-b").map(\.message) == ["for b", "endpoint-wide"])
        #expect(log.entries(for: "node-c").map(\.message) == ["endpoint-wide"])
    }

    @Test func dropsOldestEntriesBeyondCapacity() {
        let log = ConnectionLog(capacity: 10)
        for i in 1...25 {
            log.append("event \(i)")
        }

        #expect(log.entries.count == 10)
        #expect(log.entries.first?.message == "event 16")
        #expect(log.entries.last?.message == "event 25")
    }

    @Test func clearEmptiesTheBuffer() {
        let log = ConnectionLog(capacity: 10)
        log.append("something", nodeId: "node-a")
        log.clear()

        #expect(log.entries.isEmpty)
        #expect(log.entries(for: "node-a").isEmpty)
    }

    @Test func exportIsChronologicalAndScoped() {
        let log = ConnectionLog(capacity: 50)
        log.append("first event", nodeId: "node-a")
        log.append("global event")
        log.append("other server", nodeId: "node-b")

        let text = log.exportText(for: "node-a")
        let lines = text.split(separator: "\n")

        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("[node-a] first event"))
        #expect(lines[1].hasSuffix("[all] global event"))
        // The other server's event must never appear in A's export.
        #expect(!text.contains("other server"))
    }

    @Test func monitorLogsStateTransitionsOnlyOnChange() {
        let log = ConnectionLog(capacity: 50)
        let monitor = IrohConnectionMonitor(log: log)

        monitor.setState(.connecting, for: "node-a")
        monitor.setState(.connecting, for: "node-a") // no change → not logged
        monitor.setState(.connected, for: "node-a")
        monitor.setState(.connected, for: "node-b")

        #expect(log.entries.count == 3)
        let forA = log.entries(for: "node-a").map(\.message)
        #expect(forA == [
            "state: unknown → connecting",
            "state: connecting → connected",
        ])
        // B's transition is not visible in A's slice (global entries aside).
        #expect(log.entries(for: "node-a").count == 2)
        #expect(log.entries(for: "node-b").contains { $0.message.contains("connected") })
    }
}
