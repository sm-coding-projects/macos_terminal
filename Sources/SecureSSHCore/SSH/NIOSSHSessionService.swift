import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Production SSH backend built on SwiftNIO SSH.
///
/// Design notes:
///  - Host-key verification is mandatory: `HostKeyVerificationDelegate`
///    always consults the `verifyHostKey` callback and fails the handshake
///    unless it returns true. There is no accept-all code path.
///  - Authentication offers each credential once; when the server rejects
///    it, the handshake fails with `SSHAppError.authenticationFailed`
///    rather than looping.
public final class NIOSSHSessionService: SSHSessionServicing, @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup

    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        group.shutdownGracefully { _ in }
    }

    public func connect(
        config: SSHConnectionConfig,
        credential: ResolvedCredential,
        callbacks: SSHSessionCallbacks
    ) async throws -> any SSHSessionHandle {
        // Parse key material up front so failures surface as friendly errors
        // before any network traffic.
        let authDelegate: ClientAuthDelegate
        switch credential {
        case .password(let password):
            authDelegate = ClientAuthDelegate(username: config.username, method: .password(password))
        case .privateKey(let fileContents, _):
            let key = try OpenSSHKeyParser.parse(pemContents: fileContents)
            authDelegate = ClientAuthDelegate(username: config.username, method: .privateKey(key))
        }

        let errorRecorder = ConnectionErrorRecorder()
        let serverAuthDelegate = HostKeyVerificationDelegate(
            verify: callbacks.verifyHostKey,
            recorder: errorRecorder
        )

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: authDelegate,
                            serverAuthDelegate: serverAuthDelegate
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    ),
                    ErrorRecordingHandler(recorder: errorRecorder),
                ])
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: config.host, port: config.port).get()
        } catch let error as NIOConnectionError {
            throw SSHAppError.connectionFailed(reason: friendlyConnectReason(error))
        } catch is ChannelError {
            throw SSHAppError.connectionFailed(reason: "the connection could not be established")
        } catch {
            throw errorRecorder.mapped(fallback: error)
        }

        do {
            let childChannel = try await createShellChannel(
                parent: channel,
                config: config,
                callbacks: callbacks,
                recorder: errorRecorder
            )
            let session = NIOSSHSession(parent: channel, child: childChannel)
            return session
        } catch {
            try? await channel.close().get()
            throw errorRecorder.mapped(fallback: error)
        }
    }

    private func createShellChannel(
        parent: Channel,
        config: SSHConnectionConfig,
        callbacks: SSHSessionCallbacks,
        recorder: ConnectionErrorRecorder
    ) async throws -> Channel {
        let childPromise = parent.eventLoop.makePromise(of: Channel.self)
        let shellReadyPromise = parent.eventLoop.makePromise(of: Void.self)

        parent.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .failure(let error):
                childPromise.fail(error)
            case .success(let sshHandler):
                sshHandler.createChannel(childPromise, channelType: .session) { childChannel, _ in
                    childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        childChannel.pipeline.addHandler(
                            InteractiveShellHandler(
                                terminalSize: config.initialTerminalSize,
                                callbacks: callbacks,
                                shellReady: shellReadyPromise
                            )
                        )
                    }
                }
            }
        }

        let child = try await childPromise.futureResult.get()
        do {
            try await shellReadyPromise.futureResult.get()
        } catch {
            throw recorder.mapped(fallback: SSHAppError.channelSetupFailed)
        }
        return child
    }

    private func friendlyConnectReason(_ error: NIOConnectionError) -> String {
        if error.connectionErrors.isEmpty {
            return "host not found or unreachable"
        }
        return "the host refused the connection or is unreachable"
    }
}

// MARK: - Session handle

final class NIOSSHSession: SSHSessionHandle, @unchecked Sendable {
    private let parent: Channel
    private let child: Channel

    init(parent: Channel, child: Channel) {
        self.parent = parent
        self.child = child
    }

    func send(_ data: Data) {
        guard child.isActive else { return }
        var buffer = child.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        child.writeAndFlush(buffer, promise: nil)
    }

    func resize(cols: Int, rows: Int) {
        guard child.isActive else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        child.triggerUserOutboundEvent(event, promise: nil)
    }

    func disconnect() async {
        _ = try? await child.close().get()
        _ = try? await parent.close().get()
    }
}

// MARK: - Interactive shell channel handler

