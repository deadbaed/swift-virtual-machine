import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import NIOSSH

enum SSHProvisioningError: Error, CustomStringConvertible {
    case invalidChannelType
    case missingExitStatus
    case commandExecFailed
    case execFailed(String)

    var description: String {
        switch self {
        case .invalidChannelType:
            return "SSH channel type was not a session"
        case .missingExitStatus:
            return "SSH channel closed without an exit status"
        case .commandExecFailed:
            return "SSH exec handler removed before completion"
        case .execFailed(let message):
            return "SSH exec failed: \(message)"
        }
    }
}

struct SSHExecResult {
    let exitStatus: Int
    let stdout: String
    let stderr: String
}

// MARK: - Authentication Delegates

/// Accepts any host key. Only safe because the VM is local and provisioned by this tool.
final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

/// Provides a single username/password authentication offer.
final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let password: String
    private let hasOffered: NIOLockedValueBox<Bool>

    init(username: String, password: String) {
        self.username = username
        self.password = password
        self.hasOffered = NIOLockedValueBox(false)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let shouldOffer = self.hasOffered.withLockedValue { offered in
            guard !offered, availableMethods.contains(.password) else {
                return false
            }
            offered = true
            return true
        }

        if shouldOffer {
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .password(.init(password: password))
            )
            nextChallengePromise.succeed(offer)
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

// MARK: - Exec Handler

/// Runs a single SSH exec request, feeding optional stdin and collecting stdout/stderr.
final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let input: ByteBuffer?
    private var completionPromise: EventLoopPromise<SSHExecResult>?

    private var stdout: ByteBuffer
    private var stderr: ByteBuffer
    private var exitStatus: Int?

    init(command: String, input: ByteBuffer?, completionPromise: EventLoopPromise<SSHExecResult>) {
        self.command = command
        self.input = input
        self.completionPromise = completionPromise
        self.stdout = ByteBuffer()
        self.stderr = ByteBuffer()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .assumeIsolated()
            .whenFailure { error in
                context.fireErrorCaught(error)
            }
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        let execFuture = context.triggerUserOutboundEvent(execRequest).assumeIsolated()

        execFuture.whenSuccess { [weak self] _ in
            guard let self = self else { return }
            if let input = self.input, input.readableBytes > 0 {
                context.writeAndFlush(
                    self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(input))),
                    promise: nil
                )
            }
            // Close stdin so the remote command sees EOF.
            context.close(mode: .output, promise: nil)
        }

        execFuture.whenFailure { _ in
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)

        guard case .byteBuffer(var bytes) = data.data else {
            return
        }

        switch data.type {
        case .channel:
            stdout.writeBuffer(&bytes)
        case .stdErr:
            stderr.writeBuffer(&bytes)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? SSHChannelRequestEvent.ExitStatus {
            self.exitStatus = Int(event.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard let promise = completionPromise else {
            return
        }
        completionPromise = nil

        if let exitStatus {
            let result = SSHExecResult(
                exitStatus: exitStatus,
                stdout: String(decoding: stdout.readableBytesView, as: UTF8.self),
                stderr: String(decoding: stderr.readableBytesView, as: UTF8.self)
            )
            promise.succeed(result)
        } else {
            promise.fail(SSHProvisioningError.missingExitStatus)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        guard let promise = completionPromise else {
            return
        }
        completionPromise = nil
        promise.fail(SSHProvisioningError.commandExecFailed)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard let promise = completionPromise else {
            context.close(promise: nil)
            return
        }
        completionPromise = nil
        promise.fail(error)
        context.close(promise: nil)
    }
}

// MARK: - SSH Provisioner

enum SSHProvisioner {
    /// Execute a command over SSH, optionally feeding stdin from a string.
    static func execute(
        host: String,
        port: Int = 22,
        username: String,
        password: String,
        command: String,
        input: String? = nil
    ) throws -> SSHExecResult {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        let authDelegate = PasswordAuthDelegate(username: username, password: password)
        let serverAuthDelegate = AcceptAllHostKeysDelegate()

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: serverAuthDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(5))

        let channel = try bootstrap.connect(host: host, port: port).wait()
        defer {
            try? channel.close().wait()
        }

        let exitPromise = group.next().makePromise(of: SSHExecResult.self)
        let inputBuffer: ByteBuffer? = input.map { ByteBuffer(string: $0) }

        let childChannel: Channel = try channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHProvisioningError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    let exec = ExecHandler(
                        command: command,
                        input: inputBuffer,
                        completionPromise: exitPromise
                    )
                    try childChannel.pipeline.syncOperations.addHandler(exec)
                }
            }
            return promise.futureResult
        }.wait()

        _ = try childChannel.closeFuture.wait()
        return try exitPromise.futureResult.wait()
    }

    /// Upload and run a local shell script on the remote host.
    static func runScript(
        host: String,
        port: Int = 22,
        username: String,
        password: String,
        scriptPath: String
    ) throws -> SSHExecResult {
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        let escapedPassword = password.replacingOccurrences(of: "'", with: "'\\''")
        let modifiedScript = "export VM_PASSWORD='\(escapedPassword)'\n" + script
        return try execute(
            host: host,
            port: port,
            username: username,
            password: password,
            command: "bash -s",
            input: modifiedScript
        )
    }
}
