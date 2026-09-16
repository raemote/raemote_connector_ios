import Foundation
import Security

/// Stores the device's iroh private key in the iOS Keychain.
///
/// The key is this app's device identity: anyone who holds it can impersonate
/// this phone to a paired server. It is kept in the Keychain rather than
/// `UserDefaults`, and marked `AfterFirstUnlockThisDeviceOnly` so that it:
///
/// - is unavailable before the first unlock after a reboot;
/// - is **not** synced to iCloud Keychain; and
/// - is **not** restored onto a different device from a backup.
enum KeychainSecretStore {
    /// Keychain service this app stores its identity under.
    ///
    /// Derived from the bundle identifier rather than hard-coded, so a fork
    /// with its own bundle id gets its own Keychain entry. For an existing
    /// install the value is unchanged, which matters: moving it would make the
    /// app look like a new device and require pairing again.
    static let defaultService = Bundle.main.bundleIdentifier ?? "raemote"
    static let defaultAccount = "iroh-secret-key"

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Read the stored key, or `nil` if none is present.
    static func load(
        service: String = defaultService,
        account: String = defaultAccount
    ) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Store (or replace) the key. Returns `false` on failure.
    @discardableResult
    static func save(
        _ data: Data,
        service: String = defaultService,
        account: String = defaultAccount
    ) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Remove the stored key. Returns `false` on failure.
    @discardableResult
    static func delete(
        service: String = defaultService,
        account: String = defaultAccount
    ) -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
