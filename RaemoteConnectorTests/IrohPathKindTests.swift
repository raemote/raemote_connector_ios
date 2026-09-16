import Testing
import Foundation
@testable import Raemote_Connector

struct IrohPathKindTests {
    private func path(selected: Bool = false, ip: Bool, relay: Bool) -> IrohPathFacts {
        IrohPathFacts(isSelected: selected, isIp: ip, isRelay: relay)
    }

    @Test func nothingOpenIsUnknown() {
        #expect(IrohPathKind(paths: []) == .unknown)
    }

    @Test func theSelectedPathDecides() {
        // A direct path carries the data even while the relay stays open as a
        // fallback (iroh keeps it around, so this is the common steady state).
        #expect(IrohPathKind(paths: [
            path(ip: false, relay: true),
            path(selected: true, ip: true, relay: false),
        ]) == .direct)

        // Before hole-punching succeeds, the relay is what is selected.
        #expect(IrohPathKind(paths: [
            path(selected: true, ip: false, relay: true),
            path(ip: true, relay: false),
        ]) == .relayed)
    }

    @Test func fallsBackWhenNothingIsSelectedYet() {
        #expect(IrohPathKind(paths: [path(ip: true, relay: false)]) == .direct)
        #expect(IrohPathKind(paths: [path(ip: false, relay: true)]) == .relayed)
        #expect(IrohPathKind(paths: [
            path(ip: false, relay: true),
            path(ip: true, relay: false),
        ]) == .direct)
    }

    @Test func aPathForAnotherServerIsNotReported() {
        let state = IrohPathState(nodeId: "server-a", kind: .direct)
        #expect(state.kind(for: "server-a") == .direct)
        #expect(state.kind(for: "server-b") == nil)
    }
}
