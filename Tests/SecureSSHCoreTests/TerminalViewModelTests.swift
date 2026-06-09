import Foundation
import Testing
@testable import SecureSSHCore

// MARK: - Mocks

final class MockSSHHandle: SSHSessionHandle, @unchecked Sendable {
    private(set) var sent: [Data] = []
    private(set) var resizes: [(cols: Int, rows: Int)] = []
    private(set) var disconnected = false
    var onDisconnect: (() -> Void)?

    func send(_ data: Data) { sent.append(data) }
    func resize(cols: Int, rows: Int) { resizes.append((cols, rows)) }
    func disconnect() async {
        disconnected = true
        onDisconnect?()
    }
}

/// Scriptable SSH backend. Runs the host-key callback exactly like the real
/// service, then either succeeds (emitting `.connected` and optional output)
/// or throws.
final class MockSSHSessionService: SSHSessionServicing, @unchecked Sendable {
    enum Behavior {
        case success(initialOutput: Data?)
        case failure(Error)
    }

    var behavior: Behavior = .success(initialOutput: nil)
    var presentedHostKey = HostKeyCandidate(openSSHString: "ssh-ed25519 AAAAB3NzaMockKeyBlob")
    private(set) var lastConfig: SSHConnectionConfig?
    private(set) var lastCredential: ResolvedCredential?
    private(set) var lastHandle: MockSSHHandle?
    private(set) var connectCallCount = 0

    func connect(
        config: SSHConnectionConfig,
        credential: ResolvedCredential,
        callbacks: SSHSessionCallbacks
    ) async throws -> any SSHSessionHandle {
        connectCallCount += 1
        lastConfig = config
        lastCredential = credential

        guard await callbacks.verifyHostKey(presentedHostKey) else {
            throw SSHAppError.hostKeyRejected
        }

        switch behavior {
        case .failure(let error):
            throw error
        case .success(let initialOutput):
            let handle = MockSSHHandle()
            handle.onDisconnect = { callbacks.onStateChange(.disconnected(reason: nil)) }
            lastHandle = handle
            callbacks.onStateChange(.connected)
            if let initialOutput {
                callbacks.onOutput(initialOutput)
            }
            return handle
        }
    }
}

final class MockPrompts: UserPrompting, @unchecked Sendable {
    var passwordAnswer: (password: String, save: Bool)?
    var hostKeyDecision: HostKeyDecision = .trustAndSave
    private(set) var passwordRequests = 0
    private(set) var hostKeyQuestions: [HostKeyQuestion] = []

    func requestPassword(for profile: ConnectionProfile) async -> (password: String, save: Bool)? {
        passwordRequests += 1
        return passwordAnswer
    }

    func resolveHostKey(_ question: HostKeyQuestion) async -> HostKeyDecision {
        hostKeyQuestions.append(question)
        return hostKeyDecision
    }
}

final class MockKnownHosts: KnownHostsServicing, @unchecked Sendable {
    var entries: [String: HostKeyCandidate] = [:]
    private(set) var trustCalls = 0
    private(set) var replaceCalls = 0

    private func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    func evaluate(candidate: HostKeyCandidate, host: String, port: Int) -> HostKeyVerdict {
        guard let stored = entries[key(host, port)] else { return .firstConnection }
        if stored == candidate { return .trusted }
        return .changed(stored: KnownHostEntry(host: host, port: port, candidate: stored))
    }

    func trust(candidate: HostKeyCandidate, host: String, port: Int) throws {
        trustCalls += 1
        entries[key(host, port)] = candidate
    }

    func replace(candidate: HostKeyCandidate, host: String, port: Int) throws {
        replaceCalls += 1
        entries[key(host, port)] = candidate
    }

    func remove(host: String, port: Int) throws { entries.removeValue(forKey: key(host, port)) }
    func allEntries() -> [KnownHostEntry] { [] }
}

// MARK: - Helpers

