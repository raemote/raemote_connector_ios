import Testing
import UIKit
@testable import Raemote_Connector

@MainActor
struct WebAppTabRackTests {

    /// Counts factory calls so reuse-vs-recreate is observable.
    private final class Counter {
        var n = 0
    }

    private func makeRack() -> (WebAppTabRack, Counter) {
        let counter = Counter()
        let rack = WebAppTabRack { _ in
            counter.n += 1
            return UIViewController()
        }
        return (rack, counter)
    }

    private func url(_ s: String = "http://127.0.0.1:9/") -> URL {
        URL(string: s)!
    }

    // MARK: - Tab lifecycle

    @Test func createsAtMostOneControllerPerSession() {
        let (rack, counter) = makeRack()
        let key = WebAppSessionKey(nodeId: "n", app: "a")

        let first = rack.controller(for: key, url: url())
        let second = rack.controller(for: key, url: url())

        #expect(first === second, "a session's tab is created once, then reused")
        #expect(counter.n == 1)
        #expect(rack.hasController(for: key))
        #expect(rack.controllerCount == 1)
    }

    @Test func identicalAppNamesOnTwoServersStayIsolated() {
        // The NodeId-isolation rule applied to tabs: `jellyfin` on two
        // servers is two pages that must never share a controller.
        let (rack, counter) = makeRack()
        let a = WebAppSessionKey(nodeId: "server-a", app: "jellyfin")
        let b = WebAppSessionKey(nodeId: "server-b", app: "jellyfin")

        let controllerA = rack.controller(for: a, url: url())
        let controllerB = rack.controller(for: b, url: url())

        #expect(controllerA !== controllerB)
        #expect(counter.n == 2)
        #expect(rack.controllerCount == 2)
    }

    @Test func destroyRemovesExactlyThatTab() {
        let (rack, _) = makeRack()
        let a = WebAppSessionKey(nodeId: "n", app: "one")
        let b = WebAppSessionKey(nodeId: "n", app: "two")
        _ = rack.controller(for: a, url: url())
        _ = rack.controller(for: b, url: url())

        rack.destroy(for: a)
        #expect(!rack.hasController(for: a))
        #expect(rack.hasController(for: b), "other tabs survive")
        #expect(rack.controllerCount == 1)

        // Destroying an unknown key is a harmless no-op.
        rack.destroy(for: WebAppSessionKey(nodeId: "n", app: "ghost"))
        #expect(rack.controllerCount == 1)
    }

    // MARK: - Mounting (window attachment + visibility)

    @Test func mountParentsTheRackAndShowsOnlyTheActiveTab() {
        let (rack, _) = makeRack()
        let a = WebAppSessionKey(nodeId: "n", app: "a")
        let b = WebAppSessionKey(nodeId: "n", app: "b")
        let controllerA = rack.controller(for: a, url: url())
        let controllerB = rack.controller(for: b, url: url())
        let host = UIViewController()

        rack.mount(into: host, activeKey: a, activeURL: nil, onFinish: {})
        #expect(rack.isMounted)
        #expect(!controllerA.view.isHidden)
        #expect(controllerB.view.isHidden)

        // Switching the active key flips visibility, not identity.
        rack.mount(into: host, activeKey: b, activeURL: nil, onFinish: {})
        #expect(controllerA.view.isHidden)
        #expect(!controllerB.view.isHidden)

        // Unmount detaches the container but keeps every page.
        rack.unmount()
        #expect(!rack.isMounted)
        #expect(rack.hasController(for: a))
        #expect(rack.hasController(for: b))
    }

    @Test func mountCreatesTheActiveTabFromItsURL() {
        // Self-heal path: a session whose page was destroyed (memory warning)
        // is presented again — mount creates it from the proxy URL.
        let (rack, counter) = makeRack()
        let a = WebAppSessionKey(nodeId: "n", app: "a")
        let host = UIViewController()

        rack.mount(into: host, activeKey: a, activeURL: url(), onFinish: {})

        #expect(rack.hasController(for: a))
        #expect(counter.n == 1)
        #expect(rack.isMounted)
    }

    // MARK: - Done routing

    @Test func doneRoutesOnlyForTheActiveTab() {
        let (rack, _) = makeRack()
        let a = WebAppSessionKey(nodeId: "n", app: "a")
        let b = WebAppSessionKey(nodeId: "n", app: "b")
        _ = rack.controller(for: a, url: url())
        _ = rack.controller(for: b, url: url())
        let host = UIViewController()
        var finished = 0

        rack.mount(into: host, activeKey: a, activeURL: nil, onFinish: { finished += 1 })

        // A stale callback from a background tab must never dismiss the screen.
        rack.tabDidFinish(b)
        #expect(finished == 0)
        rack.tabDidFinish(a)
        #expect(finished == 1)

        // After unmount (screen gone) nothing routes.
        rack.unmount()
        rack.tabDidFinish(a)
        #expect(finished == 1)
    }

