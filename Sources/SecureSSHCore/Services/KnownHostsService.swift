import Foundation
import Crypto

/// A host key presented by a server during connection, in a
/// transport-agnostic form suitable for display and persistence.
public struct HostKeyCandidate: Equatable, Sendable {
    /// Key algorithm identifier, e.g. "ssh-ed25519".
    public let keyType: String
    /// Full OpenSSH-format public key string: "<type> <base64-blob>".
    public let openSSHString: String
    /// OpenSSH-style fingerprint: "SHA256:<base64-no-padding>".
    public let fingerprintSHA256: String

    public init(openSSHString: String) {
        let parts = openSSHString.split(separator: " ")
        self.keyType = parts.first.map(String.init) ?? "unknown"
        self.openSSHString = openSSHString
        if parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) {
            let digest = SHA256.hash(data: blob)
            let b64 = Data(digest).base64EncodedString()
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            self.fingerprintSHA256 = "SHA256:\(b64)"
        } else {
            self.fingerprintSHA256 = "SHA256:invalid-key-encoding"
        }
    }
}

/// A persisted trust decision for one host:port.
public struct KnownHostEntry: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let openSSHString: String
    public let fingerprintSHA256: String
    public let addedAt: Date

    public init(host: String, port: Int, candidate: HostKeyCandidate, addedAt: Date = Date()) {
        self.host = host.lowercased()
        self.port = port
        self.keyType = candidate.keyType
        self.openSSHString = candidate.openSSHString
        self.fingerprintSHA256 = candidate.fingerprintSHA256
        self.addedAt = addedAt
    }
}

/// Outcome of checking a presented key against the known-hosts store.
public enum HostKeyVerdict: Equatable, Sendable {
    /// Key matches the stored entry — proceed silently.
    case trusted
    /// No entry for this host:port — first connection, user must decide.
    case firstConnection
    /// Entry exists but the key differs — block by default.
    case changed(stored: KnownHostEntry)
}

public protocol KnownHostsServicing: AnyObject {
    func evaluate(candidate: HostKeyCandidate, host: String, port: Int) -> HostKeyVerdict
    /// Records trust for a first connection. Refuses to silently overwrite a
    /// conflicting entry — use `replace` for that deliberate action.
    func trust(candidate: HostKeyCandidate, host: String, port: Int) throws
    /// Deliberately replaces a changed key. Only valid path after `.changed`.
    func replace(candidate: HostKeyCandidate, host: String, port: Int) throws
    func remove(host: String, port: Int) throws
    func allEntries() -> [KnownHostEntry]
}

public enum KnownHostsError: Error, Equatable {
    case conflictingEntryExists
    case ioFailure(String)
}

/// JSON-file-backed known-hosts store with 0o600 permissions, kept in the
/// app's Application Support directory (inside the sandbox container when
/// the app is sandboxed).
public final class FileKnownHostsService: KnownHostsServicing {
    private let fileURL: URL
    private let fileManager: FileManager
    private var entries: [KnownHostEntry]
    private let queue = DispatchQueue(label: "FileKnownHostsService.io")

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
        self.fileURL = dir.appendingPathComponent("known_hosts.json")

        if fileManager.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.entries = (try? decoder.decode([KnownHostEntry].self, from: data)) ?? []
        } else {
            self.entries = []
        }
    }

    public func evaluate(candidate: HostKeyCandidate, host: String, port: Int) -> HostKeyVerdict {
        queue.sync {
            guard let stored = lookup(host: host, port: port) else {
                return .firstConnection
            }
            if stored.openSSHString == candidate.openSSHString {
                return .trusted
            }
            return .changed(stored: stored)
        }
    }

    public func trust(candidate: HostKeyCandidate, host: String, port: Int) throws {
        try queue.sync {
            if let stored = lookup(host: host, port: port),
               stored.openSSHString != candidate.openSSHString {
                throw KnownHostsError.conflictingEntryExists
            }
            upsert(KnownHostEntry(host: host, port: port, candidate: candidate))
            try persist()
        }
    }

    public func replace(candidate: HostKeyCandidate, host: String, port: Int) throws {
        try queue.sync {
            upsert(KnownHostEntry(host: host, port: port, candidate: candidate))
            try persist()
        }
    }

    public func remove(host: String, port: Int) throws {
        try queue.sync {
            entries.removeAll { $0.host == host.lowercased() && $0.port == port }
            try persist()
        }
    }

    public func allEntries() -> [KnownHostEntry] {
        queue.sync { entries }
    }

    // MARK: private (call only from queue)

    private func lookup(host: String, port: Int) -> KnownHostEntry? {
        entries.first { $0.host == host.lowercased() && $0.port == port }
    }

    private func upsert(_ entry: KnownHostEntry) {
        entries.removeAll { $0.host == entry.host && $0.port == entry.port }
        entries.append(entry)
    }

    private func persist() throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw KnownHostsError.ioFailure(error.localizedDescription)
        }
    }
}
