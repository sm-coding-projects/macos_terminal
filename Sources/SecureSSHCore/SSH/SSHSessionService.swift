import Foundation

/// Connection parameters for one session. Credential material is held only
/// for the duration of the connect call and is never persisted by the
/// session layer.
public struct SSHConnectionConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var initialTerminalSize: (cols: Int, rows: Int)

    public init(host: String, port: Int, username: String, initialTerminalSize: (cols: Int, rows: Int) = (80, 24)) {
        self.host = host
        self.port = port
        self.username = username
        self.initialTerminalSize = initialTerminalSize
    }
}

/// Credential resolved just-in-time for a connection attempt.
public enum ResolvedCredential: Sendable {
    case password(String)
    /// Raw contents of a private key file. Parsed by the SSH backend.
    case privateKey(fileContents: String, passphrase: String?)
}

/// Lifecycle states reported by a session.
public enum SSHSessionState: Equatable, Sendable {
    case connecting
    case connected
    case disconnected(reason: String?)
    case failed(message: String)
}

/// Event sinks for a session. All callbacks may be invoked from background
/// threads; consumers must hop to the main actor themselves.
public struct SSHSessionCallbacks: Sendable {
    public var onOutput: @Sendable (Data) -> Void
    public var onStateChange: @Sendable (SSHSessionState) -> Void
    /// Asked exactly once per connection with the server's host key.
    /// Return true to proceed, false to abort the handshake.
    /// Host-key verification cannot be skipped: there is no configuration
    /// that bypasses this callback.
    public var verifyHostKey: @Sendable (HostKeyCandidate) async -> Bool

    public init(
        onOutput: @escaping @Sendable (Data) -> Void,
        onStateChange: @escaping @Sendable (SSHSessionState) -> Void,
        verifyHostKey: @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) {
        self.onOutput = onOutput
        self.onStateChange = onStateChange
        self.verifyHostKey = verifyHostKey
    }
}

/// A live interactive session.
public protocol SSHSessionHandle: AnyObject, Sendable {
    func send(_ data: Data)
    func resize(cols: Int, rows: Int)
    func disconnect() async
}

/// Creates interactive SSH sessions. Implemented by `NIOSSHSessionService`
/// (production) and `MockSSHSessionService` (tests).
public protocol SSHSessionServicing: AnyObject, Sendable {
    func connect(
        config: SSHConnectionConfig,
        credential: ResolvedCredential,
        callbacks: SSHSessionCallbacks
    ) async throws -> any SSHSessionHandle
}