    @Test func destroyAllEmptiesTheRack() {
        let (rack, _) = makeRack()
        for i in 0..<4 {
            _ = rack.controller(for: WebAppSessionKey(nodeId: "n", app: "app-\(i)"), url: url())
        }
        rack.destroyAll()
        #expect(rack.controllerCount == 0)
    }

    // MARK: - Layout (the "blank screen" repro)

    @Test func mountedTabFillsTheScreenAfterLayoutFromZeroBounds() {
        // SwiftUI may call `updateUIViewController` before it has sized the
        // representable's view, so the container and its children start at
        // .zero. If any of that depends on frame/autoresizing bookkeeping
        // computed from a zero base, the tab can stay 0×0 forever → blank.
        let (rack, _) = makeRack()
        let a = WebAppSessionKey(nodeId: "n", app: "a")
        let tab = rack.controller(for: a, url: url())

        let host = UIViewController()
        host.view.frame = .zero
        rack.mount(into: host, activeKey: a, activeURL: nil, onFinish: {})

        // …then SwiftUI lays the screen out.
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        #expect(!tab.view.isHidden)
        #expect(tab.view.frame == host.view.bounds,
                "tab is \(tab.view.frame), host is \(host.view.bounds)")
        #expect(tab.view.bounds.size.width > 0, "tab view must not be 0×0")
    }

    @Test func layoutSurvivesLaterContainerResizes() {
        let (rack, _) = makeRack()
        let a = WebAppSessionKey(nodeId: "n", app: "a")
        let tab = rack.controller(for: a, url: url())
        let host = UIViewController()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        rack.mount(into: host, activeKey: a, activeURL: nil, onFinish: {})

        // Rotation.
        host.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        #expect(tab.view.frame == host.view.bounds)
    }

    // MARK: - First-load state (the "stuck blank page" repro)

    @Test func firstLoadStateTracksThePageLifecycle() {
        let (rack, _) = makeRack()
        let key = WebAppSessionKey(nodeId: "n", app: "a")

        #expect(rack.loadState(for: key) == nil, "no page yet")
        _ = rack.controller(for: key, url: url())
        #expect(rack.loadState(for: key) == .loading, "a new tab starts loading")

        rack.tabDidLoad(key, didLoad: true)
        #expect(rack.loadState(for: key) == .loaded)

        // A destroyed tab must not leave a load state behind for a later tab.
        rack.destroy(for: key)
        #expect(rack.loadState(for: key) == nil)
    }

    @Test func retryAfterAFailedLoadDropsTheTabSoItCanRebuild() {
        let (rack, counter) = makeRack()
        let key = WebAppSessionKey(nodeId: "n", app: "a")
        _ = rack.controller(for: key, url: url())
        rack.tabDidLoad(key, didLoad: false)
        #expect(rack.loadState(for: key) == .failed)

        // SFVC has no reload(): "Try Again" drops the controller so the next
        // mount rebuilds it from the proxy URL.
        rack.retryLoad(for: key)
        #expect(rack.loadState(for: key) == nil)
        #expect(!rack.hasController(for: key))
        _ = rack.controller(for: key, url: url())
        #expect(rack.loadState(for: key) == .loading, "the rebuilt page waits again")
        #expect(counter.n == 2, "a fresh controller, not a stale one")
    }

    @Test func staleLoadCallbacksAreIgnored() {
        let (rack, _) = makeRack()
        let key = WebAppSessionKey(nodeId: "n", app: "a")
        rack.tabDidLoad(key, didLoad: true) // no tab exists (closed, evicted)
        #expect(rack.loadState(for: key) == nil)
    }

    // MARK: - Safari vs the connection gate

    @Test func gateCoversEveryStateWhereThePageIsNotReachable() {
        typealias P = AppPagePresentation
        func resolve(_ proxyUp: Bool, _ connectionUp: Bool, _ loadState: TabLoadState?) -> P {
            P.resolve(proxyUp: proxyUp, connectionUp: connectionUp, loadState: loadState)
        }
        // No proxy yet: nothing to show, whatever the connection says.
        #expect(resolve(false, true, .loaded) == .waiting)
        // Cold app while the connection is still coming up — the reported bug:
        // a Safari view used to be created here and sat blank and unswipeable.
        #expect(resolve(true, false, nil) == .waiting)
        // A load in flight with no connection behind it will never finish.
        #expect(resolve(true, false, .loading) == .waiting)
        // Connected and loading (or not yet created): Safari may take over.
        #expect(resolve(true, true, nil) == .showing)
        #expect(resolve(true, true, .loading) == .showing)
        // A finished page keeps showing — warm tabs outlive the connection.
        #expect(resolve(true, false, .loaded) == .showing)
        // A failed first load asks for a retry rather than a blank page.
        #expect(resolve(true, true, .failed) == .failed)
    }
}
