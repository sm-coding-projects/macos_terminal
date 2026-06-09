import Foundation
import Crypto
import NIOSSH

/// Parses private key files into `NIOSSHPrivateKey`.
///
/// Supported:
///  - Unencrypted OpenSSH format (`-----BEGIN OPENSSH PRIVATE KEY-----`)
///    containing Ed25519 or ECDSA P-256/P-384/P-521 keys.
///  - Unencrypted SEC1/PKCS#8 PEM ECDSA keys (via swift-crypto).
///
/// Passphrase-encrypted keys are detected and rejected with a specific,
/// user-actionable error (`SSHAppError.privateKeyEncrypted`) — decryption
/// requires bcrypt_pbkdf, which we deliberately do not hand-roll. See
/// DECISIONS.md.
public enum OpenSSHKeyParser {
    public static func parse(pemContents: String) throws -> NIOSSHPrivateKey {
        let trimmed = pemContents.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHFormat(trimmed)
        }

        // Legacy encrypted PEM ("Proc-Type: 4,ENCRYPTED") or encrypted PKCS#8.
        if trimmed.contains("Proc-Type: 4,ENCRYPTED") || trimmed.contains("BEGIN ENCRYPTED PRIVATE KEY") {
            throw SSHAppError.privateKeyEncrypted
        }

        if trimmed.contains("BEGIN EC PRIVATE KEY") || trimmed.contains("BEGIN PRIVATE KEY") {
            if let p256 = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
                return NIOSSHPrivateKey(p256Key: p256)
            }
            if let p384 = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) {
                return NIOSSHPrivateKey(p384Key: p384)
            }
            if let p521 = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) {
                return NIOSSHPrivateKey(p521Key: p521)
            }
            throw SSHAppError.privateKeyUnsupported(detail: "PEM key is not a supported ECDSA key")
        }

        if trimmed.contains("BEGIN RSA PRIVATE KEY") {
            throw SSHAppError.privateKeyUnsupported(detail: "RSA keys are not supported by the SSH backend; use Ed25519")
        }

        throw SSHAppError.privateKeyUnsupported(detail: "unrecognized key file format")
    }

    // MARK: - openssh-key-v1

    private static func parseOpenSSHFormat(_ pem: String) throws -> NIOSSHPrivateKey {
        let lines = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let blob = Data(base64Encoded: lines) else {
            throw SSHAppError.privateKeyUnsupported(detail: "invalid base64 body")
        }

        var reader = SSHWireReader(data: blob)
        let magic = "openssh-key-v1\0"
        guard let magicData = reader.readBytes(count: magic.utf8.count),
              String(data: magicData, encoding: .utf8) == magic else {
            throw SSHAppError.privateKeyUnsupported(detail: "missing openssh-key-v1 header")
        }

        guard let cipherName = reader.readString(),
              let kdfName = reader.readString(),
              reader.readLengthPrefixed() != nil,   // kdf options
              let keyCount = reader.readUInt32() else {
            throw SSHAppError.privateKeyUnsupported(detail: "truncated key file")
        }

        guard cipherName == "none", kdfName == "none" else {
            throw SSHAppError.privateKeyEncrypted
        }
        guard keyCount == 1 else {
            throw SSHAppError.privateKeyUnsupported(detail: "multi-key files are not supported")
        }

        guard reader.readLengthPrefixed() != nil,                 // public key blob
              let privateSection = reader.readLengthPrefixed() else {
            throw SSHAppError.privateKeyUnsupported(detail: "truncated key file")
        }

        var priv = SSHWireReader(data: privateSection)
        guard let check1 = priv.readUInt32(), let check2 = priv.readUInt32(), check1 == check2 else {
            throw SSHAppError.privateKeyUnsupported(detail: "integrity check failed")
        }

        guard let keyType = priv.readString() else {
            throw SSHAppError.privateKeyUnsupported(detail: "missing key type")
        }

        switch keyType {
        case "ssh-ed25519":
            guard priv.readLengthPrefixed() != nil,                       // public key (32 bytes)
                  let privBlob = priv.readLengthPrefixed(),               // 64 bytes: seed || public
                  privBlob.count == 64 else {
                throw SSHAppError.privateKeyUnsupported(detail: "malformed Ed25519 key")
            }
            let seed = privBlob.prefix(32)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return NIOSSHPrivateKey(ed25519Key: key)

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard priv.readString() != nil,                               // curve name
                  priv.readLengthPrefixed() != nil,                       // public point Q
                  let dRaw = priv.readLengthPrefixed() else {
                throw SSHAppError.privateKeyUnsupported(detail: "malformed ECDSA key")
            }
            // d is an mpint: strip a leading zero sign byte, then left-pad
            // to the curve's field size.
            var d = dRaw
            if d.first == 0 { d = d.dropFirst() }
            switch keyType {
            case "ecdsa-sha2-nistp256":
                let key = try P256.Signing.PrivateKey(rawRepresentation: d.leftPadded(to: 32))
                return NIOSSHPrivateKey(p256Key: key)
            case "ecdsa-sha2-nistp384":
                let key = try P384.Signing.PrivateKey(rawRepresentation: d.leftPadded(to: 48))
                return NIOSSHPrivateKey(p384Key: key)
            default:
                let key = try P521.Signing.PrivateKey(rawRepresentation: d.leftPadded(to: 66))
                return NIOSSHPrivateKey(p521Key: key)
            }

        case "ssh-rsa":
            throw SSHAppError.privateKeyUnsupported(detail: "RSA keys are not supported by the SSH backend; use Ed25519")
        default:
            throw SSHAppError.privateKeyUnsupported(detail: "key type \(keyType)")
        }
    }
}

// MARK: - Wire-format reader

/// Minimal reader for SSH wire format (RFC 4251): big-endian uint32
/// length-prefixed fields.
struct SSHWireReader {
    private let data: Data
    private var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readBytes(count: Int) -> Data? {
        guard count >= 0, data.distance(from: offset, to: data.endIndex) >= count else { return nil }
        let end = data.index(offset, offsetBy: count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(count: 4) else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readLengthPrefixed() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(count: Int(length))
    }

    mutating func readString() -> String? {
        guard let bytes = readLengthPrefixed() else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

extension Data {
    func leftPadded(to length: Int) -> Data {
        if count >= length { return suffix(length) }
        return Data(repeating: 0, count: length - count) + self
    }
}
