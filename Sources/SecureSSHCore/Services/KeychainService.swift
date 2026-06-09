import Foundation
import Security

/// Abstraction over secret storage. The production implementation is the
/// macOS Keychain; tests use `InMemoryKeychainService`.
public protocol KeychainServicing: AnyObject {
    /// Stores (or replaces) a secret. When `requireUserPresence` is true the
    /// item is protected by an access control requiring Touch ID or the
    /// system password at read time.
    func storeSecret(_ secret: Data, account: String, requireUserPresence: Bool) throws
    /// Returns the secret, or nil if no item exists for the account.
    func readSecret(account: String) throws -> Data?
    /// Removes the secret if present. Missing items are not an error.
    func deleteSecret(account: String) throws
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case accessControlCreationFailed
    case userCancelled
}

/// Real Keychain-backed implementation.
///
/// Items are stored as generic passwords under a single service name,
/// with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so secrets never
/// migrate to other devices or backups, and are unavailable while locked.
public final class MacKeychainService: KeychainServicing {
    public static let defaultService = "com.securessh.terminal.credentials"
    private let service: String

    public init(service: String = MacKeychainService.defaultService) {
        self.service = service
    }

    public func storeSecret(_ secret: Data, account: String, requireUserPresence: Bool) throws {
        // Replace-then-add keeps the operation idempotent.
        try deleteSecret(account: account)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
        ]

        if requireUserPresence {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &error
            ) else {
                throw KeychainError.accessControlCreationFailed
            }
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func readSecret(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: "SecureSSH Terminal needs your saved credential to connect.",
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.userCancelled
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func deleteSecret(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// Test/preview double. Never persists anything to disk.
public final class InMemoryKeychainService: KeychainServicing {
    public private(set) var storage: [String: Data] = [:]
    public private(set) var presenceRequired: Set<String> = []

    public init() {}

    public func storeSecret(_ secret: Data, account: String, requireUserPresence: Bool) throws {
        storage[account] = secret
        if requireUserPresence { presenceRequired.insert(account) } else { presenceRequired.remove(account) }
    }

    public func readSecret(account: String) throws -> Data? { storage[account] }

    public func deleteSecret(account: String) throws {
        storage.removeValue(forKey: account)
        presenceRequired.remove(account)
    }
}

// MARK: - Profile secret coordination

/// Maps profiles to their Keychain accounts and enforces the lifecycle rules:
/// secrets are stored only when the profile opts in, and all secrets are
/// purged when a profile is deleted.
public final class ProfileSecretsManager {
    private let keychain: KeychainServicing

    public init(keychain: KeychainServicing) {
        self.keychain = keychain
    }

    public static func passwordAccount(for profileID: UUID) -> String {
        "\(profileID.uuidString).password"
    }

    public static func passphraseAccount(for profileID: UUID) -> String {
        "\(profileID.uuidString).passphrase"
    }

    public func savePassword(_ password: String, for profile: ConnectionProfile) throws {
        guard profile.saveCredentials else { return }
        try keychain.storeSecret(
            Data(password.utf8),
            account: Self.passwordAccount(for: profile.id),
            requireUserPresence: profile.requireUserPresence
        )
    }

    public func savePassphrase(_ passphrase: String, for profile: ConnectionProfile) throws {
        guard profile.saveCredentials else { return }
        try keychain.storeSecret(
            Data(passphrase.utf8),
            account: Self.passphraseAccount(for: profile.id),
            requireUserPresence: profile.requireUserPresence
        )
    }

    public func readPassword(for profile: ConnectionProfile) throws -> String? {
        guard let data = try keychain.readSecret(account: Self.passwordAccount(for: profile.id)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func readPassphrase(for profile: ConnectionProfile) throws -> String? {
        guard let data = try keychain.readSecret(account: Self.passphraseAccount(for: profile.id)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Removes every Keychain item associated with the profile.
    /// Called when a profile is deleted, or when saving is switched off.
    public func deleteAllSecrets(for profileID: UUID) throws {
        try keychain.deleteSecret(account: Self.passwordAccount(for: profileID))
        try keychain.deleteSecret(account: Self.passphraseAccount(for: profileID))
    }
}
