import Foundation
import Testing
@testable import SecureSSHCore

@Suite("Profile validation")
struct ProfileValidationTests {
    private func validProfile() -> ConnectionProfile {
        ConnectionProfile(displayName: "Test Server", host: "example.com", username: "admin")
    }

    @Test func validProfilePasses() {
        #expect(ProfileValidator.validate(validProfile()).isEmpty)
    }

    @Test func defaultPortIs22() {
        #expect(ConnectionProfile().port == 22)
    }

    @Test func emptyDisplayNameRejected() {
        var p = validProfile()
        p.displayName = "   "
        #expect(ProfileValidator.validate(p).contains(.emptyDisplayName))
    }

    @Test func emptyHostRejected() {
        var p = validProfile()
        p.host = ""
        #expect(ProfileValidator.validate(p).contains(.emptyHost))
    }

    @Test func hostWithSpacesRejected() {
        var p = validProfile()
        p.host = "bad host name"
        #expect(ProfileValidator.validate(p).contains(.invalidHost))
    }

    @Test func ipv6HostAccepted() {
        var p = validProfile()
        p.host = "fe80::1%en0"
        #expect(ProfileValidator.validate(p).isEmpty)
    }

    @Test(arguments: [0, -5, 65536, 100_000])
    func outOfRangePortRejected(port: Int) {
        var p = validProfile()
        p.port = port
        #expect(ProfileValidator.validate(p).contains(.invalidPort))
    }

    @Test(arguments: [1, 22, 2222, 65535])
    func inRangePortAccepted(port: Int) {
        var p = validProfile()
        p.port = port
        #expect(!ProfileValidator.validate(p).contains(.invalidPort))
    }

    @Test func emptyUsernameRejected() {
        var p = validProfile()
        p.username = ""
        #expect(ProfileValidator.validate(p).contains(.emptyUsername))
    }

    @Test func privateKeyAuthRequiresKeyPath() {
        var p = validProfile()
        p.authMethod = .privateKey
        p.privateKeyPath = nil
        #expect(ProfileValidator.validate(p).contains(.missingPrivateKeyPath))
        p.privateKeyPath = "~/.ssh/id_ed25519"
        #expect(ProfileValidator.validate(p).isEmpty)
    }

    @Test func multipleErrorsReportedTogether() {
        let p = ConnectionProfile()
        let errors = ProfileValidator.validate(p)
        #expect(errors.contains(.emptyDisplayName))
        #expect(errors.contains(.emptyHost))
        #expect(errors.contains(.emptyUsername))
    }

    @Test func duplicateGetsFreshIdentityAndNoCredentialOptIn() {
        var p = validProfile()
        p.saveCredentials = true
        p.lastUsedAt = Date()
        let copy = p.duplicated()
        #expect(copy.id != p.id)
        #expect(copy.displayName == "Test Server Copy")
        #expect(copy.lastUsedAt == nil)
        #expect(copy.saveCredentials == false)
        #expect(copy.host == p.host)
        #expect(copy.username == p.username)
    }
}

@Suite("Profile store persistence")
struct ProfileStoreTests {
    private func makeTempStore() throws -> (JSONProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssht-tests-\(UUID().uuidString)", isDirectory: true)
        return (try JSONProfileStore(directory: dir), dir)
    }

    @Test func emptyStoreLoadsNoProfiles() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.loadProfiles().isEmpty)
    }

    @Test func roundTripPreservesAllFields() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = ConnectionProfile(
            displayName: "Prod",
            host: "10.0.0.5",
            port: 2222,
            username: "deploy",
            authMethod: .privateKey,
            privateKeyPath: "~/.ssh/id_ed25519",
            notes: "Primary box",
            saveCredentials: true,
            requireUserPresence: true,
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.saveProfiles([profile])

        // Re-open from disk to prove persistence, not caching.
        let reopened = try JSONProfileStore(directory: dir)
        let loaded = try reopened.loadProfiles()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == profile.id)
        #expect(loaded[0].displayName == "Prod")
        #expect(loaded[0].port == 2222)
        #expect(loaded[0].authMethod == .privateKey)
        #expect(loaded[0].privateKeyPath == "~/.ssh/id_ed25519")
        #expect(loaded[0].saveCredentials)
        #expect(loaded[0].requireUserPresence)
        #expect(loaded[0].lastUsedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func updatesAndDeletionsPersist() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var a = ConnectionProfile(displayName: "A", host: "a.example", username: "u")
        let b = ConnectionProfile(displayName: "B", host: "b.example", username: "u")
        try store.saveProfiles([a, b])

        a.displayName = "A renamed"
        try store.saveProfiles([a]) // b deleted
        let loaded = try store.loadProfiles()
        #expect(loaded.count == 1)
        #expect(loaded[0].displayName == "A renamed")
        #expect(loaded[0].id == a.id)
        _ = b
    }

    @Test func profileFileHasOwnerOnlyPermissions() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveProfiles([ConnectionProfile(displayName: "X", host: "x", username: "u")])

        let attrs = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("profiles.json").path
        )
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
    }

    @Test func storedJSONContainsNoSecretFields() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = ConnectionProfile(displayName: "X", host: "x", username: "u")
        p.saveCredentials = true
        try store.saveProfiles([p])

        // The persisted JSON may name "password" as the auth *method*, but
        // must never contain a field that stores secret material.
        let data = try Data(contentsOf: dir.appendingPathComponent("profiles.json"))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let keys = Set((decoded?.first ?? [:]).keys.map { $0.lowercased() })
        let allowedKeys: Set<String> = [
            "id", "displayname", "host", "port", "username", "authmethod",
            "privatekeypath", "notes", "savecredentials", "requireuserpresence",
            "createdat", "lastusedat",
        ]
        #expect(keys.isSubset(of: allowedKeys), "unexpected fields in profiles.json: \(keys.subtracting(allowedKeys))")
        #expect(!keys.contains("password"))
        #expect(!keys.contains("passphrase"))
    }
}
