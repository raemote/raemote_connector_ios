import Testing
import Foundation
@testable import Raemote_Connector

struct ProxyPortStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ProxyPortStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func portsAreNamespacedByServer() {
        let defaults = freshDefaults()

        ProxyPortStore.remember(51000, nodeId: "server-a", app: "jellyfin", defaults: defaults)
        ProxyPortStore.remember(52000, nodeId: "server-b", app: "jellyfin", defaults: defaults)

        // Same app name on two servers → independent ports (and origins).
        #expect(ProxyPortStore.preferredPort(nodeId: "server-a", app: "jellyfin", defaults: defaults) == 51000)
        #expect(ProxyPortStore.preferredPort(nodeId: "server-b", app: "jellyfin", defaults: defaults) == 52000)
        #expect(ProxyPortStore.preferredPort(nodeId: "server-c", app: "jellyfin", defaults: defaults) == nil)
    }

    @Test func differentAppsOnOneServerAreIndependent() {
        let defaults = freshDefaults()

        ProxyPortStore.remember(53000, nodeId: "server-a", app: "jellyfin", defaults: defaults)
        ProxyPortStore.remember(53001, nodeId: "server-a", app: "home", defaults: defaults)

        #expect(ProxyPortStore.preferredPort(nodeId: "server-a", app: "jellyfin", defaults: defaults) == 53000)
        #expect(ProxyPortStore.preferredPort(nodeId: "server-a", app: "home", defaults: defaults) == 53001)
    }
}
