import Testing
import Foundation
@testable import Raemote_Connector

@MainActor
struct RecentAppStoreTests {
    private func freshStore() -> (RecentAppStore, UserDefaults, String) {
        let suite = "RecentAppStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (RecentAppStore(defaults: defaults), defaults, suite)
    }

    private func key(_ node: String, _ app: String) -> WebAppSessionKey {
        WebAppSessionKey(nodeId: node, app: app)
    }

    @Test func recordsMostRecentFirst() {
        let (store, _, _) = freshStore()
        store.record(key("server-a", "one"), at: Date(timeIntervalSince1970: 100))
        store.record(key("server-a", "two"), at: Date(timeIntervalSince1970: 200))

        #expect(store.entries.map(\.app) == ["two", "one"])
    }

    @Test func reRecordingMovesAnAppToTheFrontWithoutDuplicating() {
        let (store, _, _) = freshStore()
        store.record(key("server-a", "one"), at: Date(timeIntervalSince1970: 100))
        store.record(key("server-a", "two"), at: Date(timeIntervalSince1970: 200))
        store.record(key("server-a", "one"), at: Date(timeIntervalSince1970: 300))

        #expect(store.entries.map(\.app) == ["one", "two"])
        #expect(store.entries.count == 2)
    }

    @Test func stoppingTheAppDoesNotRemoveTheRecent() {
        // The whole point: the session (live app) and the recent (memory) are
        // separate. Closing the session must leave the entry — without its
        // green dot, which comes from `sessionManager.isRunning`.
        let (store, _, _) = freshStore()
        let manager = WebAppSessionManager(service: IrohService(monitor: IrohConnectionMonitor()))
        let key = key("server-a", "jellyfin")

        store.record(key)
        _ = manager.open(nodeId: key.nodeId, app: key.app)
        #expect(manager.isRunning(key))

        manager.close(key)

        #expect(!manager.isRunning(key))
        #expect(store.entries.map(\.app) == ["jellyfin"])
    }

    @Test func sameAppNameOnTwoServersStaysIsolated() {
        let (store, _, _) = freshStore()
        store.record(key("server-a", "jellyfin"), at: Date(timeIntervalSince1970: 100))
        store.record(key("server-b", "jellyfin"), at: Date(timeIntervalSince1970: 200))

        #expect(store.entries.count == 2)
        #expect(store.entries.map(\.nodeId) == ["server-b", "server-a"])

        store.remove(key("server-a", "jellyfin"))
        #expect(store.entries.map(\.nodeId) == ["server-b"])
    }

    @Test func capsTheHistoryAtTheOldestEnd() {
        let (store, _, _) = freshStore()
        for i in 0..<(RecentAppStore.maxEntries + 5) {
            store.record(
                key("server-a", "app-\(i)"),
                at: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }
        #expect(store.entries.count == RecentAppStore.maxEntries)
        // The newest survived; the first five were dropped.
        #expect(store.entries.first?.app == "app-\(RecentAppStore.maxEntries + 4)")
        #expect(!store.entries.contains { $0.app == "app-0" })
    }

    @Test func removeAllDropsOnlyThatServer() {
        let (store, _, _) = freshStore()
        store.record(key("server-a", "one"))
        store.record(key("server-a", "two"))
        store.record(key("server-b", "one"))

        store.removeAll(nodeId: "server-a")

        #expect(store.entries.map(\.nodeId) == ["server-b"])
    }

    @Test func historySurvivesARelaunch() {
        let (store, defaults, _) = freshStore()
        store.record(key("server-a", "one"), at: Date(timeIntervalSince1970: 100))
        store.record(key("server-a", "two"), at: Date(timeIntervalSince1970: 200))

        // A fresh store over the same defaults, as after a relaunch.
        let reloaded = RecentAppStore(defaults: defaults)
        #expect(reloaded.entries.map(\.app) == ["two", "one"])
    }
}