/// Bridges the SSH session channel to the callbacks: requests a PTY and a
/// shell on activation, converts inbound `SSHChannelData` to raw bytes, and
/// wraps outbound bytes back into `SSHChannelData`.
final class InteractiveShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let terminalSize: (cols: Int, rows: Int)
    private let callbacks: SSHSessionCallbacks
    private let shellReady: EventLoopPromise<Void>
    private var pendingRequestSuccesses = 0
    private var shellStarted = false
    private var exitStatus: Int? = nil

    init(terminalSize: (cols: Int, rows: Int), callbacks: SSHSessionCallbacks, shellReady: EventLoopPromise<Void>) {
        self.terminalSize = terminalSize
        self.callbacks = callbacks
        self.shellReady = shellReady
    }

    func channelActive(context: ChannelHandlerContext) {
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: terminalSize.cols,
            terminalRowHeight: terminalSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        pendingRequestSuccesses = 2
        context.triggerUserOutboundEvent(ptyRequest, promise: nil)
        context.triggerUserOutboundEvent(shellRequest, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else {
            return
        }
        // Deliver both stdout and stderr streams to the terminal.
        let bytes = Data(buffer.readableBytesView)
        if !bytes.isEmpty {
            callbacks.onOutput(bytes)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if !shellStarted {
                pendingRequestSuccesses -= 1
                if pendingRequestSuccesses <= 0 {
                    shellStarted = true
                    shellReady.succeed(())
                    callbacks.onStateChange(.connected)
                }
            }
        case is ChannelFailureEvent:
            if !shellStarted {
                shellReady.fail(SSHAppError.channelSetupFailed)
            }
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !shellStarted {
            shellReady.fail(SSHAppError.channelSetupFailed)
        } else {
            let reason = exitStatus.map { "exit status \($0)" }
            callbacks.onStateChange(.disconnected(reason: reason))
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !shellStarted {
            shellReady.fail(error)
        }
        context.close(promise: nil)
    }
}

// MARK: - Authentication delegates

/// Offers the configured credential exactly once.
final class ClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    enum Method {
        case password(String)
        case privateKey(NIOSSHPrivateKey)
    }

    private let username: String
    private let method: Method
    private var attempted = false

    init(username: String, method: Method) {
        self.username = username
        self.method = method
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !attempted else {
            // The server rejected our one credential — fail rather than loop.
            nextChallengePromise.fail(SSHAppError.authenticationFailed)
            return
        }
        attempted = true

        switch method {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.fail(SSHAppError.authenticationFailed)
                return
            }
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .password(.init(password: password))
            ))
        case .privateKey(let key):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.fail(SSHAppError.authenticationFailed)
                return
            }
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: key))
            ))
        }
    }
}

/// Validates the server host key through the app's known-hosts flow.
/// Fails the handshake unless the verification callback explicitly approves.
final class HostKeyVerificationDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let verify: @Sendable (HostKeyCandidate) async -> Bool
    private let recorder: ConnectionErrorRecorder

    init(verify: @escaping @Sendable (HostKeyCandidate) async -> Bool, recorder: ConnectionErrorRecorder) {
        self.verify = verify
        self.recorder = recorder
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let candidate = HostKeyCandidate(openSSHString: String(openSSHPublicKey: hostKey))
        let verify = self.verify
        let recorder = self.recorder
        Task {
            if await verify(candidate) {
                validationCompletePromise.succeed(())
            } else {
                recorder.record(SSHAppError.hostKeyRejected)
                validationCompletePromise.fail(SSHAppError.hostKeyRejected)
            }
        }
    }
}

// MARK: - Error plumbing

/// Captures the first meaningful error seen on the connection so that the
/// generic "channel closed" failures NIO surfaces can be replaced with the
/// real cause (auth failure, host key rejection, ...).
final class ConnectionErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Error?

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if first == nil { first = error }
    }

    func mapped(fallback: Error) -> Error {
        lock.lock()
        defer { lock.unlock() }
        if let appError = first as? SSHAppError { return appError }
        if let appError = fallback as? SSHAppError { return appError }
        if let recorded = first { return Self.translate(recorded) }
        return Self.translate(fallback)
    }

    private static func translate(_ error: Error) -> Error {
        if let sshError = error as? NIOSSHError {
            switch sshError.type {
            case .protocolViolation, .keyExchangeNegotiationFailure:
                return SSHAppError.connectionFailed(reason: "the server speaks an incompatible SSH protocol")
            default:
                break
            }
        }
        if error is NIOSSHError {
            // Most post-handshake failures with no recorded cause are auth rejections.
            return SSHAppError.authenticationFailed
        }
        return error
    }
}

final class ErrorRecordingHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private let recorder: ConnectionErrorRecorder

    init(recorder: ConnectionErrorRecorder) {
        self.recorder = recorder
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        recorder.record(error)
        context.close(promise: nil)
    }
}
