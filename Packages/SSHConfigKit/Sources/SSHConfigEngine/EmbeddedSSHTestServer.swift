//
//  EmbeddedSSHTestServer.swift
//  sshconfigmanager
//
//  A tiny, loopback-only SSH *server* used solely to drive the in-process tunnel
//  engine (NIOTunnelEngine, an SSH client) end-to-end in unit tests without a
//  real `sshd`, a network, or any external setup.
//
//  This lives in the APP target (not the test target) on purpose: the test target
//  deliberately does NOT link swift-nio-ssh (see NIOTunnelEngine.makeConnectionForTesting),
//  so the test must reach an SSH server through a NIOSSH-free static factory.
//  Everything here is `#if DEBUG`-gated so it never ships in release builds.
//
//  Behaviour mirrors the vendored NIOSSHServer example (Vendor/swift-nio-ssh):
//    - generates an ed25519 host key in-process (client uses TOFU, so any key works);
//    - accepts ANY publickey auth (the client offers a throwaway key);
//    - for each `direct-tcpip` child channel (-L / -D) it dials the requested
//      target host:port over real loopback TCP and glues the two channels;
//    - for `tcpip-forward` (-R) it binds a real listener and, for each inbound
//      connection, opens a `forwarded-tcpip` channel back to the client and glues.
//

