import Testing
import Foundation
@testable import Raemote_Connector

struct DeviceNameStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "DeviceNameStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func generatesAndPersistsADefault() {
        let defaults = freshDefaults()
        let first = DeviceNameStore.load(from: defaults)
        #expect(!first.isEmpty)
        // Stored: a second read returns the same value.
        #expect(DeviceNameStore.load(from: defaults) == first)
    }

    @Test func savesAndTrimsAName() {
        let defaults = freshDefaults()
        DeviceNameStore.save("  Leo's iPhone  ", to: defaults)
        #expect(DeviceNameStore.load(from: defaults) == "Leo's iPhone")
    }

    @Test func blankNameFallsBackToTheDefault() {
        let defaults = freshDefaults()
        DeviceNameStore.save("   ", to: defaults)
        #expect(!DeviceNameStore.load(from: defaults).isEmpty)
    }
}
