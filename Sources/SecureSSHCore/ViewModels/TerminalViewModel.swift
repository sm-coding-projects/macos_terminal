import Foundation
import Combine

/// User decision for a host-key trust prompt.
public enum HostKeyDecision: Sendable {
    /// First connection: record the key and proceed.
    case trustAndSave
    /// Proceed without recording (e.g. ephemeral host).
    case trustOnce
    /// Changed key: deliberately replace the stored entry and proceed.
    case replaceAndConnect
    case cancel
}

/// What the UI must show the user before a connection can proceed.
public struct HostKeyQuestion: Sendable {
    public let host: String
    public let port: Int
    public let candidate: HostKeyCandidate
    /// Non-nil when the presented key conflicts with a stored entry.
    public let previousEntry: KnownHostEntry?

    public var isChangedKey: Bool { previousEntry != nil }

    public init(host: String, port: Int, candidate: HostKeyCandidate, previousEntry: KnownHostEntry?) {
        self.host = host
        self.port = port
        self.candidate = candidate
        self.previousEntry = previousEntry
    }
}

/// UI-side prompt provider. Implemented by the app with SwiftUI sheets;
/// by tests with canned answers.
public protocol UserPrompting: AnyObject {
    /// Returns the password, plus whether the user asked to save it.
    func requestPassword(for profile: ConnectionProfile) async -> (password: String, save: Bool)?
    func resolveHostKey(_ question: HostKeyQuestion) async -> HostKeyDecision
}

/// Drives one terminal session: resolves credentials, runs the host-key
/// trust flow, owns the live session handle, and buffers output until the
/// terminal view attaches.
@MainActor
public final class TerminalViewModel: ObservableObject, Identifiable {
    public enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(reason: String?)
        case failed(message: String)

