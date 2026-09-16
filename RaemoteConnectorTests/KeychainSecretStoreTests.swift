import Testing
import Foundation
@testable import Raemote_Connector

struct KeychainSecretStoreTests {
    // Use a dedicated service/account so the tests never touch the app's real
    // device key.
    private let service = "raemote-connector-tests"
    private let account = "iroh-secret-key-test"

    @Test func saveLoadOverwriteDelete() {
        let original = Data((0..<32).map { UInt8($0) })
        KeychainSecretStore.delete(service: service, account: account)

        #expect(KeychainSecretStore.save(original, service: service, account: account))
        #expect(KeychainSecretStore.load(service: service, account: account) == original)

        let updated = Data(repeating: 7, count: 32)
        #expect(KeychainSecretStore.save(updated, service: service, account: account))
        #expect(KeychainSecretStore.load(service: service, account: account) == updated)

        #expect(KeychainSecretStore.delete(service: service, account: account))
        #expect(KeychainSecretStore.load(service: service, account: account) == nil)
    }

    /// The app's Keychain entry must follow the bundle identifier: that is what
    /// keeps an existing install's identity in place after this indirection
    /// (changing the service string would orphan the stored key).
    @Test func defaultServiceFollowsTheBundleIdentifier() {
        #expect(KeychainSecretStore.defaultService == (Bundle.main.bundleIdentifier ?? "raemote"))
    }

    @Test func loadMissingReturnsNil() {
        KeychainSecretStore.delete(service: service, account: account)
        #expect(KeychainSecretStore.load(service: service, account: account) == nil)
    }

    @Test func deleteMissingSucceeds() {
        #expect(KeychainSecretStore.delete(service: service, account: account))
    }
}
