//
//  NIOTunnelConnection.swift
//  sshconfigmanager
//
//  One SSH connection (a chain of hops, established by SSHHopChainConnector)
//  + its local/remote forwards. Split out of NIOTunnelEngine.swift.
//

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NIOSSHRSA
import SSHConfigCore
import SSHConfigCrypto

// MARK: - The connection (a chain of SSH hops + a local listener)

/// One port forward within a connection (a single `-L`/`-R`/`-D` mapping). A
/// connection can carry several of these over the same SSH link, exactly as
/// `ssh -L … -L …` does.
public struct PortForward: Sendable {
    public let bindHost: String
    public let bindPort: Int
    public let targetHost: String
    public let targetPort: Int

    public init(bindHost: String, bindPort: Int, targetHost: String, targetPort: Int) {
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }
}

/// One SSH connection path (one or more nested hops via ProxyJump) plus the local
/// listener that feeds it. Internal so the end-to-end test can drive a real
/// forward directly.
public nonisolated final class NIOTunnelConnection: @unchecked Sendable {
    private let mode: TunnelMode
    /// Establishes and authenticates the ordered chain of SSH hops (jump hosts
    /// first, the target last) — everything ssh_config-compliance-related lives
    /// there now, shared with any future non-forwarding SSH session.
    private let connector: SSHHopChainConnector
    private var group: MultiThreadedEventLoopGroup { connector.group }
    /// Every forward to run over this one SSH link (one per `-L`/`-R`/`-D` mapping).
    private let forwards: [PortForward]
    /// `ExitOnForwardFailure` — sourced from the target hop (the one that actually
    /// owns the forwards), since ProxyJump hops earlier in the chain don't have their
    /// own port forwards to fail. Default `false` matches ssh_config(5): a forward
    /// that fails to bind logs an error and the tunnel continues with the others.
    private let exitOnForwardFailure: Bool

    // Mutable state is written from NIO event-loop callbacks and read from the
    // store's @MainActor `stop`, so it's all guarded by one lock.
    private let stateLock = NSLock()
    private var _sshChannel: Channel?
    private var _serverChannels: [Channel] = []
    private var _boundPorts: [Int] = []
    private var _remoteBoundPorts: [Int] = []
    private var _shutdown = false
    private var _onEvent: (@Sendable (EngineEvent) -> Void)?

    /// Counts bytes pumped over the SSH link in both directions (see SSHWrapperHandler).
    public let byteCounter = ByteCounter()
    public var byteCounts: (in: UInt64, out: UInt64) { byteCounter.snapshot() }

    /// Installs the liveness-event sink. Set once before `start`; reads from NIO
    /// callbacks go through `fireEvent` under the lock.
    public func setEventHandler(_ handler: @escaping @Sendable (EngineEvent) -> Void) {
        stateLock.lock()
        _onEvent = handler
        stateLock.unlock()
    }

    private func fireEvent(_ event: EngineEvent) {
        stateLock.lock()
        let handler = _onEvent
        stateLock.unlock()
        handler?(event)
    }

    /// Records a console line for this tunnel (routed through the event sink).
    private func fireLog(_ level: TunnelLogLevel, _ message: String) {
        fireEvent(.log(level, message))
    }

    /// A thread-safe `@Sendable` log sink, safe to capture into NIO callbacks and
    /// child-channel initializers that run off the main actor.
    private var logSink: @Sendable (TunnelLogLevel, String) -> Void {
        { [weak self] level, message in self?.fireLog(level, message) }
    }

    /// Emits `.awaitingInput` so the supervisor can pause its startup deadline
    /// while a 2FA/passphrase prompt is on screen.
    private var awaitingInputSink: @Sendable (Bool) -> Void {
        { [weak self] waiting in self?.fireEvent(.awaitingInput(waiting)) }
    }

    /// The local port the first listener bound (useful when `bindPort` is 0,
    /// i.e. OS-assigned). Set before `.active` is reported.
    public var boundPort: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _boundPorts.first
    }

    /// The remote port the server bound for the first `-R` forward (resolved when
    /// the requested port was 0). Set before `.active`.
    public var remoteBoundPort: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _remoteBoundPorts.first
    }

    /// Index-aligned with `forwards`: the actual port the server bound for each `-R`
    /// forward. Read from the NIO event loop when routing an inbound channel.
    public var remoteBoundPortsSnapshot: [Int] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _remoteBoundPorts
    }

    /// Fired on trust-on-first-use so the caller can persist the accepted key to
    /// known_hosts (audit #9). No-op by default (e.g. tests that don't care).
    private let persistTrustedKey: @Sendable (String, Int, Bool, String) -> Void

    public init(
        mode: TunnelMode, hops: [ConnectionHop],
        knownHosts: [KnownHostEntry], forwards: [PortForward],
        prompter: SSHCredentialPrompting = NonInteractivePrompter(),
        signer: SSHAgentSigning,
        persistTrustedKey: @escaping @Sendable (String, Int, Bool, String) -> Void = { _, _, _, _ in },
        refuseWeakAlgorithms: Bool = false,
        subprocessCapable: Bool = false
    ) {
        self.mode = mode
        self.connector = SSHHopChainConnector(
            hops: hops, knownHosts: knownHosts, prompter: prompter, signer: signer,
            subprocessCapable: subprocessCapable)
        self.connector.refuseWeakAlgorithms = refuseWeakAlgorithms
        self.forwards = forwards
        self.exitOnForwardFailure = hops.last?.exitOnForwardFailure ?? false
        self.persistTrustedKey = persistTrustedKey
    }

    public func start(onStatus: @escaping @Sendable (TunnelStatus) -> Void) {
        connector.connect(
            log: logSink, awaitingInput: awaitingInputSink, persistTrustedKey: persistTrustedKey,
            lastHopChildInitializer: mode == .remote ? inboundChildInitializer() : nil,
            onEachHopEstablished: { [weak self] index, hop, channel in
                guard let self else { return }
                if index == 0 {
                    self.stateLock.lock()
                    self._sshChannel = channel
                    self.stateLock.unlock()
                }
                self.watchClose(channel)
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let channel):
                    switch self.mode {
                    case .local, .dynamic: self.startLocalListeners(over: channel, onStatus: onStatus)
                    case .remote: self.startRemoteForwards(over: channel, onStatus: onStatus)
                    }
                case .failure(let error):
                    self.shutdown() // release the event-loop group on a failed connect
                    // A hop that never got as far as a real handshake attempt (the
                    // TCP connect itself, or a stale pipeline lookup) is reported as
                    // `.failed`; a hop whose handshake actually ran and failed is
                    // reported as `.closed`, matching this distinction as it existed
                    // before the hop-chain logic moved into SSHHopChainConnector.
                    if case SSHHopChainError.hopFailed(let underlying) = error {
                        let reason = SSHErrorText.describe(underlying)
                        self.fireEvent(.closed(reason: reason))
                        onStatus(.failed(reason: reason))
                    } else {
                        let reason = SSHErrorText.describe(error)
                        self.fireEvent(.failed(reason: reason))
                        onStatus(.failed(reason: reason))
                    }
                }
            })
    }

    /// Emits `.closed` if a hop channel drops while we didn't ask it to — a drop
    /// anywhere in the chain tears the tunnel down.
    private func watchClose(_ channel: Channel) {
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            let intentional = self._shutdown
            self.stateLock.unlock()
            if !intentional {
                self.fireLog(.error, "Connection dropped — the SSH channel closed unexpectedly")
                self.fireEvent(.closed(reason: nil))
            }
        }
    }

    // MARK: - Local (-L) and dynamic (-D): a local listener feeding the SSH side

    private func startLocalListeners(over sshChannel: Channel, onStatus: @escaping @Sendable (TunnelStatus) -> Void) {
        let mode = self.mode
        let group = self.group
        let counter = self.byteCounter
        let forwards = self.forwards
        let log = self.logSink
        let loop = sshChannel.eventLoop

        sshChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            guard case .success(let handler) = result else {
                self.fireEvent(.failed(reason: "SSH handler unavailable"))
                onStatus(.failed(reason: "SSH handler unavailable"))
                return
            }
            // Carry the (non-Sendable) handler into the @Sendable child initializers
            // safely: every listener shares the SSH connection's single event loop.
            let handlerBox = NIOLoopBoundBox(handler, eventLoop: loop)

            // Bind one local listener per forward; the tunnel is up once all bind.
            let bindFutures: [EventLoopFuture<Channel>] = forwards.map { forward in
                let targetHost = forward.targetHost
                let targetPort = forward.targetPort
                let server = ServerBootstrap(group: group)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    // Propagate a local client's FIN as a half-close (EOF on the SSH
                    // channel) instead of tearing the whole pair down — protocols that
                    // shutdown(SHUT_WR) and then await the response (e.g. HTTP/1.0) would
                    // otherwise have the response side truncated.
                    .childChannelOption(.allowRemoteHalfClosure, value: true)
                    .childChannelInitializer { inbound in
                        switch mode {
                        case .dynamic:
                            // SOCKS5: the target comes from each client's CONNECT request.
                            log(.detail, "SOCKS client connected")
                            return inbound.eventLoop.makeCompletedFuture {
                                try inbound.pipeline.syncOperations.addHandler(
                                    SOCKS5InboundHandler(handlerBox: handlerBox, counter: counter, log: log))
                            }
                        default:
                            log(.detail, "New connection → \(targetHost):\(targetPort)")
                            return Self.openDirectTCPIP(
                                from: inbound, handlerBox: handlerBox,
                                targetHost: targetHost, targetPort: targetPort, counter: counter
                            )
                            .map { _ in }
                            // A server that refuses the channel leaves the tunnel active and
                            // the listener bound, so the client just gets an empty reply. Say
                            // why, or the log shows only a "New connection" line per attempt.
                            .flatMapErrorThrowing { error in
                                log(
                                    .error,
                                    SSHErrorText.describeForwardRejection(
                                        error, targetHost: targetHost, targetPort: targetPort))
                                throw error
                            }
                        }
                    }
                return server.bind(host: forward.bindHost, port: forward.bindPort)
            }

            EventLoopFuture.whenAllComplete(bindFutures, on: loop).whenComplete { aggregate in
                let results = (try? aggregate.get()) ?? []
                // Index-aligned with `forwards` (nil where the bind failed) so a
                // failure that isn't the last forward doesn't shift later successes
                // out of position — `ExitOnForwardFailure=no` needs to log/keep each
                // forward against its own bind address, not whichever one happens to
                // land at the same array index after failures are dropped.
                var perForwardChannel: [Channel?] = Array(repeating: nil, count: forwards.count)
                var firstError: String?
                for (index, r) in results.enumerated() {
                    switch r {
                    case .success(let channel):
                        if index < perForwardChannel.count { perForwardChannel[index] = channel }
                    case .failure(let error):
                        let port = index < forwards.count ? forwards[index].bindPort : 0
                        let message = Self.bindErrorMessage(
                            error, host: index < forwards.count ? forwards[index].bindHost : "127.0.0.1", port: port)
                        firstError = firstError ?? message
                        log(.error, message)
                    }
                }
                if let firstError, self.exitOnForwardFailure {
                    for channel in perForwardChannel.compactMap({ $0 }) { channel.close(promise: nil) }
                    self.shutdown() // ExitOnForwardFailure=yes: any bind failure tears down the tunnel
                    self.fireEvent(.failed(reason: firstError))
                    onStatus(.failed(reason: firstError))
                    return
                }
                if firstError != nil {
                    log(.error, "Continuing with the forward(s) that bound OK (ExitOnForwardFailure=no)")
                }
                let channels = perForwardChannel.compactMap { $0 }
                self.stateLock.lock()
                self._serverChannels = channels
                self._boundPorts = channels.compactMap { $0.localAddress?.port }
                self.stateLock.unlock()
                for (forward, channel) in zip(forwards, perForwardChannel) {
                    guard let channel else { continue }
                    self.fireLog(
                        .info, "Listening on \(forward.bindHost):\(channel.localAddress?.port ?? forward.bindPort)")
                }
                self.fireLog(
                    .info, "Tunnel established — \(channels.count) forward\(channels.count == 1 ? "" : "s") active")
                self.fireEvent(.connected)
                onStatus(.active(since: Date()))
            }
        }
    }

    /// Opens a direct-tcpip SSH channel to `targetHost:targetPort` and glues it to
    /// `inbound` (a locally-accepted connection).
    /// Returns the opened child channel (not just `Void`) so a caller that buffers
    /// bytes ahead of the channel actually opening — the SOCKS5 handler, across the
    /// request-parsed-to-channel-open gap — can flush whatever accumulated in that
    /// gap once it's open (audit #30). `-L`/`-R` callers that don't need it just
    /// `.map { _ in }`.
    #if DEBUG
        /// Test seam: delays the direct-tcpip channel-open by this long before it
        /// actually starts. A real local/embedded channel-open completes near-
        /// instantly, which makes the `.connecting`-window race audit #30 fixes
        /// (client bytes arriving after the request is parsed but before the
        /// channel is open) unreproducible on any realistic timing — this lets a
        /// test widen that window deterministically instead. Zero (the default)
        /// is a no-op; reset it after use, since it's shared/global.
        public nonisolated(unsafe) static var openDirectTCPIPDelayForTesting: TimeAmount = .zero
    #endif

    public static func openDirectTCPIP(
        from inbound: Channel,
        handlerBox: NIOLoopBoundBox<NIOSSHHandler>,
        targetHost: String, targetPort: Int,
        counter: ByteCounter,
        initialData: [UInt8] = []
    ) -> EventLoopFuture<Channel> {
        guard let origin = inbound.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0)) else {
            return inbound.eventLoop.makeFailedFuture(SSHForwardError.invalidData)
        }
        let promise = inbound.eventLoop.makePromise(of: Channel.self)
        let directTCPIP = SSHChannelType.DirectTCPIP(
            targetHost: targetHost, targetPort: targetPort, originatorAddress: origin)

        func openNow() {
            handlerBox.value.createChannel(promise, channelType: .directTCPIP(directTCPIP)) {
                childChannel, channelType in
                guard case .directTCPIP = channelType else {
                    return childChannel.eventLoop.makeFailedFuture(SSHForwardError.invalidChannelType)
                }
                return childChannel.eventLoop.makeCompletedFuture {
                    try Self.glue(sshChild: childChannel, peer: inbound, counter: counter)
                    // Forward any bytes the client already sent past the SOCKS request.
                    if !initialData.isEmpty {
                        var early = childChannel.allocator.buffer(capacity: initialData.count)
                        early.writeBytes(initialData)
                        counter.addOut(initialData.count)
                        childChannel.writeAndFlush(early, promise: nil)
                    }
                }
            }
        }

        handlerBox.eventLoop.execute {
            #if DEBUG
                let delay = Self.openDirectTCPIPDelayForTesting
                if delay > .zero {
                    handlerBox.eventLoop.scheduleTask(in: delay) { openNow() }
                } else {
                    openNow()
                }
            #else
                openNow()
            #endif
        }
        return promise.futureResult
    }

    // MARK: - Remote (-R): ask the server to listen; dial each inbound channel locally

    private func startRemoteForwards(over sshChannel: Channel, onStatus: @escaping @Sendable (TunnelStatus) -> Void) {
        let forwards = self.forwards
        let loop = sshChannel.eventLoop
        sshChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            guard case .success(let handler) = result else {
                self.fireEvent(.failed(reason: "SSH handler unavailable"))
                onStatus(.failed(reason: "SSH handler unavailable"))
                return
            }
            // Ask the server to listen for each forward; up once all are accepted.
            let requestFutures: [EventLoopFuture<GlobalRequest.TCPForwardingResponse?>] = forwards.map { forward in
                let promise = loop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                handler.sendTCPForwardingRequest(
                    .listen(host: forward.bindHost, port: forward.bindPort), promise: promise)
                return promise.futureResult
            }
            EventLoopFuture.whenAllComplete(requestFutures, on: loop).whenComplete { aggregate in
                let results = (try? aggregate.get()) ?? []
                // Index-aligned with `forwards`, 0 where the request was refused — see
                // the matching comment in `startLocalListeners` for why this can't be
                // a plain "append on success" array once failures don't tear
                // everything down.
                var boundPorts = Array(repeating: 0, count: forwards.count)
                var firstError: Error?
                for (index, r) in results.enumerated() {
                    switch r {
                    case .success(let response):
                        if index < boundPorts.count {
                            boundPorts[index] = response?.boundPort ?? forwards[index].bindPort
                        }
                    case .failure(let error):
                        firstError = firstError ?? error
                        self.fireLog(
                            .error,
                            "Remote forward for \(forwards[index].bindHost):\(forwards[index].bindPort) "
                                + "rejected: \(SSHErrorText.describe(error))")
                    }
                }
                if let firstError, self.exitOnForwardFailure {
                    self.shutdown() // ExitOnForwardFailure=yes: any rejection tears down the tunnel
                    self.fireEvent(.failed(reason: "Remote forward rejected: \(SSHErrorText.describe(firstError))"))
                    onStatus(.failed(reason: "Remote forward rejected: \(SSHErrorText.describe(firstError))"))
                    return
                }
                if firstError != nil {
                    self.fireLog(
                        .error,
                        "Continuing with the remote forward(s) that were accepted "
                            + "(ExitOnForwardFailure=no)")
                }
                self.stateLock.lock()
                self._remoteBoundPorts = boundPorts
                self.stateLock.unlock()
                var activeCount = 0
                for (forward, port) in zip(forwards, boundPorts) where port != 0 {
                    activeCount += 1
                    self.fireLog(.info, "Remote listening on \(forward.bindHost):\(port)")
                }
                self.fireLog(
                    .info, "Tunnel established — \(activeCount) remote forward\(activeCount == 1 ? "" : "s") active")
                self.fireEvent(.connected)
                onStatus(.active(since: Date()))
            }
        }
    }

    /// Builds the inbound child-channel initializer for `-R`: each forwarded-tcpip
    /// channel from the server is routed to the matching forward's local target
    /// (matched by the remote listening port) and glued.
    private func inboundChildInitializer() -> ((Channel, SSHChannelType) -> EventLoopFuture<Void>)? {
        guard case .remote = mode else { return nil }
        let forwards = self.forwards
        let group = self.group
        let counter = self.byteCounter
        let log = self.logSink
        return { [weak self] sshChild, channelType in
            guard case .forwardedTCPIP(let info) = channelType else {
                return sshChild.eventLoop.makeFailedFuture(SSHForwardError.invalidChannelType)
            }
            // Route to the forward whose remote listening port matches. When a forward
            // requested bind port 0, the server assigns the real port, captured in
            // `_remoteBoundPorts` (index-aligned with `forwards`); match against that
            // first so multiple port-0 `-R` forwards reach the right local target. Fall
            // back to the requested bind port, then the first forward.
            let boundPorts = self?.remoteBoundPortsSnapshot ?? []
            let byBound = zip(forwards, boundPorts).first { $0.1 == info.listeningPort }?.0
            guard
                let forward = byBound
                    ?? forwards.first(where: { $0.bindPort == info.listeningPort })
                    ?? forwards.first
            else {
                return sshChild.eventLoop.makeFailedFuture(SSHForwardError.invalidData)
            }
            log(.detail, "Inbound from server :\(info.listeningPort) → \(forward.targetHost):\(forward.targetPort)")
            // Dial the local target, then glue it to the inbound SSH channel.
            return ClientBootstrap(group: group)
                .channelOption(.allowRemoteHalfClosure, value: true)
                .connect(host: forward.targetHost, port: forward.targetPort)
                .flatMap { local in
                    sshChild.eventLoop.makeCompletedFuture {
                        try Self.glue(sshChild: sshChild, peer: local, counter: counter)
                    }
                }
        }
    }

    /// Wires an SSH child channel and a plain TCP channel together: the SSH side
    /// gets the SSHChannelData wrapper, then a glued pair pumps both directions.
    public static func glue(sshChild: Channel, peer: Channel, counter: ByteCounter) throws {
        let (ours, theirs) = GlueHandler.matchedPair()
        let sshSync = sshChild.pipeline.syncOperations
        // Let the remote half-close (EOF) reach the GlueHandler so it can be
        // forwarded to the peer instead of collapsing the whole pair. Callers run
        // this on `sshChild`'s event loop, so the synchronous option API is safe.
        try sshChild.syncOptions?.setOption(.allowRemoteHalfClosure, value: true)
        try sshSync.addHandler(SSHWrapperHandler(counter: counter))
        try sshSync.addHandler(ours)
        try peer.pipeline.syncOperations.addHandler(theirs)
    }

    /// Turns a listener-bind failure into a clear, actionable message — the common
    /// case being a local port that something else (Docker, another tunnel, a dev
    /// server) already holds.
    public static func bindErrorMessage(_ error: Error, host: String, port: Int) -> String {
        // `SSHErrorText`, not `localizedDescription`: a bind failure arrives as a
        // NIO `IOError`, whose Foundation description is the opaque
        // "(NIOCore.IOError error 1.)" — none of the matches below ever fired.
        let text = SSHErrorText.describe(error)
        let desc = text.lowercased()
        if desc.contains("in use") || desc.contains("address already") {
            return
                "Local port \(port) is already in use — stop whatever is using it, or change this tunnel's local port."
        }
        if desc.contains("permission") || desc.contains("denied") {
            return
                "Not allowed to bind \(host):\(port). Ports below 1024 need elevated privileges — pick a higher port."
        }
        return "Couldn't bind \(host):\(port): \(text)"
    }

    /// Idempotent: cancels keepalive loops, closes both channels, and releases the
    /// event-loop group. Safe to call from any thread and more than once (failure
    /// paths + explicit stop). Keepalive tasks are cancelled here (rather than left
    /// to notice `_shutdown` on their own next tick) so a `stop()` right after
    /// `start()` doesn't leave a probe loop running for up to one more
    /// `ServerAliveInterval` — `RepeatedTask.cancel()` is safe to call off its
    /// owning event loop (it dispatches internally).
    public func shutdown() {
        stateLock.lock()
        if _shutdown {
            stateLock.unlock()
            return
        }
        _shutdown = true
        let servers = _serverChannels
        let ssh = _sshChannel
        _serverChannels = []
        _sshChannel = nil
        stateLock.unlock()

        fireLog(
            .detail,
            "Tearing down — closing \(servers.count) listener(s) and the SSH connection")
        for server in servers { server.close(promise: nil) }
        ssh?.close(promise: nil)
        connector.shutdown() // cancels keepalive loops and releases the event-loop group
    }
}