#if DEBUG

    import Foundation
    import NIOCore
    import NIOPosix
    import NIOSSH
    import Crypto

    /// A loopback SSH server for tests. Start one with `EmbeddedSSHTestServer.start()`,
    /// point a `NIOTunnelConnection` at `handle.port`, and call `handle.shutdown()`
    /// when done. The `Handle` is NIOSSH-free so the test target can hold it without
    /// linking the SSH library.
    public enum EmbeddedSSHTestServer {
        /// A running server: the loopback port it bound and a teardown closure.
        public struct Handle: Sendable {
            public let port: Int
            public let shutdown: @Sendable () -> Void
        }

        /// Starts a loopback SSH server bound to an OS-assigned port (so concurrent
        /// tests don't collide) and returns once it is listening. Each server owns its
        /// own event-loop group, released by `Handle.shutdown`.
        ///
        /// `async` so it drives the bind with `EventLoopFuture.get()` instead of
        /// `.wait()`: blocking a thread is illegal on Swift Concurrency's cooperative
        /// pool (where Swift Testing runs), so the old `.wait()` faulted under strict
        /// concurrency. `shutdown` stays synchronous (it's used from `defer`) but
        /// offloads the blocking group teardown to a background queue.
        public static func start() async throws -> Handle {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            // A fresh, throwaway host key. The client validates host keys trust-on-first-use
            // for unknown hosts (knownHosts: []), so any key the server presents is accepted.
            let hostKey = NIOSSHPrivateKey(ed25519Key: .init())

            let bootstrap = ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSHHandler(
                                role: .server(
                                    .init(
                                        hostKeys: [hostKey],
                                        userAuthDelegate: AcceptAllPublicKeyDelegate(),
                                        globalRequestDelegate: TCPForwardingDelegate())),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: Self.childChannelInitializer))
                    }
                }
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.allowRemoteHalfClosure, value: true)

            let channel: Channel
            do {
                channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            } catch {
                try? await group.shutdownGracefully()
                throw error
            }
            guard let port = channel.localAddress?.port else {
                channel.close(promise: nil)
                try? await group.shutdownGracefully()
                throw EmbeddedServerError.noBoundPort
            }

            return Handle(
                port: port,
                shutdown: {
                    channel.close(promise: nil)
                    // Fire-and-forget the blocking group teardown off the caller's thread so
                    // `defer { server.shutdown() }` never blocks a cooperative-pool thread.
                    DispatchQueue.global().async { try? group.syncShutdownGracefully() }
                })
        }

        /// Handles a child channel the client opened. For `direct-tcpip` (-L / -D) the
        /// server is the *real* endpoint: it dials the requested target on loopback and
        /// pumps bytes both ways. Other channel types are refused.
        private nonisolated static func childChannelInitializer(
            _ channel: Channel,
            _ channelType: SSHChannelType
        ) -> EventLoopFuture<Void> {
            switch channelType {
            case .directTCPIP(let target):
                let (ours, theirs) = TestGlueHandler.matchedPair()
                let loopBoundPartner = NIOLoopBound(theirs, eventLoop: channel.eventLoop)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SSHDataCodec())
                    try channel.pipeline.syncOperations.addHandler(ours)
                }.flatMap {
                    ClientBootstrap(group: channel.eventLoop)
                        .channelOption(.allowRemoteHalfClosure, value: true)
                        .connect(host: target.targetHost, port: target.targetPort)
                        .flatMap { peer in
                            peer.eventLoop.makeCompletedFuture {
                                try peer.pipeline.syncOperations.addHandler(loopBoundPartner.value)
                            }
                        }
                }
            case .session, .forwardedTCPIP:
                return channel.eventLoop.makeFailedFuture(EmbeddedServerError.unsupportedChannelType)
            }
        }
    }

    /// Accepts every publickey authentication attempt. Test-only — never deploy.
    private nonisolated final class AcceptAllPublicKeyDelegate: NIOSSHServerUserAuthenticationDelegate {
        public var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }

        public func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            // The client only ever offers a publickey; accept it regardless of which key.
            guard case .publicKey = request.request else {
                responsePromise.succeed(.failure)
                return
            }
            responsePromise.succeed(.success)
        }
    }

    /// Honours the client's `tcpip-forward` (-R) request by binding a real loopback
    /// listener; each accepted connection becomes a `forwarded-tcpip` channel back to
    /// the client, which the engine glues to its local target. Mirrors the vendored
    /// RemotePortForwarder example, but allows multiple bound ports per connection.
    private nonisolated final class TCPForwardingDelegate: GlobalRequestDelegate {
        private var forwarders: [RemoteForwarder] = []

        public func tcpForwardingRequest(
            _ request: GlobalRequest.TCPForwardingRequest,
            handler: NIOSSHHandler,
            promise: EventLoopPromise<GlobalRequest.TCPForwardingResponse>
        ) {
            switch request {
            case .listen(let host, let port):
                let forwarder = RemoteForwarder(handler: handler)
                self.forwarders.append(forwarder)
                forwarder.beginListening(on: host, port: port, loop: promise.futureResult.eventLoop)
                    .map { GlobalRequest.TCPForwardingResponse(boundPort: $0) }
                    .cascade(to: promise)
            case .cancel:
                promise.succeed(GlobalRequest.TCPForwardingResponse(boundPort: nil))
            }
        }
    }

    /// Binds a loopback listener on the server and, for each inbound connection, opens
    /// a `forwarded-tcpip` channel back to the client and glues the two together.
    private nonisolated final class RemoteForwarder {
        private let handler: NIOSSHHandler

        public init(handler: NIOSSHHandler) { self.handler = handler }

        public func beginListening(on host: String, port: Int, loop: EventLoop) -> EventLoopFuture<Int?> {
            let loopBoundHandler = NIOLoopBound(handler, eventLoop: loop)
            return ServerBootstrap(group: loop)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { childChannel in
                    childChannel.eventLoop.makeCompletedFuture {
                        let (ours, theirs) = TestGlueHandler.matchedPair()
                        let promise = loop.makePromise(of: Channel.self)
                        loopBoundHandler.value.createChannel(
                            promise,
                            channelType: .forwardedTCPIP(
                                .init(
                                    listeningHost: host,
                                    listeningPort: childChannel.localAddress!.port!,
                                    originatorAddress: childChannel.remoteAddress!))
                        ) { sshChild, _ in
                            sshChild.eventLoop.makeCompletedFuture {
                                try sshChild.pipeline.syncOperations.addHandler(SSHDataCodec())
                                try sshChild.pipeline.syncOperations.addHandler(theirs)
                            }.flatMap {
                                sshChild.setOption(.allowRemoteHalfClosure, value: true)
                            }
                        }
                        try childChannel.pipeline.syncOperations.addHandler(ours)
                    }
                }
                .bind(host: host, port: port)
                .map { $0.localAddress?.port } // always report the actual port (port 0 → OS-assigned)
        }
    }

    /// Bridges raw bytes <-> `SSHChannelData` on an SSH child channel (server side).
    /// Identical in spirit to the engine's SSHWrapperHandler and the vendored
    /// DataToBufferCodec.
    private nonisolated final class SSHDataCodec: ChannelDuplexHandler {
        public typealias InboundIn = SSHChannelData
        public typealias InboundOut = ByteBuffer
        public typealias OutboundIn = ByteBuffer
        public typealias OutboundOut = SSHChannelData

        public func handlerAdded(context: ChannelHandlerContext) {
            context.channel.setOption(.allowRemoteHalfClosure, value: true).assumeIsolated().whenFailure {
                context.fireErrorCaught($0)
            }
        }

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let data = unwrapInboundIn(data)
            guard case .channel = data.type, case .byteBuffer(let bytes) = data.data else {
                context.fireErrorCaught(EmbeddedServerError.invalidDataType)
                return
            }
            context.fireChannelRead(wrapInboundOut(bytes))
        }

        public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            let buffer = unwrapOutboundIn(data)
            context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
        }
    }

    /// Pumps bytes bidirectionally between a paired SSH child channel and a plain TCP
    /// channel — a verbatim copy of the vendored example's GlueHandler.
    private nonisolated final class TestGlueHandler {
        private var partner: TestGlueHandler?
        private var context: ChannelHandlerContext?
        private var pendingRead = false

        private init() {}

        public static func matchedPair() -> (TestGlueHandler, TestGlueHandler) {
            let first = TestGlueHandler()
            let second = TestGlueHandler()
            first.partner = second
            second.partner = first
            return (first, second)
        }

        private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
        private func partnerFlush() { context?.flush() }
        private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
        private func partnerCloseFull() { context?.close(promise: nil) }
        private func partnerBecameWritable() {
            if pendingRead {
                pendingRead = false
                context?.read()
            }
        }
        private var partnerWritable: Bool { context?.channel.isWritable ?? false }
    }

    extension TestGlueHandler: @preconcurrency ChannelDuplexHandler {
        public typealias InboundIn = NIOAny
        public typealias OutboundIn = NIOAny
        public typealias OutboundOut = NIOAny

        public func handlerAdded(context: ChannelHandlerContext) {
            self.context = context
            if context.channel.isWritable { partner?.partnerBecameWritable() }
        }
        public func handlerRemoved(context: ChannelHandlerContext) {
            self.context = nil
            partner = nil
        }
        public func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
        public func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
        public func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }
        public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let event = event as? ChannelEvent, case .inputClosed = event { partner?.partnerWriteEOF() }
        }
        public func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }
        public func channelWritabilityChanged(context: ChannelHandlerContext) {
            if context.channel.isWritable { partner?.partnerBecameWritable() }
        }
        public func read(context: ChannelHandlerContext) {
            if let partner, partner.partnerWritable { context.read() } else { pendingRead = true }
        }
    }

    private enum EmbeddedServerError: Error {
        case noBoundPort, unsupportedChannelType, invalidDataType
    }

#endif
