import Foundation

/// One-time onboarding tips, so guidance appears once and never nags.
enum OnboardingStore {
    private static let networkTipKey = "didShowNetworkCheckTip"

    /// Whether the "try it on another network" tip still needs to be shown.
    static func shouldShowNetworkTip(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: networkTipKey)
    }

    /// Record that the tip has been shown.
    static func markNetworkTipShown(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: networkTipKey)
    }
}
