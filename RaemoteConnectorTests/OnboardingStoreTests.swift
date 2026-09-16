import Testing
import Foundation
@testable import Raemote_Connector

struct OnboardingStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "OnboardingStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func theNetworkTipIsOfferedOnce() {
        let defaults = freshDefaults()

        #expect(OnboardingStore.shouldShowNetworkTip(defaults: defaults))
        OnboardingStore.markNetworkTipShown(defaults: defaults)
        #expect(!OnboardingStore.shouldShowNetworkTip(defaults: defaults))
    }

    @Test func tipsAreIndependentPerDefaults() {
        let a = freshDefaults()
        let b = freshDefaults()
        OnboardingStore.markNetworkTipShown(defaults: a)
        #expect(!OnboardingStore.shouldShowNetworkTip(defaults: a))
        #expect(OnboardingStore.shouldShowNetworkTip(defaults: b))
    }
}
