import Testing
@testable import Raemote_Connector

/// The monitor's state is per server node. This is the NodeId-isolation rule:
/// a connected server's state must never be shown for a different server —
/// which is exactly what happened when `state` was one shared value (open the
/// offline server's detail after the online one and it read "Connected").
@MainActor
struct IrohConnectionMonitorTests {
    @Test func stateIsIsolatedPerServer() {
        let monitor = IrohConnectionMonitor()

        monitor.setState(.connected, for: "server-a")
        #expect(monitor.state(for: "server-a") == .connected)
        // The other server is untouched — this is the leak that was fixed.
        #expect(monitor.state(for: "server-b") == .unknown)

        monitor.setState(.disconnected("offline"), for: "server-b")
        #expect(monitor.state(for: "server-b") == .disconnected("offline"))
        #expect(monitor.state(for: "server-a") == .connected)
    }

    @Test func unknownServerHasNoState() {
        let monitor = IrohConnectionMonitor()
        #expect(monitor.state(for: "never-seen") == .unknown)
    }

    @Test func resetForgetsEveryServer() {
        let monitor = IrohConnectionMonitor()
        monitor.setState(.connected, for: "server-a")
        monitor.setState(.connecting, for: "server-b")

        monitor.reset()

        #expect(monitor.state(for: "server-a") == .unknown)
        #expect(monitor.state(for: "server-b") == .unknown)
    }
}
