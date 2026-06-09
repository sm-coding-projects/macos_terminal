import Foundation

/// How the user authenticates to the remote host.
public enum AuthMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case password
    case privateKey

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Private Key"
        }
    }
}

/// A saved SSH connection profile. Contains only non-secret metadata —
/// passwords and key passphrases live exclusively in the macOS Keychain
/// (see `ProfileSecretsManager`), never in this struct or its JSON encoding.
public struct ConnectionProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod
    /// Path to the private key file (only meaningful when `authMethod == .privateKey`).
    public var privateKeyPath: String?
    public var notes: String
    /// When true, the password / key passphrase may be persisted to the Keychain.
    public var saveCredentials: Bool
    /// When true, Keychain reads require user presence (Touch ID / system password).
    public var requireUserPresence: Bool
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .password,
        privateKeyPath: String? = nil,
        notes: String = "",
        saveCredentials: Bool = false,
        requireUserPresence: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.notes = notes
        self.saveCredentials = saveCredentials
        self.requireUserPresence = requireUserPresence
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// A copy with a fresh identity, suitable for "Duplicate".
    /// The duplicate never inherits saved-credential state: secrets are
    /// keyed by profile ID and must be re-entered for the new profile.
    public func duplicated() -> ConnectionProfile {
        var copy = self
        copy.id = UUID()
        copy.displayName = displayName.isEmpty ? "Copy" : "\(displayName) Copy"
        copy.createdAt = Date()
        copy.lastUsedAt = nil
        copy.saveCredentials = false
        return copy
    }
}

// MARK: - Validation

public enum ProfileValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyDisplayName
    case emptyHost
    case invalidHost
    case invalidPort
    case emptyUsername
    case missingPrivateKeyPath

    public var description: String {
        switch self {
        case .emptyDisplayName: return "Display name is required."
        case .emptyHost: return "Host or IP address is required."
        case .invalidHost: return "Host contains invalid characters."
        case .invalidPort: return "Port must be between 1 and 65535."
        case .emptyUsername: return "Username is required."
        case .missingPrivateKeyPath: return "A private key file is required for key authentication."
        }
    }
}

public enum ProfileValidator {
    /// Characters permitted in a hostname or IP literal (incl. IPv6 colons).
    private static let hostAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_[]%")

    public static func validate(_ profile: ConnectionProfile) -> [ProfileValidationError] {
        var errors: [ProfileValidationError] = []

        if profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptyDisplayName)
        }

        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty {
            errors.append(.emptyHost)
        } else if host.rangeOfCharacter(from: hostAllowed.inverted) != nil {
            errors.append(.invalidHost)
        }

        if !(1...65535).contains(profile.port) {
            errors.append(.invalidPort)
        }

        if profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptyUsername)
        }

        if profile.authMethod == .privateKey {
            let path = profile.privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if path.isEmpty {
                errors.append(.missingPrivateKeyPath)
            }
        }

        return errors
    }

    public static func isValid(_ profile: ConnectionProfile) -> Bool {
        validate(profile).isEmpty
    }
}
