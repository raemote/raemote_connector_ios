import Testing
import Foundation
@testable import Raemote_Connector

struct AppNameStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "AppNameStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func namesAreNamespacedByServer() {
        let defaults = freshDefaults()

        AppNameStore.remember("Jellyfin", nodeId: "server-a", app: "jellyfin", defaults: defaults)
        AppNameStore.remember("Plex", nodeId: "server-b", app: "jellyfin", defaults: defaults)

        // Same app name on two servers → independent names.
        #expect(AppNameStore.name(nodeId: "server-a", app: "jellyfin", defaults: defaults) == "Jellyfin")
        #expect(AppNameStore.name(nodeId: "server-b", app: "jellyfin", defaults: defaults) == "Plex")
        #expect(AppNameStore.name(nodeId: "server-c", app: "jellyfin", defaults: defaults) == nil)
    }

    @Test func namesReturnsOnlyThatServer() {
        let defaults = freshDefaults()

        AppNameStore.remember("Jellyfin", nodeId: "server-a", app: "jellyfin", defaults: defaults)
        AppNameStore.remember("Home", nodeId: "server-a", app: "home", defaults: defaults)
        AppNameStore.remember("Other", nodeId: "server-b", app: "home", defaults: defaults)

        #expect(AppNameStore.names(nodeId: "server-a", defaults: defaults) == [
            "jellyfin": "Jellyfin",
            "home": "Home",
        ])
        #expect(AppNameStore.names(nodeId: "server-b", defaults: defaults) == ["home": "Other"])
    }

    @Test func collapsesWhitespaceAndTrims() {
        let defaults = freshDefaults()
        AppNameStore.remember("  DeepSeek   Harness\n", nodeId: "server-a", app: "app", defaults: defaults)
        #expect(AppNameStore.name(nodeId: "server-a", app: "app", defaults: defaults) == "DeepSeek Harness")
    }

    @Test func rejectsPlaceholderTitles() {
        #expect(AppNameStore.normalized("") == nil)
        #expect(AppNameStore.normalized("   ") == nil)
        #expect(AppNameStore.normalized("Loading…") == nil)
        #expect(AppNameStore.normalized("untitled") == nil)
        #expect(AppNameStore.normalized("127.0.0.1:52001") == nil)
        #expect(AppNameStore.normalized("http://localhost:3000/") == nil)
        #expect(AppNameStore.normalized("3000") == nil)
        #expect(AppNameStore.normalized("192.168.1.10:8096") == nil)
    }

    @Test func keepsRealTitles() {
        #expect(AppNameStore.normalized("Jellyfin") == "Jellyfin")
        #expect(AppNameStore.normalized("Directory listing for /") == "Directory listing for /")
        #expect(AppNameStore.normalized("Vite + React") == "Vite + React")
    }

    @Test func unusableTitleIsNotStored() {
        let defaults = freshDefaults()
        let stored = AppNameStore.remember("Loading…", nodeId: "server-a", app: "app", defaults: defaults)
        #expect(stored == nil)
        #expect(AppNameStore.name(nodeId: "server-a", app: "app", defaults: defaults) == nil)
    }

    @Test func laterTitleReplacesTheEarlierOne() {
        let defaults = freshDefaults()
        AppNameStore.remember("First", nodeId: "server-a", app: "app", defaults: defaults)
        AppNameStore.remember("Second", nodeId: "server-a", app: "app", defaults: defaults)
        #expect(AppNameStore.name(nodeId: "server-a", app: "app", defaults: defaults) == "Second")
    }

    /// A name stored by a build before the error-page marker (which could have
    /// saved our own error headline) is dropped once, and the version is
    /// recorded so it does not happen again.
    @Test func migrationDropsNamesFromOlderBuilds() {
        let defaults = freshDefaults()
        // Simulate a v1 store holding the confusing value.
        defaults.set(
            ["server-a/app": "Couldn't reach the app."],
            forKey: "appNamesByApp"
        )
        defaults.set(1, forKey: "appNamesSchemaVersion")

        #expect(AppNameStore.name(nodeId: "server-a", app: "app", defaults: defaults) == nil)
        #expect(defaults.integer(forKey: "appNamesSchemaVersion") == 2)

        // It only happens once: a name learned afterwards survives a re-read.
        AppNameStore.remember("Jellyfin", nodeId: "server-a", app: "app", defaults: defaults)
        #expect(AppNameStore.name(nodeId: "server-a", app: "app", defaults: defaults) == "Jellyfin")
        #expect(AppNameStore.name(nodeId: "server-a", app: "app", defaults: defaults) == "Jellyfin")
    }

    /// Read-time validation: a stored value that would be rejected today is
    /// never surfaced, even if it predates the write-time guard.
    @Test func aStoredValueThatIsUnusableIsNotSurfaced() {
        let defaults = freshDefaults()
        defaults.set(["server-a/app": "127.0.0.1:52001"], forKey: "appNamesByApp")
        defaults.set(2, forKey: "appNamesSchemaVersion")
        #expect(AppNameStore.name(nodeId: "server-a", app: "app", defaults: defaults) == nil)
    }
}
