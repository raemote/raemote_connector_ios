import Testing
import Foundation
import UIKit
@testable import Raemote_Connector

@MainActor
struct WebAppSessionManagerTests {

    private func makeManager(rack: WebAppTabRack? = nil) -> WebAppSessionManager {
        // The registry tests never start a proxy; an unconnected service is
        // fine for building the manager. The rack's factory is only invoked
        // when a test explicitly creates a warm page (with a stub rack).
        WebAppSessionManager(service: IrohService(monitor: IrohConnectionMonitor()), rack: rack)
    }

    private func stubRack() -> WebAppTabRack {
        WebAppTabRack { _ in UIViewController() }
    }

    @Test func sameAppOnTwoServersIsTwoSessions() {
        let manager = makeManager()
        let a = manager.open(nodeId: "server-a", app: "jellyfin")
        let b = manager.open(nodeId: "server-b", app: "jellyfin")

        // The NodeId-isolation rule: identical app names on two servers are
        // two distinct sessions; the registry never conflates them.
        #expect(a.key != b.key)
        #expect(manager.runningCount == 2)

        // Re-opening the same key returns the same session, never a duplicate.
        let again = manager.open(nodeId: "server-a", app: "jellyfin")
        #expect(again === a)
        #expect(manager.runningCount == 2)
    }

    @Test func openAndCloseRoundTrip() {
        let manager = makeManager()
        let session = manager.open(nodeId: "n", app: "app1")

        #expect(manager.isRunning(nodeId: "n", app: "app1"))
        manager.close(session.key)
        #expect(!manager.isRunning(WebAppSessionKey(nodeId: "n", app: "app1")))
        #expect(manager.runningCount == 0)

        // Closing an unknown key is a harmless no-op.
        #expect(!manager.close(nodeId: "n", app: "app1"))
    }

    @Test func evictsTheLeastRecentlyUsedNotTheOldestOpened() throws {
        let manager = makeManager()
        var keys: [WebAppSessionKey] = []
        for i in 0..<WebAppSessionManager.maxSessions {
            let key = WebAppSessionKey(nodeId: "node", app: "app-\(i)")
            _ = manager.open(nodeId: key.nodeId, app: key.app)
            // Deterministic LRU ordering: app-0 was used least recently.
            manager.session(for: key)?.lastActivated = Date(timeIntervalSince1970: TimeInterval(i + 1))
            keys.append(key)
        }
        #expect(manager.runningCount == WebAppSessionManager.maxSessions)

        // Use the *first-opened* app again. It is now the most recently used,
        // so the next open must evict app-1 — not app-0, which insertion order
        // (the old behaviour) would have picked.
        manager.session(for: keys[0])?.lastActivated = Date(timeIntervalSince1970: 1000)

        let extra = manager.open(nodeId: "node", app: "app-extra")
        #expect(manager.runningCount == WebAppSessionManager.maxSessions)
        #expect(manager.isRunning(keys[0]), "recently used session is kept")
        #expect(!manager.isRunning(keys[1]), "least recently used session is evicted")
        #expect(manager.isRunning(extra.key))
    }

    @Test func evictionNeverTakesTheActiveSession() throws {
        let manager = makeManager()
        let anchored = WebAppSessionKey(nodeId: "node", app: "anchored")
        _ = manager.open(nodeId: anchored.nodeId, app: anchored.app)
        manager.activate(anchored)
        // Older than everything else, yet still not a candidate: the presented
        // session is the one that must not be torn down.
        manager.session(for: anchored)?.lastActivated = Date(timeIntervalSince1970: 0)

        for i in 0..<WebAppSessionManager.maxSessions {
            _ = manager.open(nodeId: "node2", app: "next-\(i)")
            #expect(manager.isRunning(anchored), "active session survives eviction")
        }
        #expect(manager.runningCount == WebAppSessionManager.maxSessions)
    }

    @Test func closeClearsActiveKeyWhenItIsTheClosedOne() {
        let manager = makeManager()
        let key = WebAppSessionKey(nodeId: "n", app: "a")
        _ = manager.open(nodeId: key.nodeId, app: key.app)
        manager.activate(key)
        #expect(manager.isActive(key))

        manager.close(key)
        #expect(manager.activeKey == nil)
        #expect(!manager.isActive(key))
    }

    @Test func deletingAServerClosesOnlyThatServersSessions() {
        let manager = makeManager()
        _ = manager.open(nodeId: "server-a", app: "one")
        _ = manager.open(nodeId: "server-a", app: "two")
        _ = manager.open(nodeId: "server-b", app: "one")

        manager.closeRunningSessions(nodeId: "server-a")

        #expect(!manager.isRunning(nodeId: "server-a", app: "one"))
        #expect(!manager.isRunning(nodeId: "server-a", app: "two"))
        #expect(manager.isRunning(nodeId: "server-b", app: "one"))
        #expect(manager.runningCount == 1)
        #expect(manager.closeRunningSessions(nodeId: "server-a").isEmpty)
    }

    @Test func ensureProxyLeavesNothingBehindWhenSessionClosesMidStart() async throws {
        // The classic async-lifecycle race: the session can be closed (or LRU
        // evicted) while the listener's `start()` is in flight. The
        // post-start identity fence must refuse to install the proxy, so a
        // session that is no longer in the registry can never own a live
        // NWListener.
        let manager = makeManager()
        let key = WebAppSessionKey(nodeId: "n", app: "app1")
        let session = manager.open(nodeId: key.nodeId, app: key.app)

        let start = Task { try await manager.ensureProxy(for: session, launchPath: nil) }
        // Let the listener setup begin, then tear the session down.
        try? await Task.sleep(for: .milliseconds(30))
        manager.close(key)
        let outcome = await start.result

        // Either path is correct; BOTH must leave nothing dangling.
        switch outcome {
        case .failure:
            // Fence refused the install (session closed mid-start): fine.
            break
        case .success(let url):
            // The start won the race; close() immediately after must still
            // tear everything down: no URL, no listener, no tracked proxy.
            manager.close(key)
            #expect(session.proxyURL == nil)
            #expect(!manager.isRunning(key))
            _ = url
        }
        #expect(manager.session(for: key) == nil)
    }