@MainActor
private func makeVM(
    profile: ConnectionProfile? = nil,
    service: MockSSHSessionService = MockSSHSessionService(),
    prompts: MockPrompts = MockPrompts(),
    knownHosts: MockKnownHosts = MockKnownHosts(),
    keychain: InMemoryKeychainService = InMemoryKeychainService()
) -> (TerminalViewModel, MockSSHSessionService, MockPrompts, MockKnownHosts, InMemoryKeychainService) {
    let profile = profile ?? ConnectionProfile(
        displayName: "Test",
        host: "test.example",
        username: "user"
    )
    let vm = TerminalViewModel(
        profile: profile,
        sshService: service,
        knownHosts: knownHosts,
        secrets: ProfileSecretsManager(keychain: keychain),
        prompts: prompts
    )
    return (vm, service, prompts, knownHosts, keychain)
}

/// The session state lands via main-actor hops; poll briefly for it.
@MainActor
private func waitFor(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: - Tests

@Suite("Terminal view model")
@MainActor
struct TerminalViewModelTests {
    @Test func successfulPasswordConnectReachesConnectedAndFiresOnConnected() async {
        let prompts = MockPrompts()
        prompts.passwordAnswer = (password: UUID().uuidString, save: false)
        let (vm, service, _, _, _) = makeVM(prompts: prompts)

        var connectedCallbackFired = false
        vm.onConnected = { connectedCallbackFired = true }

        await vm.connect()
        await waitFor { vm.state == .connected }

        #expect(vm.state == .connected)
        #expect(connectedCallbackFired)
        #expect(service.lastConfig?.host == "test.example")
        #expect(service.lastConfig?.port == 22)
    }

    @Test func cancellingPasswordPromptReturnsToIdleWithoutConnecting() async {
        let prompts = MockPrompts()
        prompts.passwordAnswer = nil // user hits Cancel
        let (vm, service, _, _, _) = makeVM(prompts: prompts)

        await vm.connect()

        #expect(vm.state == .idle)
        #expect(service.connectCallCount == 0)
    }

    @Test func savedPasswordIsUsedWithoutPrompting() async throws {
        let keychain = InMemoryKeychainService()
        var profile = ConnectionProfile(displayName: "T", host: "h", username: "u")
        profile.saveCredentials = true
        let secrets = ProfileSecretsManager(keychain: keychain)
        let stored = UUID().uuidString
        try secrets.savePassword(stored, for: profile)

        let prompts = MockPrompts()
        let (vm, service, _, _, _) = makeVM(profile: profile, prompts: prompts, keychain: keychain)

        await vm.connect()
        await waitFor { vm.state == .connected }

        #expect(prompts.passwordRequests == 0, "saved credential must not trigger a prompt")
        guard case .password(let used)? = service.lastCredential else {
            Issue.record("expected password credential")
            return
        }
        #expect(used == stored)
    }

    @Test func firstConnectionTrustAndSaveRecordsKey() async {
        let prompts = MockPrompts()
        prompts.passwordAnswer = (password: UUID().uuidString, save: false)
        prompts.hostKeyDecision = .trustAndSave
        let (vm, service, _, knownHosts, _) = makeVM(prompts: prompts)

        await vm.connect()
        await waitFor { vm.state == .connected }

        #expect(vm.state == .connected)
        #expect(knownHosts.trustCalls == 1)
        #expect(prompts.hostKeyQuestions.count == 1)
        #expect(prompts.hostKeyQuestions.first?.isChangedKey == false)
        // Second connection: now trusted, no prompt.
        await vm.disconnect()
        await vm.connect()
        await waitFor { vm.state == .connected }
        #expect(prompts.hostKeyQuestions.count == 1, "trusted key must not prompt again")
        _ = service
    }

    @Test func rejectingFirstConnectionFailsWithHostKeyError() async {
        let prompts = MockPrompts()
        prompts.passwordAnswer = (password: UUID().uuidString, save: false)
        prompts.hostKeyDecision = .cancel
        let (vm, _, _, knownHosts, _) = makeVM(prompts: prompts)

        await vm.connect()

        guard case .failed(let message) = vm.state else {
            Issue.record("expected failure, got \(vm.state)")
            return
        }
        #expect(message.contains("host key was not trusted"))
        #expect(knownHosts.trustCalls == 0)
    }

    @Test func changedHostKeyIsBlockedUnlessDeliberatelyReplaced() async {
        let knownHosts = MockKnownHosts()
        let service = MockSSHSessionService()
        // Pre-trust a *different* key for this host.
        knownHosts.entries["test.example:22"] = HostKeyCandidate(openSSHString: "ssh-ed25519 AAAAOldStoredKey")

        let prompts = MockPrompts()
        prompts.passwordAnswer = (password: UUID().uuidString, save: false)
        prompts.hostKeyDecision = .trustAndSave // NOT an explicit replacement
        let (vm, _, _, _, _) = makeVM(service: service, prompts: prompts, knownHosts: knownHosts)

        await vm.connect()

        guard case .failed = vm.state else {
            Issue.record("changed key must block, got \(vm.state)")
            return
        }
        #expect(prompts.hostKeyQuestions.first?.isChangedKey == true)
        #expect(knownHosts.replaceCalls == 0)

        // Deliberate replacement is the only path through.
        prompts.hostKeyDecision = .replaceAndConnect
        await vm.connect()
        await waitFor { vm.state == .connected }
        #expect(vm.state == .connected)
        #expect(knownHosts.replaceCalls == 1)
    }

    @Test func outputBeforeViewAttachIsBufferedAndReplayed() async {
        let banner = Data("Welcome to test.example\r\n".utf8)
        let service = MockSSHSessionService()
        service.behavior = .success(initialOutput: banner)
        let prompts = MockPrompts()
        prompts.passwordAnswer = (password: UUID().uuidString, save: false)
        let (vm, _, _, _, _) = makeVM(service: service, prompts: prompts)

        await vm.connect()
        await waitFor { vm.state == .connected }
        // Output was delivered before any sink attached; let it land.
        await waitFor { true }

        var received = Data()
        vm.attachOutput { received.append($0) }
        await waitFor { !received.isEmpty }
        #expect(received == banner)
    }

    @Test func sendAndControlSequencesReachTheSession() async {
        let prompts = MockPrompts()
        prompts.passwordAnswer = (password: UUID().uuidString, save: false)
        let (vm, service, _, _, _) = makeVM(prompts: prompts)

        await vm.connect()
        await waitFor { vm.state == .connected }

        vm.send(Data("ls\n".utf8))
        vm.sendInterrupt()
        vm.sendEOF()
        vm.resize(cols: 120, rows: 40)

        let handle = service.lastHandle
        #expect(handle?.sent.count == 3)
        #expect(handle?.sent[1] == Data([0x03]), "Ctrl+C must send ETX")
        #expect(handle?.sent[2] == Data([0x04]), "Ctrl+D must send EOT")
        #expect(handle?.resizes.last?.cols == 120)
        #expect(handle?.resizes.last?.rows == 40)
    }

    @Test func disconnectCleansUpAndReportsState() async {
        let prompts = MockPrompts()
        prompts.passwordAnswer = (password: UUID().uuidString, save: false)
        let (vm, service, _, _, _) = makeVM(prompts: prompts)

        await vm.connect()
        await waitFor { vm.state == .connected }

        await vm.disconnect()
        #expect(service.lastHandle?.disconnected == true)
        guard case .disconnected = vm.state else {
            Issue.record("expected disconnected, got \(vm.state)")
            return
        }
    }

    @Test func connectionFailureSurfacesFriendlyRedactedMessage() async {
        let service = MockSSHSessionService()
        service.behavior = .failure(SSHAppError.authenticationFailed)
        let prompts = MockPrompts()
        let secretPassword = UUID().uuidString
        prompts.passwordAnswer = (password: secretPassword, save: false)
        let (vm, _, _, _, _) = makeVM(service: service, prompts: prompts)

        await vm.connect()

        guard case .failed(let message) = vm.state else {
            Issue.record("expected failed state")
            return
        }
        #expect(message.contains("Authentication failed"))
        #expect(!message.contains(secretPassword), "error messages must never contain the password")
    }

    @Test func missingKeyFileFailsWithoutNetworkAttempt() async {
        var profile = ConnectionProfile(displayName: "T", host: "h", username: "u")
        profile.authMethod = .privateKey
        profile.privateKeyPath = "/nonexistent/path/id_ed25519"
        let (vm, service, _, _, _) = makeVM(profile: profile)

        await vm.connect()

        guard case .failed(let message) = vm.state else {
            Issue.record("expected failed state")
            return
        }
        #expect(message.contains("could not be read"))
        #expect(service.connectCallCount == 0)
    }
}
