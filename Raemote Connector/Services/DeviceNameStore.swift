import Foundation
import UIKit

/// The name this device advertises to paired servers.
///
/// Display only — it never affects access. Stored in `UserDefaults` and
/// editable by the user; the default is `UIDevice.current.name`, which iOS may
/// report generically (for example "iPhone") without the
/// user-assigned-device-name entitlement.
enum DeviceNameStore {
    private static let key = "deviceName"

    /// The current name, generating and persisting a default on first access.
    static var name: String {
        get { load(from: .standard) }
        set { save(newValue, to: .standard) }
    }

    /// Read the stored name, persisting a default when none is set.
    static func load(from defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: key), !stored.trimmed.isEmpty {
            return stored
        }
        let generated = defaultName()
        defaults.set(generated, forKey: key)
        return generated
    }

    /// Store a trimmed name (an empty value falls back to the default on read).
    static func save(_ name: String, to defaults: UserDefaults) {
        defaults.set(name.trimmed, forKey: key)
    }

    private static func defaultName() -> String {
        let device = UIDevice.current
        let reported = device.name.trimmed
        if !reported.isEmpty {
            return reported
        }
        return device.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