        public var isActive: Bool {
            self == .connecting || self == .connected
        }
    }

    @Published public private(set) var state: State = .idle

    public let profile: ConnectionProfile
    public nonisolated var id: UUID { profile.id }

    private let sshService: any SSHSessionServicing
    private let knownHosts: any KnownHostsServicing
    private let secrets: ProfileSecretsManager
    private weak var prompts: (any UserPrompting)?
    private var handle: (any SSHSessionHandle)?

    /// Set by the terminal view to receive output. Output arriving before
    /// the view attaches is buffered and replayed.
    private var outputSink: ((Data) -> Void)?
    private var pendingOutput = Data()
    private var lastTerminalSize: (cols: Int, rows: Int) = (80, 24)

    /// Invoked once per successful connection (used to bump lastUsedAt).
    public var onConnected: (() -> Void)?

    public init(
        profile: ConnectionProfile,
        sshService: any SSHSessionServicing,
        knownHosts: any KnownHostsServicing,
        secrets: ProfileSecretsManager,
        prompts: any UserPrompting
    ) {
        self.profile = profile
        self.sshService = sshService
        self.knownHosts = knownHosts
        self.secrets = secrets
        self.prompts = prompts
    }

    // MARK: Output plumbing

    public func attachOutput(_ sink: @escaping (Data) -> Void) {
        outputSink = sink
        if !pendingOutput.isEmpty {
            sink(pendingOutput)
            pendingOutput.removeAll()
        }
    }

    private func deliverOutput(_ data: Data) {
        if let outputSink {
            outputSink(data)
        } else {
            pendingOutput.append(data)
        }
    }

    // MARK: Connection lifecycle

    public func connect() async {
        guard !state.isActive else { return }
        state = .connecting

        guard let credential = await resolveCredential() else {
            // resolveCredential sets .failed for hard errors (e.g. unreadable
            // key file); a user-cancelled prompt returns to idle.
            if case .failed = state {} else { state = .idle }
            return
        }

        let config = SSHConnectionConfig(
            host: profile.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: profile.port,
            username: profile.username,
            initialTerminalSize: lastTerminalSize
        )

        let callbacks = SSHSessionCallbacks(
            onOutput: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.deliverOutput(data)
                }
            },
            onStateChange: { [weak self] newState in
                Task { @MainActor [weak self] in
                    self?.applySessionState(newState)
                }
            },
            verifyHostKey: { [weak self] candidate in
                guard let self else { return false }
                return await self.runHostKeyFlow(candidate: candidate)
            }
        )

        do {
            handle = try await sshService.connect(config: config, credential: credential, callbacks: callbacks)
            // .connected arrives via onStateChange when the shell is ready.
            onConnected?()
        } catch {
            handle = nil
            state = .failed(message: Redactor.describe(error))
        }
    }

    public func disconnect() async {
        guard let handle else { return }
        self.handle = nil
        await handle.disconnect()
        if state.isActive {
            state = .disconnected(reason: "Disconnected by user")
        }
    }

    private func applySessionState(_ sessionState: SSHSessionState) {
        switch sessionState {
        case .connecting:
            state = .connecting
        case .connected:
            state = .connected
        case .disconnected(let reason):
            if state.isActive {
                state = .disconnected(reason: reason)
            }
            handle = nil
        case .failed(let message):
            state = .failed(message: message)
            handle = nil
        }
    }

    // MARK: Terminal I/O

    public func send(_ data: Data) {
        handle?.send(data)
    }

    public func sendInterrupt() {
        send(Data([0x03])) // Ctrl+C
    }

    public func sendEOF() {
        send(Data([0x04])) // Ctrl+D
    }

    public func resize(cols: Int, rows: Int) {
        lastTerminalSize = (cols, rows)
        handle?.resize(cols: cols, rows: rows)
    }

    // MARK: Credential resolution

    /// Resolves the credential for this attempt. Secrets are returned by
    /// value and not retained by the view model: after `connect()` finishes
    /// the credential goes out of scope.
    private func resolveCredential() async -> ResolvedCredential? {
        switch profile.authMethod {
        case .password:
            if profile.saveCredentials,
               let saved = try? secrets.readPassword(for: profile), !saved.isEmpty {
                return .password(saved)
            }
            guard let prompts, let answer = await prompts.requestPassword(for: profile) else {
                return nil
            }
            if answer.save && profile.saveCredentials {
                try? secrets.savePassword(answer.password, for: profile)
            }
            return .password(answer.password)

        case .privateKey:
            let rawPath = profile.privateKeyPath ?? ""
            let path = (rawPath as NSString).expandingTildeInPath
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                state = .failed(message: SSHAppError.privateKeyUnreadable(path: rawPath).errorDescription ?? "Key unreadable")
                return nil
            }
            let passphrase = profile.saveCredentials ? (try? secrets.readPassphrase(for: profile)) ?? nil : nil
            return .privateKey(fileContents: contents, passphrase: passphrase)
        }
    }

    // MARK: Host key flow

    /// Implements the trust policy:
    ///  - known & matching: proceed silently
    ///  - first connection: show fingerprint, require explicit trust
    ///  - changed key: block; proceed only on deliberate replacement
    private func runHostKeyFlow(candidate: HostKeyCandidate) async -> Bool {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = knownHosts.evaluate(candidate: candidate, host: host, port: profile.port)

        switch verdict {
        case .trusted:
            return true

        case .firstConnection:
            guard let prompts else { return false }
            let question = HostKeyQuestion(host: host, port: profile.port, candidate: candidate, previousEntry: nil)
            switch await prompts.resolveHostKey(question) {
            case .trustAndSave:
                do {
                    try knownHosts.trust(candidate: candidate, host: host, port: profile.port)
                } catch {
                    return false
                }
                return true
            case .trustOnce:
                return true
            case .replaceAndConnect, .cancel:
                return false
            }

        case .changed(let stored):
            guard let prompts else { return false }
            let question = HostKeyQuestion(host: host, port: profile.port, candidate: candidate, previousEntry: stored)
            switch await prompts.resolveHostKey(question) {
            case .replaceAndConnect:
                do {
                    try knownHosts.replace(candidate: candidate, host: host, port: profile.port)
                } catch {
                    return false
                }
                return true
            case .trustAndSave, .trustOnce, .cancel:
                // A changed key is never accepted implicitly.
                return false
            }
        }
    }
}
