import Foundation

/// Persists non-secret connection profile metadata.
/// Secrets never pass through this type — see `ProfileSecretsManager`.
public protocol ProfileStoring: AnyObject {
    func loadProfiles() throws -> [ConnectionProfile]
    func saveProfiles(_ profiles: [ConnectionProfile]) throws
}

public enum ProfileStoreError: Error, Equatable {
    case ioFailure(String)
}

/// JSON-file-backed store in Application Support.
/// Directory is created with 0o700 and the file written with 0o600,
/// atomically, so a crash can't leave a partially-written profile list.
public final class JSONProfileStore: ProfileStoring {
    private let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "JSONProfileStore.io")

    /// - Parameter directory: override for tests; defaults to
    ///   `~/Library/Application Support/SecureSSHTerminal`.
    public init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            dir = appSupport.appendingPathComponent("SecureSSHTerminal", isDirectory: true)
        }
        try fileManager.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.fileURL = dir.appendingPathComponent("profiles.json")
    }

    public func loadProfiles() throws -> [ConnectionProfile] {
        try queue.sync {
            guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode([ConnectionProfile].self, from: data)
            } catch {
                throw ProfileStoreError.ioFailure("Failed to read profiles: \(error.localizedDescription)")
            }
        }
    }

    public func saveProfiles(_ profiles: [ConnectionProfile]) throws {
        try queue.sync {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(profiles)
                try data.write(to: fileURL, options: [.atomic])
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                throw ProfileStoreError.ioFailure("Failed to save profiles: \(error.localizedDescription)")
            }
        }
    }
}

/// In-memory store for tests and previews.
public final class InMemoryProfileStore: ProfileStoring {
    private var profiles: [ConnectionProfile] = []
    public init(profiles: [ConnectionProfile] = []) { self.profiles = profiles }
    public func loadProfiles() throws -> [ConnectionProfile] { profiles }
    public func saveProfiles(_ profiles: [ConnectionProfile]) throws { self.profiles = profiles }
}
