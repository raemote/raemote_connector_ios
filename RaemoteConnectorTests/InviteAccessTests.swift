import Foundation
import Testing
@testable import Raemote_Connector

@MainActor
struct InviteAccessTests {
    // MARK: - DeviceAccess decoding (server `scope_json` shapes)

    @Test func decodesTheAllShape() throws {
        let data = Data(#"{"all":true}"#.utf8)
        #expect(try JSONDecoder().decode(DeviceAccess.self, from: data) == .all)
    }

    @Test func decodesThePortsShape() throws {
        let data = Data(#"{"all":false,"ports":[8080,3000]}"#.utf8)
        #expect(try JSONDecoder().decode(DeviceAccess.self, from: data) == .ports([3000, 8080]))
    }

    @Test func failsClosedWhenPortsAreMissing() throws {
        // `all: false` with no list = grant nothing, never "grant everything".
        let data = Data(#"{"all":false}"#.utf8)
        #expect(try JSONDecoder().decode(DeviceAccess.self, from: data) == .ports([]))
    }

    @Test func infoWithoutAccessFieldDecodesToNil() throws {
        let data = Data(#"{"name":"studio","version":"0.2.0"}"#.utf8)
        struct Info: Decodable { let access: DeviceAccess? }
        #expect(try JSONDecoder().decode(Info.self, from: data).access == nil)
    }

    @Test func malformedAccessFieldIsTreatedAsUnreported() throws {
        // Mirrors `fetchDeviceAccess`: any unreadable `access` collapses to
        // "not reported" (nil → inherit-only), never to a throw and never
        // to "all".
        struct Info: Decodable { let access: DeviceAccess? }
        let shapes = [
            #"{"access":"everything"}"#,
            #"{"access":{"all":"yes"}}"#,
            #"{"access":{"all":false,"ports":["x"]}}"#,
            #"{}"#,
        ]
        for json in shapes {
            let decoded = try? JSONDecoder().decode(Info.self, from: Data(json.utf8))
            #expect((decoded?.access ?? nil) == nil, "expected nil for \(json)")
        }
    }

    // MARK: - Selection → granted ports

    @Test func grantedPortsIsTheSortedUnionOfCheckedApps() {
        let apps = [
            AppInfo(name: "a", path: "/", port: 8080),
            AppInfo(name: "b", path: "/", port: 3000),
            AppInfo(name: "c", path: "/", port: 8080),
        ]
        #expect(InviteAccess.grantedPorts(apps: apps, selected: ["a"]) == [8080])
        #expect(InviteAccess.grantedPorts(apps: apps, selected: ["a", "c", "b"]) == [3000, 8080])
        #expect(InviteAccess.grantedPorts(apps: apps, selected: []) == [])
        #expect(InviteAccess.grantedPorts(apps: apps, selected: ["unknown"]) == [])
    }

    @Test func appsSharingAGrantedPortAreDisclosed() {
        let apps = [
            AppInfo(name: "checked", path: "/", port: 8080),
            AppInfo(name: "sharesPort", path: "/", port: 8080),
            AppInfo(name: "otherPort", path: "/", port: 3000),
        ]
        let along = InviteAccess.alsoGrantedApps(apps: apps, selected: ["checked"])
        #expect(along.map(\.name) == ["sharesPort"])
    }

    @Test func malformedPortsAreSkipped() {
        let apps = [AppInfo(name: "bad", path: "/", port: 70_000)]
        #expect(InviteAccess.grantedPorts(apps: apps, selected: ["bad"]) == [])
        #expect(InviteAccess.alsoGrantedApps(apps: apps, selected: []).isEmpty)
    }

    // MARK: - Selectable apps vs. the reported scope

    @Test func selectionNeverExceedsTheReportedScope() {
        let apps = [
            AppInfo(name: "on3000", path: "/", port: 3000),
            AppInfo(name: "on9000", path: "/", port: 9000),
        ]
        let narrow: DeviceAccess = .ports([3000])
        #expect(InviteAccess.selectableApps(access: narrow, apps: apps).map(\.name) == ["on3000"])
        // `all` and unreported access show everything (unreported never
        // reaches the picker — it's gated by shouldOfferChoice).
        #expect(InviteAccess.selectableApps(access: .all, apps: apps).count == 2)
        #expect(InviteAccess.selectableApps(access: nil, apps: apps).count == 2)
    }

    // MARK: - Whether the picker is worth showing

    @Test func choiceMatrix() {
        let one = [AppInfo(name: "a", path: "/", port: 3000)]
        let two = one + [AppInfo(name: "b", path: "/", port: 8080)]

        // Older server: no reported scope → inherit-only (a narrowed invite
        // would be silently ignored, so we must not offer one).
        #expect(!InviteAccess.shouldOfferChoice(access: nil, apps: two))
        // `all` with nothing to pick.
        #expect(!InviteAccess.shouldOfferChoice(access: .all, apps: []))
        // `all` with apps: inherit-everything vs. just-these is a real choice.
        #expect(InviteAccess.shouldOfferChoice(access: .all, apps: one))
        // One port: "same as this device" and "only this app" are identical.
        #expect(!InviteAccess.shouldOfferChoice(access: .ports([3000]), apps: one))
        // A restricted scope with nothing visible to offer.
        #expect(!InviteAccess.shouldOfferChoice(access: .ports([3000]), apps: []))
        // Two ports, one visible app: inherit also opens the other port —
        // a real choice.
        #expect(InviteAccess.shouldOfferChoice(access: .ports([3000, 8080]), apps: one))
        // Two ports, but no visible app is on either (stale catalog):
        // nothing to show.
        let offScope = [AppInfo(name: "x", path: "/", port: 9000)]
        #expect(!InviteAccess.shouldOfferChoice(access: .ports([3000, 8080]), apps: offScope))
    }

    // MARK: - Request body / error copy

    @Test func requestBodyIsCompactAndSorted() throws {
        let body = try InviteAccess.requestBody(ports: [8080, 3000])
        #expect(String(decoding: body, as: UTF8.self) == #"{"ports":[3000,8080]}"#)
    }

    @Test func beyondGrantGetsAFriendlyMessage() {
        let refused = IrohError.httpError(400, "beyond_grant")
        let message = InviteAccess.mintErrorMessage(refused)
        #expect(message.contains("more than this device has"))
        #expect(message.contains("Refresh Apps"))

        let other = IrohError.httpError(400, "bad_request")
        #expect(InviteAccess.mintErrorMessage(other) == other.localizedDescription)
        let network = IrohError.connectionFailed("timeout")
        #expect(InviteAccess.mintErrorMessage(network) == network.localizedDescription)
    }
}