    // MARK: - Warm tab rack lifecycle

    @Test func closeDestroysTheWarmPage() {
        let rack = stubRack()
        let manager = makeManager(rack: rack)
        let key = WebAppSessionKey(nodeId: "n", app: "app1")
        _ = manager.open(nodeId: key.nodeId, app: key.app)
        _ = rack.controller(for: key, url: URL(string: "http://127.0.0.1:1/")!)
        #expect(rack.hasController(for: key))

        manager.close(key)
        #expect(!rack.hasController(for: key), "close is the teardown choke point")
        #expect(rack.controllerCount == 0)
    }

    @Test func serverRemovalDestroysOnlyThatServersPages() {
        let rack = stubRack()
        let manager = makeManager(rack: rack)
        let a1 = WebAppSessionKey(nodeId: "server-a", app: "one")
        let a2 = WebAppSessionKey(nodeId: "server-a", app: "two")
        let b1 = WebAppSessionKey(nodeId: "server-b", app: "one")
        for key in [a1, a2, b1] {
            _ = manager.open(nodeId: key.nodeId, app: key.app)
            _ = rack.controller(for: key, url: URL(string: "http://127.0.0.1:1/")!)
        }

        manager.closeRunningSessions(nodeId: "server-a")

        #expect(!rack.hasController(for: a1))
        #expect(!rack.hasController(for: a2))
        #expect(rack.hasController(for: b1), "another server's page is untouched")
    }

    @Test func lruSessionEvictionDestroysItsPage() {
        let rack = stubRack()
        let manager = makeManager(rack: rack)
        let keys = (0..<WebAppSessionManager.maxSessions).map { i in
            WebAppSessionKey(nodeId: "node", app: "app-\(i)")
        }
        for (i, key) in keys.enumerated() {
            _ = manager.open(nodeId: key.nodeId, app: key.app)
            _ = rack.controller(for: key, url: URL(string: "http://127.0.0.1:1/")!)
            // Deterministic LRU ordering: app-0 is least recently used.
            manager.session(for: key)?.lastActivated = Date(timeIntervalSince1970: TimeInterval(i + 1))
        }
        #expect(rack.controllerCount == WebAppSessionManager.maxSessions)

        _ = manager.open(nodeId: "node", app: "extra")

        #expect(!rack.hasController(for: keys[0]), "evicted session's page goes with it")
        #expect(rack.controllerCount == WebAppSessionManager.maxSessions - 1)
        #expect(manager.runningCount == WebAppSessionManager.maxSessions)
    }

    @Test func memoryWarningDropsTheLruBackgroundPageButKeepsTheSession() {
        let rack = stubRack()
        let manager = makeManager(rack: rack)
        let active = WebAppSessionKey(nodeId: "node", app: "active")
        let background = WebAppSessionKey(nodeId: "node", app: "background")
        for key in [active, background] {
            _ = manager.open(nodeId: key.nodeId, app: key.app)
            _ = rack.controller(for: key, url: URL(string: "http://127.0.0.1:1/")!)
        }
        manager.activate(active)
        manager.session(for: background)?.lastActivated = Date(timeIntervalSince1970: 1)

        manager.evictWarmPageUnderPressure()

        #expect(!rack.hasController(for: background), "LRU background page dropped")
        #expect(rack.hasController(for: active), "active page never evicted")
        // The session itself survives: proxy, green dot, and Recent tile stay;
        // only the page is recreated on next mount.
        #expect(manager.isRunning(background))
        #expect(manager.runningCount == 2)
    }

    @Test func memoryWarningEvictsNothingWhenOnlyTheActivePageExists() {
        let rack = stubRack()
        let manager = makeManager(rack: rack)
        let key = WebAppSessionKey(nodeId: "node", app: "only")
        _ = manager.open(nodeId: key.nodeId, app: key.app)
        _ = rack.controller(for: key, url: URL(string: "http://127.0.0.1:1/")!)
        manager.activate(key)

        manager.evictWarmPageUnderPressure()

        #expect(rack.hasController(for: key))
        #expect(manager.isRunning(key))
    }

    @Test func memoryWarningSkipsSessionsWithoutAPage() {
        let rack = stubRack()
        let manager = makeManager(rack: rack)
        let paged = WebAppSessionKey(nodeId: "node", app: "paged")
        let neverMounted = WebAppSessionKey(nodeId: "node", app: "never-mounted")
        _ = manager.open(nodeId: paged.nodeId, app: paged.app)
        _ = rack.controller(for: paged, url: URL(string: "http://127.0.0.1:1/")!)
        _ = manager.open(nodeId: neverMounted.nodeId, app: neverMounted.app)
        // The oldest session, but it never got a page — it can be neither the
        // victim (nothing to destroy) nor a reason to drop the real page.
        manager.session(for: neverMounted)?.lastActivated = Date(timeIntervalSince1970: 0)
        manager.activate(paged)

        manager.evictWarmPageUnderPressure()

        #expect(rack.hasController(for: paged))
        #expect(manager.runningCount == 2)
    }
}
