import Foundation
import Testing
@testable import SecureSSHCore

/// Keys for these tests are generated at runtime with ssh-keygen in a
/// temporary directory — no key material is committed to the repository.
@Suite("OpenSSH private key parsing", .serialized)
struct OpenSSHKeyParserTests {
    private func generateKey(type: String, passphrase: String = "") throws -> String? {
        let sshKeygen = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: sshKeygen) else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssht-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("test_key").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshKeygen)
        process.arguments = ["-t", type, "-N", passphrase, "-f", keyPath, "-q", "-C", "generated-test-key"]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try String(contentsOfFile: keyPath, encoding: .utf8)
    }

    @Test func unencryptedEd25519KeyParses() throws {
        guard let pem = try generateKey(type: "ed25519") else { return }
        _ = try OpenSSHKeyParser.parse(pemContents: pem)
    }

    @Test func unencryptedECDSAKeyParses() throws {
        guard let pem = try generateKey(type: "ecdsa") else { return }
        _ = try OpenSSHKeyParser.parse(pemContents: pem)
    }

    @Test func encryptedKeyIsRejectedWithSpecificError() throws {
        // Throwaway random passphrase, generated at runtime.
        guard let pem = try generateKey(type: "ed25519", passphrase: UUID().uuidString) else { return }
        #expect(throws: SSHAppError.privateKeyEncrypted) {
            _ = try OpenSSHKeyParser.parse(pemContents: pem)
        }
    }

    @Test func rsaKeyIsRejectedAsUnsupported() throws {
        guard let pem = try generateKey(type: "rsa") else { return }
        do {
            _ = try OpenSSHKeyParser.parse(pemContents: pem)
            Issue.record("RSA keys must be rejected")
        } catch let error as SSHAppError {
            guard case .privateKeyUnsupported = error else {
                Issue.record("expected privateKeyUnsupported, got \(error)")
                return
            }
        }
    }

    @Test func garbageInputIsRejected() {
        #expect(throws: SSHAppError.self) {
            _ = try OpenSSHKeyParser.parse(pemContents: "not a key at all")
        }
        #expect(throws: SSHAppError.self) {
            _ = try OpenSSHKeyParser.parse(
                pemContents: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"
            )
        }
    }

    @Test func publicKeyFileIsRejected() {
        #expect(throws: SSHAppError.self) {
            _ = try OpenSSHKeyParser.parse(pemContents: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummy generated-test")
        }
    }
}
