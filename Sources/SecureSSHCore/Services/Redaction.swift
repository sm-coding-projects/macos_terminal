import Foundation

/// Removes secret material from strings destined for logs or user-facing errors.
public enum Redactor {
    public static let mask = "•••redacted•••"

    /// Replaces every occurrence of each secret in `message` with a mask.
    /// Empty or whitespace-only secrets are ignored (they would corrupt the message).
    public static func redact(_ message: String, secrets: [String?]) -> String {
        var result = message
        for secret in secrets {
            guard let secret, secret.count >= 1,
                  !secret.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result = result.replacingOccurrences(of: secret, with: mask)
        }
        return result
    }

    /// Formats an arbitrary error for display, stripping any secrets that
    /// might have leaked into its description.
    public static func describe(_ error: Error, secrets: [String?] = []) -> String {
        if let appError = error as? SSHAppError {
            return appError.errorDescription ?? "An unknown error occurred."
        }
        return redact(String(describing: error), secrets: secrets)
    }
}

/// User-facing error type. Messages are templated and never interpolate
/// secret material (passwords, passphrases, key contents).
public enum SSHAppError: Error, LocalizedError, Equatable {
    case connectionFailed(reason: String)
    case connectionTimedOut
    case authenticationFailed
    case hostKeyRejected
    case hostKeyChanged
    case privateKeyUnreadable(path: String)
    case privateKeyEncrypted
    case privateKeyUnsupported(detail: String)
    case notConnected
    case channelSetupFailed

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Could not connect: \(reason)"
        case .connectionTimedOut:
            return "The connection timed out. Check the host, port, and your network."
        case .authenticationFailed:
            return "Authentication failed. Check your username and credentials."
        case .hostKeyRejected:
            return "Connection cancelled: the server's host key was not trusted."
        case .hostKeyChanged:
            return "Connection blocked: the server's host key has changed. This could indicate a man-in-the-middle attack."
        case .privateKeyUnreadable(let path):
            return "The private key at \(path) could not be read."
        case .privateKeyEncrypted:
            return "This private key is passphrase-protected, which this version cannot decrypt. Use an unencrypted key (e.g. ssh-keygen -p -N \"\") stored in a protected location, or password authentication."
        case .privateKeyUnsupported(let detail):
            return "Unsupported private key: \(detail). Supported formats: unencrypted OpenSSH Ed25519, and unencrypted PEM ECDSA (P-256/384/521)."
        case .notConnected:
            return "Not connected."
        case .channelSetupFailed:
            return "The server refused to open an interactive session."
        }
    }
}
