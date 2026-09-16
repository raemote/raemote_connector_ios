import Testing
import Foundation
@testable import Raemote_Connector

struct AppLaunchStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "AppLaunchStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func acceptsAWholeURL() {
        #expect(AppLaunchStore.normalized("http://127.0.0.1:3080/?token=abc") == "/?token=abc")
        #expect(AppLaunchStore.normalized("https://127.0.0.1:3080/app/?t=1&u=2") == "/app/?t=1&u=2")
        // A LAN URL is accepted too; only the path and query matter.
        #expect(AppLaunchStore.normalized("http://192.168.1.5:3080/?token=abc") == "/?token=abc")
    }

    @Test func acceptsQueryPathOrPair() {
        #expect(AppLaunchStore.normalized("?token=abc") == "/?token=abc")
        #expect(AppLaunchStore.normalized("token=abc") == "/?token=abc")
        #expect(AppLaunchStore.normalized("/admin?token=abc") == "/admin?token=abc")
        #expect(AppLaunchStore.normalized("127.0.0.1:3080/?token=abc") == "/?token=abc")
        // Surrounding whitespace (from a copy) is trimmed.
        #expect(AppLaunchStore.normalized("  ?token=abc\n") == "/?token=abc")
    }

    @Test func rejectsInputWithNothingToOpen() {
        #expect(AppLaunchStore.normalized("") == nil)
        #expect(AppLaunchStore.normalized("   ") == nil)
        #expect(AppLaunchStore.normalized("/") == nil)
        #expect(AppLaunchStore.normalized("http://127.0.0.1:3080/") == nil)
        #expect(AppLaunchStore.normalized("just some words") == nil)
    }

    @Test func pathsAreNamespacedByServer() {
        let defaults = freshDefaults()

        AppLaunchStore.remember("/?token=a", nodeId: "server-a", app: "tool", defaults: defaults)
        AppLaunchStore.remember("/?token=b", nodeId: "server-b", app: "tool", defaults: defaults)

        #expect(AppLaunchStore.path(nodeId: "server-a", app: "tool", defaults: defaults) == "/?token=a")
        #expect(AppLaunchStore.path(nodeId: "server-b", app: "tool", defaults: defaults) == "/?token=b")
        #expect(AppLaunchStore.path(nodeId: "server-c", app: "tool", defaults: defaults) == nil)
    }

    @Test func pathsReturnsOnlyThatServer() {
        let defaults = freshDefaults()

        AppLaunchStore.remember("/?token=a", nodeId: "server-a", app: "tool", defaults: defaults)
        AppLaunchStore.remember("/?token=b", nodeId: "server-b", app: "tool", defaults: defaults)

        #expect(AppLaunchStore.paths(nodeId: "server-a", defaults: defaults) == ["tool": "/?token=a"])
        #expect(AppLaunchStore.paths(nodeId: "server-b", defaults: defaults) == ["tool": "/?token=b"])
    }

    @Test func storingAWholeURLKeepsOnlyThePathAndQuery() {
        let defaults = freshDefaults()
        let stored = AppLaunchStore.remember(
            "http://127.0.0.1:3080/?token=secret",
            nodeId: "server-a",
            app: "tool",
            defaults: defaults
        )
        #expect(stored == "/?token=secret")
        #expect(AppLaunchStore.path(nodeId: "server-a", app: "tool", defaults: defaults) == "/?token=secret")
    }

    @Test func emptyInputClearsTheEntry() {
        let defaults = freshDefaults()
        AppLaunchStore.remember("/?token=a", nodeId: "server-a", app: "tool", defaults: defaults)
        #expect(AppLaunchStore.remember("", nodeId: "server-a", app: "tool", defaults: defaults) == nil)
        #expect(AppLaunchStore.path(nodeId: "server-a", app: "tool", defaults: defaults) == nil)
        #expect(AppLaunchStore.paths(nodeId: "server-a", defaults: defaults).isEmpty)
    }
}
