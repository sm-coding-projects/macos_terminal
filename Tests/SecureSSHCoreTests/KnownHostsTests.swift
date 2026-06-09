import Foundation
import Testing
@testable import SecureSSHCore

@Suite("Known hosts trust transitions")
struct KnownHostsTests {
    /// A syntactically valid OpenSSH public key encoding (random blob —
    /// generated per test, not a real server's key).
    private func randomCandidate() -> HostKeyCandidate {
        var blob = Data("\u{0}\u{0}\u{0}\u{0B}ssh-ed25519".utf8)
        blob.append(contentsOf: (0..<36).map { _ in UInt8.random(in: 0...255) })
        return HostKeyCandidate(openSSHString: "ssh-ed25519 \(blob.base64EncodedString())")
    }

    private func makeService() throws -> (FileKnownHostsService, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssht-kh-\(UUID().uuidString)", isDirectory: true)
        return (try FileKnownHostsService(directory: dir), dir)
    }

    @Test func fingerprintMatchesOpenSSHFormat() {
        let candidate = randomCandidate()
        #expect(candidate.keyType == "ssh-ed25519")
        #expect(candidate.fingerprintSHA256.hasPrefix("SHA256:"))
        #expect(!candidate.fingerprintSHA256.contains("="), "OpenSSH fingerprints strip base64 padding")
    }

    @Test func unknownHostIsFirstConnection() throws {
        let (service, dir) = try makeService()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(service.evaluate(candidate: randomCandidate(), host: "h1", port: 22) == .firstConnection)
    }

    @Test func trustThenMatchIsTrusted() throws {
        let (service, dir) = try makeService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let candidate = randomCandidate()
        try service.trust(candidate: candidate, host: "H1.example", port: 22)
        // Hostname comparison is case-insensitive.
        #expect(service.evaluate(candidate: candidate, host: "h1.example", port: 22) == .trusted)
    }

    @Test func samePortDifferentHostAreIndependent() throws {
        let (service, dir) = try makeService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let candidate = randomCandidate()
        try service.trust(candidate: candidate, host: "h1", port: 22)
        #expect(service.evaluate(candidate: candidate, host: "h2", port: 22) == .firstConnection)
        #expect(service.evaluate(candidate: candidate, host: "h1", port: 2222) == .firstConnection)
    }

    @Test func changedKeyIsBlockedAndReportsStoredEntry() throws {
        let (service, dir) = try makeService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = randomCandidate()
        let attacker = randomCandidate()
        try service.trust(candidate: original, host: "h1", port: 22)

        let verdict = service.evaluate(candidate: attacker, host: "h1", port: 22)
        guard case .changed(let stored) = verdict else {
            Issue.record("expected .changed, got \(verdict)")
            return
        }
        #expect(stored.fingerprintSHA256 == original.fingerprintSHA256)
    }

    @Test func trustRefusesToSilentlyOverwriteConflictingKey() throws {
        let (service, dir) = try makeService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = randomCandidate()
        let imposter = randomCandidate()
        try service.trust(candidate: original, host: "h1", port: 22)

        #expect(throws: KnownHostsError.conflictingEntryExists) {
            try service.trust(candidate: imposter, host: "h1", port: 22)
        }
        // Original trust is intact.
        #expect(service.evaluate(candidate: original, host: "h1", port: 22) == .trusted)
    }

    @Test func deliberateReplaceTrustsNewKey() throws {
        let (service, dir) = try makeService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = randomCandidate()
        let rotated = randomCandidate()
        try service.trust(candidate: original, host: "h1", port: 22)
        try service.replace(candidate: rotated, host: "h1", port: 22)

        #expect(service.evaluate(candidate: rotated, host: "h1", port: 22) == .trusted)
        guard case .changed = service.evaluate(candidate: original, host: "h1", port: 22) else {
            Issue.record("old key must no longer be trusted after replacement")
            return
        }
    }

    @Test func entriesPersistAcrossReopen() throws {
        let (service, dir) = try makeService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let candidate = randomCandidate()
        try service.trust(candidate: candidate, host: "h1", port: 22)

        let reopened = try FileKnownHostsService(directory: dir)
        #expect(reopened.evaluate(candidate: candidate, host: "h1", port: 22) == .trusted)
    }

    @Test func removeForgetsHost() throws {
        let (service, dir) = try makeService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let candidate = randomCandidate()
        try service.trust(candidate: candidate, host: "h1", port: 22)
        try service.remove(host: "h1", port: 22)
        #expect(service.evaluate(candidate: candidate, host: "h1", port: 22) == .firstConnection)
    }

    @Test func knownHostsFileHasOwnerOnlyPermissions() throws {
        let (service, dir) = try makeService()
        defer { try? FileManager.default.removeItem(at: dir) }
        try service.trust(candidate: randomCandidate(), host: "h1", port: 22)

        let attrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("known_hosts.json").path
        )
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
