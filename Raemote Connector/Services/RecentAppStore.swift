import Foundation
import Observation

/// Remembers the web apps the user has opened, so the list can offer a
/// "Recent" row that outlives a stopped app (and an app relaunch).
///
/// This is deliberately separate from `WebAppSessionManager`: a session is a
/// *live* app (proxy + web view, gone once closed), while a recent is just the
/// fact that you used it. Stopping an app — or restarting the whole daemon —
/// leaves its entry here; only opening it again moves it to the front.
///
/// Entries are keyed by **server node id + app name** (the NodeId-isolation
/// rule): two servers running an identically-named app are two distinct
/// recents, never one.
///
/// The history is deliberately **unbounded**: the row scrolls, so a long
/// history costs a longer scroll and nothing else. What is capped is *memory*,
/// not memory-of-use — `WebAppSessionManager` keeps only the five most
/// recently used apps live, so an evicted app keeps its tile here and is one
/// tap from being warm again. Manual removal is always available.
@MainActor
@Observable
final class RecentAppStore {
    static let shared = RecentAppStore()

    /// One recently used app.
    struct Entry: Identifiable, Hashable {
        let nodeId: String
        let app: String
        let lastUsed: Date

        var key: WebAppSessionKey { WebAppSessionKey(nodeId: nodeId, app: app) }
        var id: String { key.id }
    }

    /// Most recently used first.
    private(set) var entries: [Entry] = []

    private static let storageKey = "recentApps"

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Note that the user just used `key`; it moves to the front.
    func record(_ key: WebAppSessionKey, at date: Date = .now) {
        entries.removeAll { $0.key == key }
        entries.insert(Entry(nodeId: key.nodeId, app: key.app, lastUsed: date), at: 0)
        save()
    }

    /// Forget one app (it may still be running).
    func remove(_ key: WebAppSessionKey) {
        guard entries.contains(where: { $0.key == key }) else { return }
        entries.removeAll { $0.key == key }
        save()
    }

    /// Forget every recent app of one server (used when that server is removed).
    func removeAll(nodeId: String) {
        let before = entries.count
        entries.removeAll { $0.nodeId == nodeId }
        if entries.count != before { save() }
    }

    // MARK: - Persistence

    private func load() {
        guard let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: Double] else {
            return
        }
        entries = stored
            .compactMap { id, time in
                // The key is "nodeId/app". App names are slugs without a "/",
                // but split on the first one anyway so a strange value cannot
                // corrupt another entry.
                let parts = id.split(separator: "/", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return Entry(
                    nodeId: String(parts[0]),
                    app: String(parts[1]),
                    lastUsed: Date(timeIntervalSince1970: time)
                )
            }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    private func save() {
        var stored: [String: Double] = [:]
        for entry in entries {
            stored[entry.id] = entry.lastUsed.timeIntervalSince1970
        }
        defaults.set(stored, forKey: Self.storageKey)
    }
}
