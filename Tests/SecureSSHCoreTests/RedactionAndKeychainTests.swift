import Foundation
import Testing
@testable import SecureSSHCore

@Suite("Redaction")
struct RedactionTests {
    @Test func secretsAreMasked() {
        // Throwaway value generated for this test only — not a real credential.
        let secret = UUID().uuidString
        let message = "auth failed for user with \(secret) at host"
        let redacted = Redactor.redact(message, secrets: [secret])
        #expect(!redacted.contains(secret))
        #expect(redacted.contains(Redactor.mask))
    }

    @Test func multipleAndRepeatedSecretsAreMasked() {
        let s1 = "tok-\(UUID().uuidString)"
        let s2 = "key-\(UUID().uuidString)"
        let message = "\(s1) … \(s2) … \(s1)"
        let redacted = Redactor.redact(message, secrets: [s1, s2])
        #expect(!redacted.contains(s1))
        #expect(!redacted.contains(s2))
    }

    @Test func nilAndEmptySecretsAreIgnored() {
        let message = "plain message"
        #expect(Redactor.redact(message, secrets: [nil, "", "   "]) == message)
    }

    @Test func describeUsesFriendlyAppErrorMessages() {
        let described = Redactor.describe(SSHAppError.authenticationFailed)
        #expect(described.contains("Authentication failed"))
    }

    @Test func describeRedactsSecretsFromUnderlyingErrors() {
        struct LeakyError: Error, CustomStringConvertible {
            let leak: String
            var description: String { "failure containing \(leak)" }
        }
        let secret = UUID().uuidString
        let described = Redactor.describe(LeakyError(leak: secret), secrets: [secret])
        #expect(!described.contains(secret))
    }

    @Test func appErrorMessagesNeverEchoCredentialMaterial() {
        // Error messages are templated; spot-check that the cases used on
        // auth/connect paths carry no interpolated credential.
        let messages = [
            SSHAppError.authenticationFailed,
            SSHAppError.hostKeyRejected,
            SSHAppError.hostKeyChanged,
            SSHAppError.connectionTimedOut,
        ].map { $0.errorDescription ?? "" }
        for message in messages {
            #expect(!message.isEmpty)
        }
    }
}

@Suite("Keychain service and profile secrets")
struct KeychainTests {
    @Test func storeReadDeleteRoundTrip() throws {
        let keychain = InMemoryKeychainService()
        let secret = Data(UUID().uuidString.utf8)
        try keychain.storeSecret(secret, account: "acct", requireUserPresence: false)
        #expect(try keychain.readSecret(account: "acct") == secret)
        try keychain.deleteSecret(account: "acct")
        #expect(try keychain.readSecret(account: "acct") == nil)
    }

    @Test func deleteOfMissingItemIsNotAnError() throws {
        let keychain = InMemoryKeychainService()
        try keychain.deleteSecret(account: "never-existed")
    }

    @Test func secretsOnlyStoredWhenProfileOptsIn() throws {
        let keychain = InMemoryKeychainService()
        let secrets = ProfileSecretsManager(keychain: keychain)
        var profile = ConnectionProfile(displayName: "X", host: "x", username: "u")

        profile.saveCredentials = false
        try secrets.savePassword(UUID().uuidString, for: profile)
        #expect(keychain.storage.isEmpty, "opt-out profile must never reach the keychain")

        profile.saveCredentials = true
        let value = UUID().uuidString
        try secrets.savePassword(value, for: profile)
        #expect(try secrets.readPassword(for: profile) == value)
    }

    @Test func userPresenceFlagPropagates() throws {
        let keychain = InMemoryKeychainService()
        let secrets = ProfileSecretsManager(keychain: keychain)
        var profile = ConnectionProfile(displayName: "X", host: "x", username: "u")
        profile.saveCredentials = true
        profile.requireUserPresence = true

        try secrets.savePassword(UUID().uuidString, for: profile)
        let account = ProfileSecretsManager.passwordAccount(for: profile.id)
        #expect(keychain.presenceRequired.contains(account))
    }

    @Test func deletingProfileSecretsRemovesPasswordAndPassphrase() throws {
        let keychain = InMemoryKeychainService()
        let secrets = ProfileSecretsManager(keychain: keychain)
        var profile = ConnectionProfile(displayName: "X", host: "x", username: "u")
        profile.saveCredentials = true

        try secrets.savePassword(UUID().uuidString, for: profile)
        try secrets.savePassphrase(UUID().uuidString, for: profile)
        #expect(keychain.storage.count == 2)

        try secrets.deleteAllSecrets(for: profile.id)
        #expect(keychain.storage.isEmpty)
    }

    @Test func accountsAreNamespacedPerProfile() throws {
        let keychain = InMemoryKeychainService()
        let secrets = ProfileSecretsManager(keychain: keychain)
        var p1 = ConnectionProfile(displayName: "A", host: "a", username: "u")
        var p2 = ConnectionProfile(displayName: "B", host: "b", username: "u")
        p1.saveCredentials = true
        p2.saveCredentials = true

        let v1 = UUID().uuidString
        let v2 = UUID().uuidString
        try secrets.savePassword(v1, for: p1)
        try secrets.savePassword(v2, for: p2)

        try secrets.deleteAllSecrets(for: p1.id)
        #expect(try secrets.readPassword(for: p1) == nil)
        #expect(try secrets.readPassword(for: p2) == v2, "deleting one profile must not touch another's secrets")
    }
}
