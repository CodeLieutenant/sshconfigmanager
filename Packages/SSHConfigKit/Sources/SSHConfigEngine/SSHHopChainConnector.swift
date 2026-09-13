//
//  SSHHopChainConnector.swift
//  sshconfigmanager
//
//  Establishes and authenticates a chain of one or more nested SSH connections
//  (a ProxyJump chain: jump hosts first, the target last), honoring every
//  per-hop ssh_config directive this engine enforces — host-key policy,
//  ciphers, KexAlgorithms/HostKeyAlgorithms overrides, auth-method gates
//  (publickey/agent/keyboard-interactive/password), and ServerAliveInterval
//  keepalive. Deliberately ignorant of what the caller does with the resulting
//  channel: NIOTunnelConnection uses it to feed port forwards, but nothing
//  here is forwarding-specific, so it's the seam to reuse for any future
//  generic SSH session (exec, shell, sftp) over the same vendored NIOSSH fork.
//  Split out of NIOTunnelConnection.swift.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SSHConfigCore

/// How a single hop authenticates. `.key` signs with an in-memory private key;
/// `.agent` delegates signing to the ssh-agent over the given identities (tried
/// in order) — `socketPath` overrides `SSH_AUTH_SOCK` when the hop configures its
/// own `IdentityAgent`, nil keeps the default agent — so the private key never
/// enters this process. `.keyboardInteractive` means the server drives the dialog
/// via RFC 4256 challenge prompts (PAM/TOTP).
public nonisolated enum HopAuth: Sendable {
    /// `certifiedKey` is the parsed `CertificateFile` (or `<identity>-cert.pub`
    /// convention) paired with this private key, if one was found. nil when the
    /// identity has no certificate, the common case.
    case key(NIOSSHPrivateKey, certifiedKey: NIOSSHCertifiedPublicKey? = nil)
    case agent([AgentIdentity], socketPath: String?)
    case keyboardInteractive
}

/// One node in an SSH connection path (a jump host, or the final target). Not
/// tied to port forwarding — this is everything needed to connect and
/// authenticate one hop per ssh_config semantics.
public nonisolated struct ConnectionHop: Sendable {
    public let host: String, port: Int, username: String
    public let auth: HopAuth
    /// `ConnectTimeout` — only meaningful on hop 0: later hops are virtual
    /// `direct-tcpip` channels tunnelled over the prior hop, not real sockets, so
    /// there's nothing for NIO's `ClientBootstrap` to time out.
    public var connectTimeout: Int? = nil
    /// `BindAddress` — same hop-0-only caveat as `connectTimeout`.
    public var bindAddress: String? = nil
    /// `ServerAliveInterval` — meaningful for every hop, since each hop in a
    /// ProxyJump chain is its own independent SSH connection (ssh(1) would spawn a
    /// separate `ssh` process per jump, each with its own keepalive).
    public var serverAliveInterval: Int? = nil
    /// `ServerAliveCountMax` — missed probes tolerated before this hop's connection
    /// is dropped (default 3, matching ssh_config(5)).
    public var serverAliveCountMax: Int = 3
    /// `TCPKeepAlive` — hop-0-only, same caveat as `connectTimeout`/`bindAddress`.
    public var tcpKeepAlive: Bool = true
    /// `StrictHostKeyChecking` for this hop's own host-key verification.
    public var strictHostKeyChecking: HostKeyCheckingPolicy = .acceptNew
    /// `HostKeyAlias` — substitutes for `host` when verifying/writing known_hosts.
    public var hostKeyAlias: String? = nil
    /// `NoHostAuthenticationForLocalhost`.
    public var noHostAuthenticationForLocalhost: Bool = false
    /// `HashKnownHosts` — hash the hostname (HMAC-SHA1, salted) when a newly
    /// trust-on-first-use key is persisted (audit #9).
    public var hashKnownHosts: Bool = false
    /// `Ciphers` — restricts the offered/accepted transport cipher list.
    public var ciphers: [String] = []
    /// `MACs` — see `TunnelHop.macs`. Ignored by the AEAD schemes.
    public var macs: [String] = []
    /// `KexAlgorithms`/`HostKeyAlgorithms` — restrict the offered key-exchange
    /// algorithms / accepted server host-key algorithms. Empty means unset (no
    /// restriction). Applied via the vendored NIOSSH fork's
    /// `SSHClientConfiguration.keyExchangeAlgorithmsOverride`/`hostKeyAlgorithmsOverride`.
    public var kexAlgorithms: [String] = []
    public var hostKeyAlgorithms: [String] = []
    /// `PubkeyAcceptedAlgorithms` — carried through from `TunnelHop` but **not yet
    /// enforced** (see `TunnelHop.pubkeyAcceptedAlgorithms`): the vendored NIOSSH
    /// fork has no public API to read a loaded key's algorithm name to filter on.
    public var pubkeyAcceptedAlgorithms: [String] = []
    /// Entries loaded from this hop's `UserKnownHostsFile`(s) and `RevokedHostKeys`
    /// file, already merged (revoked entries forced to the `.revoked` marker) — see
    /// `NIOTunnelEngine.loadExtraKnownHostsEntries`. Consulted alongside the app's
    /// managed known_hosts, not in place of it.
    public var extraKnownHostsEntries: [KnownHostEntry] = []
    /// `PubkeyAuthentication`/`KbdInteractiveAuthentication` — `false` removes that
    /// method from `CompositeAuthDelegate`'s fallback chain entirely.
    public var pubkeyAuthentication: Bool = true
    public var kbdInteractiveAuthentication: Bool = true
    /// `PasswordAuthentication` — `false` removes password from the fallback chain.
    public var passwordAuthentication: Bool = true
    /// Set when `GSSAPIAuthentication yes`/`HostbasedAuthentication yes` is
    /// explicitly configured — neither method is implemented, so this only drives a
    /// one-line "unsupported, ignored" log notice.
    public var gssapiAuthenticationRequested: Bool = false
    public var hostbasedAuthenticationRequested: Bool = false
    /// `ExitOnForwardFailure` — only meaningful read off the target (last) hop, since
    /// that's the one whose port forwards actually get established. Unused by any
    /// non-forwarding caller of `SSHHopChainConnector`.
    public var exitOnForwardFailure: Bool = false
    public var proxyCommandTransport: ProxyCommandTransportKind? = nil

    /// Only the four values a hop cannot be built without are required; every
    /// ssh_config-derived setting keeps the default it had as a synthesized
    /// memberwise init, so callers still set the handful they care about.
    public init(
        host: String, port: Int, username: String, auth: HopAuth,
        connectTimeout: Int? = nil,
        bindAddress: String? = nil,
        serverAliveInterval: Int? = nil,
        serverAliveCountMax: Int = 3,
        tcpKeepAlive: Bool = true,
        strictHostKeyChecking: HostKeyCheckingPolicy = .acceptNew,
        hostKeyAlias: String? = nil,
        noHostAuthenticationForLocalhost: Bool = false,
        hashKnownHosts: Bool = false,
        ciphers: [String] = [],
        macs: [String] = [],
        kexAlgorithms: [String] = [],
        hostKeyAlgorithms: [String] = [],
        pubkeyAcceptedAlgorithms: [String] = [],
        extraKnownHostsEntries: [KnownHostEntry] = [],
        pubkeyAuthentication: Bool = true,
        kbdInteractiveAuthentication: Bool = true,
        passwordAuthentication: Bool = true,
        gssapiAuthenticationRequested: Bool = false,
        hostbasedAuthenticationRequested: Bool = false,
        exitOnForwardFailure: Bool = false,
        proxyCommandTransport: ProxyCommandTransportKind? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.connectTimeout = connectTimeout
        self.bindAddress = bindAddress
        self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax
        self.tcpKeepAlive = tcpKeepAlive
        self.strictHostKeyChecking = strictHostKeyChecking
        self.hostKeyAlias = hostKeyAlias
        self.noHostAuthenticationForLocalhost = noHostAuthenticationForLocalhost
        self.hashKnownHosts = hashKnownHosts
        self.ciphers = ciphers
        self.macs = macs
        self.kexAlgorithms = kexAlgorithms
        self.hostKeyAlgorithms = hostKeyAlgorithms
        self.pubkeyAcceptedAlgorithms = pubkeyAcceptedAlgorithms
        self.extraKnownHostsEntries = extraKnownHostsEntries
        self.pubkeyAuthentication = pubkeyAuthentication
        self.kbdInteractiveAuthentication = kbdInteractiveAuthentication
        self.passwordAuthentication = passwordAuthentication
        self.gssapiAuthenticationRequested = gssapiAuthenticationRequested
        self.hostbasedAuthenticationRequested = hostbasedAuthenticationRequested
        self.exitOnForwardFailure = exitOnForwardFailure
        self.proxyCommandTransport = proxyCommandTransport
    }
}

/// Failures from establishing the hop chain, distinguishing *how* a hop failed
/// so callers can report it the way they did before this was split out (a
/// bare handler-lookup miss is reported differently than a handshake that
/// actually ran and failed).
public nonisolated enum SSHHopChainError: Error, LocalizedError {
    case noHops
    case handlerUnavailable
    case hopFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .noHops: return "No connection hops resolved."
        case .handlerUnavailable: return "SSH handler unavailable"
        case .hopFailed(let error): return SSHErrorText.describe(error)
        }
    }
}

/// A hop's own SSH-level authentication failed, or its channel dropped before
/// authenticating — surfaced through `SSHHopChainError.hopFailed` so `TunnelStore`
/// sees a real reason instead of `nil` (audit #19). `TunnelStore.classify`
/// recognizes "auth" in the message as fatal (stop retrying); any other wording
/// stays retryable, so word new messages carefully.
public nonisolated struct HopAuthenticationError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

/// Succeeds `promise` the moment this hop's own SSH connection reports
/// `UserAuthSuccessEvent` — the only client-observable signal that the server
/// actually accepted credentials, as opposed to the transport merely being open
/// (audit #19). Forwards every event unchanged so it doesn't interfere with
/// anything else listening on the pipeline.
public nonisolated final class UserAuthWaitHandler: ChannelInboundHandler {
    public typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>
    /// The hop this handler belongs to, for the console lines.
    private let host: String
    private let log: @Sendable (TunnelLogLevel, String) -> Void
    /// Reports the negotiated algorithms plus the worst severity found in them, so the
    /// store can badge the tunnel without re-running the audit.
    private let onNegotiated: @Sendable (NIOSSHNegotiatedAlgorithms, LintFinding.Severity?) -> Void
    /// Mirrors `SSHHopChainConnector.refuseWeakAlgorithms` for this hop.
    private let refuseWeak: Bool

    public init(
        promise: EventLoopPromise<Void>,
        host: String = "",
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void = { _, _ in },
        refuseWeak: Bool = false,
        onNegotiated: @escaping @Sendable (NIOSSHNegotiatedAlgorithms, LintFinding.Severity?) -> Void = { _, _ in }
    ) {
        self.promise = promise
        self.host = host
        self.log = log
        self.refuseWeak = refuseWeak
        self.onNegotiated = onNegotiated
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise.succeed(())
        }
        if let negotiated = event as? NIOSSHNegotiatedAlgorithms {
            self.report(negotiated, context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    /// Writes the negotiated algorithms to the tunnel console and flags any that are weak.
    /// Fires again after a rekey, which is intentional: the algorithms can change.
    private func report(_ negotiated: NIOSSHNegotiatedAlgorithms, context: ChannelHandlerContext) {
        let summary = [negotiated.keyExchange, negotiated.cipher, negotiated.hostKey]
            .joined(separator: " · ")
        self.log(.detail, "\(self.host): negotiated \(summary)")

        var verdicts = [
            ServerAlgorithmAudit.verdict(role: .keyExchange, name: negotiated.keyExchange),
            ServerAlgorithmAudit.verdict(role: .cipher, name: negotiated.cipher),
            ServerAlgorithmAudit.hostKeyVerdict(type: negotiated.hostKey),
        ]
        // An AEAD cipher negotiates no MAC, and `<implicit>` is not an algorithm to judge.
        if !negotiated.usesImplicitMAC {
            verdicts.append(ServerAlgorithmAudit.verdict(role: .mac, name: negotiated.mac))
        }

        let weaknesses = ServerAlgorithmAudit.weaknesses(in: verdicts)
        for verdict in weaknesses {
            self.log(
                verdict.severity == .error ? .error : .info,
                "\(self.host) negotiated \(verdict.name) (\(verdict.role.label.lowercased())) — \(verdict.reason)")
        }
        self.onNegotiated(negotiated, ServerAlgorithmAudit.worstSeverity(in: verdicts))

        // Strict mode: fail the hop rather than carry on. Worded to name the algorithm and
        // the way out, since the only fixes are the server's configuration or this setting.
        // Deliberately avoids the word "auth", which `TunnelStore.classify` treats as
        // permanently fatal — this is worth retrying once either side changes.
        if self.refuseWeak, let worst = weaknesses.first, (worst.severity ?? .info) > .info {
            let reason =
                "Refused \(self.host): the server negotiated \(worst.name), which this connection considers weak. "
                + "\(worst.reason) Turn off “Refuse to connect to a weak server” in Settings to connect anyway."
            self.log(.error, reason)
            // Closing is what actually stops the connection. Failing the promise only
            // works before user auth completes — after a rekey it has already succeeded
            // and `fail` is a no-op, so strict mode would otherwise carry a weak rekey.
            self.promise.fail(HopAuthenticationError(message: reason))
            context.close(promise: nil)
        }
    }

    /// `NIOSSHHandler` reports a failed handshake by firing the error down the
    /// pipeline and leaving the channel open, so nothing below it ever closed the
    /// connection: a rejected key exchange sat silent until the *server* gave up
    /// (~23 s), and the user saw "never connects" with no reason. Fail the promise
    /// with the real error and close, so the reason reaches the console at once.
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
        context.fireErrorCaught(error)
    }
}

/// Connects and authenticates an ordered chain of `ConnectionHop`s, one nested
/// SSH connection per hop. Owns its own `MultiThreadedEventLoopGroup` (exposed
/// so a forwarding caller can reuse it for its own listeners rather than
/// spinning up a second one) and its `ServerAliveInterval` keepalive loops.
///
/// Not `@MainActor`: NIO callbacks run on the event loop, and `connect`'s
/// completion/per-hop callbacks are `@Sendable` so a caller can hop back to
/// whatever actor it needs.
public nonisolated final class SSHHopChainConnector: @unchecked Sendable {
    private let hops: [ConnectionHop]
    private let knownHosts: [KnownHostEntry]
    /// Where a password or 2FA challenge goes when a hop asks for one. Injected
    /// because the engine has no UI of its own — see `SSHCredentialPrompting`.
    private let prompter: SSHCredentialPrompting
    /// Signs agent-backed offers. Injected for the same reason: reaching the
    /// agent socket is the host program's job, not the engine's.
    private let signer: SSHAgentSigning
    /// Set by `connect(...)`, not `init`, so a caller (like `NIOTunnelConnection`)
    /// can pass closures that capture itself weakly without hitting Swift's
    /// definite-initialization ordering — those closures aren't safe to build
    /// until the caller's own `init` has finished.
    private var log: @Sendable (TunnelLogLevel, String) -> Void = { _, _ in }
    private var awaitingInput: @Sendable (Bool) -> Void = { _ in }
    /// Fired on trust-on-first-use so the caller can persist the accepted key to
    /// known_hosts (audit #9). `(matchHost, port, hashKnownHosts, openSSHKeyLine)`.
    private var persistTrustedKey: @Sendable (String, Int, Bool, String) -> Void = { _, _, _, _ in }
    /// The negotiated algorithms per hop plus the worst severity found across the whole
    /// chain — a tunnel is only as strong as its weakest hop, so a ProxyJump chain is
    /// judged by the worst of them.
    private let negotiationLock = NSLock()
    private var _negotiated: [NIOSSHNegotiatedAlgorithms] = []
    private var _worstSeverity: LintFinding.Severity?

    /// Everything the chain negotiated, and the worst verdict across all of it.
    public var negotiationSummary: (algorithms: [NIOSSHNegotiatedAlgorithms], worst: LintFinding.Severity?) {
        self.negotiationLock.lock()
        defer { self.negotiationLock.unlock() }
        return (self._negotiated, self._worstSeverity)
    }

    /// `strictServerAlgorithms` — set by the caller before `connect`. When on, a hop that
    /// negotiates a warning-or-worse algorithm is torn down instead of merely logged.
    public var refuseWeakAlgorithms = false

    private func recordNegotiation(_ algorithms: NIOSSHNegotiatedAlgorithms, worst: LintFinding.Severity?) {
        self.negotiationLock.lock()
        self._negotiated.append(algorithms)
        if let worst {
            self._worstSeverity = self._worstSeverity.map { Swift.max($0, worst) } ?? worst
        }
        self.negotiationLock.unlock()
    }

    public let group: MultiThreadedEventLoopGroup

    private let stateLock = NSLock()
    private var _shutdown = false
    /// One keepalive loop per hop that configures `ServerAliveInterval` —
    /// cancelled eagerly in `shutdown()` so an in-flight probe doesn't wait up to a
    /// full interval to notice `_shutdown` on its own next tick.
    private var _keepaliveTasks: [RepeatedTask] = []

    private let subprocessCapable: Bool

    public init(
        hops: [ConnectionHop], knownHosts: [KnownHostEntry],
        prompter: SSHCredentialPrompting, signer: SSHAgentSigning, subprocessCapable: Bool = false
    ) {
        self.hops = hops
        self.knownHosts = knownHosts
        self.prompter = prompter
        self.signer = signer
        self.subprocessCapable = subprocessCapable
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Walks the hop chain. Hop 0 is a real TCP connection; every later hop
    /// opens a `direct-tcpip` channel over the prior hop's already-authenticated
    /// SSH connection and runs a fresh SSH handshake on it (each later
    /// `createChannel` naturally queues until the prior hop has authenticated).
    ///
    /// `onEachHopEstablished` fires once per hop (0-indexed, including the
    /// last) right after that hop's handshake completes — so a caller can watch
    /// its close future, schedule its own bookkeeping, etc. `lastHopChildInitializer`
    /// is installed only on the final hop's `NIOSSHHandler` (e.g. so `-R`
    /// forwards can route inbound `forwarded-tcpip` channels); pass nil for a
    /// plain outbound session with no inbound need. `completion` fires exactly
    /// once, with the final hop's authenticated channel on success.
    public func connect(
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void,
        awaitingInput: @escaping @Sendable (Bool) -> Void,
        persistTrustedKey: @escaping @Sendable (String, Int, Bool, String) -> Void = { _, _, _, _ in },
        lastHopChildInitializer: ((Channel, SSHChannelType) -> EventLoopFuture<Void>)?,
        onEachHopEstablished: @escaping @Sendable (Int, ConnectionHop, Channel) -> Void,
        completion: @escaping @Sendable (Result<Channel, Error>) -> Void
    ) {
        self.log = log
        self.awaitingInput = awaitingInput
        self.persistTrustedKey = persistTrustedKey
        guard let first = hops.first else {
            completion(.failure(SSHHopChainError.noHops))
            return
        }
        let delegate = self.authDelegate(for: first)
        // Safe to create ahead of the channel that will fulfill it: `group` is a
        // single-thread `MultiThreadedEventLoopGroup` (see `init`), so `group.next()`
        // always returns the one event loop every hop's channel also runs on.
        let authPromise = group.next().makePromise(of: Void.self)
        let initializeChannel: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
            channel.eventLoop.makeCompletedFuture {
                var clientConfig = SSHClientConfiguration(
                    userAuthDelegate: delegate,
                    serverAuthDelegate: self.hostKeyDelegate(for: first))
                clientConfig.keyboardInteractiveDelegate = delegate
                clientConfig.transportProtectionSchemes = try Self.transportProtectionSchemes(for: first)
                try Self.applyAlgorithmOverrides(to: &clientConfig, for: first)
                let ssh = NIOSSHHandler(
                    role: .client(clientConfig),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: self.hops.count == 1 ? lastHopChildInitializer : nil)
                try channel.pipeline.syncOperations.addHandler(ssh)
                try channel.pipeline.syncOperations.addHandler(
                    UserAuthWaitHandler(
                        promise: authPromise, host: first.host, log: self.log,
                        refuseWeak: self.refuseWeakAlgorithms,
                        onNegotiated: { [weak self] algorithms, worst in
                            self?.recordNegotiation(algorithms, worst: worst)
                        }))
            }
        }

        let strategy = ProxyConnectStrategyFactory.make(for: first, subprocessCapable: subprocessCapable)
        log(.info, "Connecting to \(first.host):\(first.port) via \(strategy.displayName)…")
        let channelFuture = strategy.connect(
            group: group, targetHost: first.host, targetPort: first.port, username: first.username, log: log,
            channelInitializer: initializeChannel)

        channelFuture.whenComplete { result in
            switch result {
            case .failure(let error):
                // The channel can progress far enough to install `UserAuthWaitHandler`
                // (which owns `authPromise`) before the connect ultimately fails — e.g. an
                // autostart tunnel to an unreachable or rejecting host. Complete the promise
                // here so it isn't deallocated unfulfilled when the pipeline tears down,
                // which trips NIO's debug-only "leaked promise" assertion and hard-crashes
                // debug builds. First-completion-wins keeps this a no-op on the happy path.
                authPromise.fail(error)
                // The console is where the user looks when a tunnel won't come up;
                // the status line only ever says "Reconnecting…". Name the actual
                // failure here so every attempt leaves a reason behind.
                self.log(.error, "Couldn't open the connection — \(SSHErrorText.describe(error))")
                completion(.failure(error))
            case .success(let channel):
                // Don't treat the hop as up yet — the transport is open, but the
                // server hasn't accepted (or rejected) any credentials. Reporting
                // `.active` here is exactly the audit #19 bug: a rejecting server's
                // channel looked "up" instantly, so the give-up cap was
                // unreachable (every cycle wrongly reset `attempt` to 0) and the
                // password/2FA prompt re-appeared every retry instead of once.
                self.log(
                    .detail,
                    "Transport to \(first.host):\(first.port) is up — starting the SSH handshake")
                self.failAuthPromiseOnClose(
                    authPromise, channel: channel,
                    hostLabel: "\(first.host):\(first.port)", delegate: delegate)
                authPromise.futureResult.whenComplete { authResult in
                    switch authResult {
                    case .failure(let error):
                        self.log(.error, "Authentication failed — \(SSHErrorText.describe(error))")
                        completion(.failure(error))
                    case .success:
                        self.log(.info, "Authenticated as \(first.username)@\(first.host)")
                        self.scheduleKeepalive(for: first, over: channel)
                        onEachHopEstablished(0, first, channel)
                        self.openNextHop(
                            index: 1, over: channel,
                            lastHopChildInitializer: lastHopChildInitializer,
                            onEachHopEstablished: onEachHopEstablished,
                            completion: completion)
                    }
                }
            }
        }
    }

    /// Fails `promise` if `channel` closes before it's already succeeded (a no-op
    /// otherwise — `EventLoopPromise` keeps whichever completion happens first).
    /// Distinguishes a genuine credential rejection — `delegate` reports it ran
    /// out of methods to offer — from an unrelated pre-auth drop, so
    /// `TunnelStore.classify` (which keys off "auth" in the reason string) gives
    /// up retrying the former but keeps retrying the latter (audit #19).
    private func failAuthPromiseOnClose(
        _ promise: EventLoopPromise<Void>, channel: Channel, hostLabel: String, delegate: CompositeAuthDelegate
    ) {
        channel.closeFuture.whenComplete { _ in
            let message =
                delegate.exhaustedAllMethods
                ? "Authentication failed for \(hostLabel) — the server rejected every offered credential."
                : "Connection to \(hostLabel) closed before the SSH handshake finished."
            promise.fail(SSHHopChainError.hopFailed(HopAuthenticationError(message: message)))
        }
    }

    private func openNextHop(
        index: Int, over channel: Channel,
        lastHopChildInitializer: ((Channel, SSHChannelType) -> EventLoopFuture<Void>)?,
        onEachHopEstablished: @escaping @Sendable (Int, ConnectionHop, Channel) -> Void,
        completion: @escaping @Sendable (Result<Channel, Error>) -> Void
    ) {
        guard index < hops.count else {
            completion(.success(channel))
            return
        }
        let hop = hops[index]
        log(.info, "Connecting through hop \(hop.host):\(hop.port) as \(hop.username)…")
        // `ConnectTimeout`/`BindAddress` only apply to the real hop-0 TCP connect
        // (see `ConnectionHop`'s doc comments) — a jump-only host configuring either
        // would otherwise have it silently dropped with no indication why.
        if hop.connectTimeout != nil || hop.bindAddress != nil {
            log(
                .detail,
                "ConnectTimeout/BindAddress on \(hop.host):\(hop.port) are ignored — "
                    + "they only apply to the first hop of a chain.")
        }
        let inboundInit = (index == hops.count - 1) ? lastHopChildInitializer : nil

        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            guard case .success(let handler) = result,
                let origin = try? SocketAddress(ipAddress: "127.0.0.1", port: 0)
            else {
                completion(.failure(SSHHopChainError.handlerUnavailable))
                return
            }
            let directTCPIP = SSHChannelType.DirectTCPIP(
                targetHost: hop.host, targetPort: hop.port, originatorAddress: origin)
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            let hopDelegate = self.authDelegate(for: hop)
            // Same single-event-loop reasoning as the hop-0 `authPromise` above:
            // `channel.eventLoop` is `group`'s one loop, shared by every hop.
            let authPromise = channel.eventLoop.makePromise(of: Void.self)
            handler.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { childChannel, channelType in
                guard case .directTCPIP = channelType else {
                    return childChannel.eventLoop.makeFailedFuture(SSHForwardError.invalidChannelType)
                }
                return childChannel.eventLoop.makeCompletedFuture {
                    // Bridge SSHChannelData<->ByteBuffer so the next SSH handshake runs
                    // over this tunnelled channel; inner-transport bytes aren't counted.
                    let sync = childChannel.pipeline.syncOperations
                    try sync.addHandler(SSHWrapperHandler(counter: nil))
                    var hopConfig = SSHClientConfiguration(
                        userAuthDelegate: hopDelegate,
                        serverAuthDelegate: self.hostKeyDelegate(for: hop))
                    hopConfig.keyboardInteractiveDelegate = hopDelegate
                    hopConfig.transportProtectionSchemes = try Self.transportProtectionSchemes(for: hop)
                    try Self.applyAlgorithmOverrides(to: &hopConfig, for: hop)
                    try sync.addHandler(
                        NIOSSHHandler(
                            role: .client(hopConfig),
                            allocator: childChannel.allocator,
                            inboundChildChannelInitializer: inboundInit))
                    try sync.addHandler(
                        UserAuthWaitHandler(
                            promise: authPromise, host: hop.host, log: self.log, refuseWeak: self.refuseWeakAlgorithms,
                            onNegotiated: { [weak self] algorithms, worst in
                                self?.recordNegotiation(algorithms, worst: worst)
                            }))
                }
            }
            promise.futureResult.whenComplete { childResult in
                switch childResult {
                case .failure(let error):
                    // Same leak guard as hop 0: the child channel may have installed
                    // `UserAuthWaitHandler` (owning `authPromise`) before failing, so
                    // complete the promise to avoid freeing it unfulfilled during teardown.
                    authPromise.fail(error)
                    self.log(
                        .error,
                        "Couldn't open the channel to \(hop.host):\(hop.port) through the previous hop — "
                            + "\(SSHErrorText.describe(error))")
                    completion(.failure(SSHHopChainError.hopFailed(error)))
                case .success(let childChannel):
                    // Same audit #19 gate as hop 0: this direct-tcpip channel only
                    // means the *previous* hop authenticated (that's what let NIOSSH
                    // accept the channel-open) — this hop's own credentials haven't
                    // been offered yet.
                    self.failAuthPromiseOnClose(
                        authPromise, channel: childChannel,
                        hostLabel: "\(hop.host):\(hop.port)", delegate: hopDelegate)
                    authPromise.futureResult.whenComplete { authResult in
                        switch authResult {
                        case .failure(let error):
                            self.log(
                                .error,
                                "Authentication failed at hop \(hop.host):\(hop.port) — "
                                    + "\(SSHErrorText.describe(error))")
                            completion(.failure(error))
                        case .success:
                            self.log(.info, "Hop established via \(hop.username)@\(hop.host):\(hop.port)")
                            self.scheduleKeepalive(for: hop, over: childChannel)
                            onEachHopEstablished(index, hop, childChannel)
                            self.openNextHop(
                                index: index + 1, over: childChannel,
                                lastHopChildInitializer: lastHopChildInitializer,
                                onEachHopEstablished: onEachHopEstablished,
                                completion: completion)
                        }
                    }
                }
            }
        }
    }

    private func authDelegate(for hop: ConnectionHop) -> CompositeAuthDelegate {
        let inner: NIOSSHClientUserAuthenticationDelegate?
        switch hop.auth {
        case .key(let privateKey, let certifiedKey):
            inner = PublicKeyAuthDelegate(username: hop.username, privateKey: privateKey, certifiedKey: certifiedKey)
            log(
                .detail,
                "\(hop.host): offering public-key auth"
                    + (certifiedKey != nil ? " with a certificate" : ""))
        case .agent(let identities, let socketPath):
            inner = AgentAuthDelegate(
                username: hop.username, identities: identities, socketPath: socketPath,
                signer: signer)
            log(
                .detail,
                "\(hop.host): offering \(identities.count) agent identity(s) via "
                    + (socketPath ?? "$SSH_AUTH_SOCK"))
        case .keyboardInteractive:
            inner = nil
            log(.detail, "\(hop.host): no usable key — falling back to keyboard-interactive/password")
        }
        // Which methods are even on the table decides whether a rejection is
        // "wrong key" or "the method you needed was disabled in ssh_config".
        let enabled = [
            hop.pubkeyAuthentication ? "publickey" : nil,
            hop.kbdInteractiveAuthentication ? "keyboard-interactive" : nil,
            hop.passwordAuthentication ? "password" : nil,
        ].compactMap { $0 }
        log(
            .detail,
            "\(hop.host): auth methods enabled — "
                + (enabled.isEmpty ? "none (every method is disabled in ssh_config)" : enabled.joined(separator: ", ")))
        if hop.gssapiAuthenticationRequested {
            log(
                .info,
                "GSSAPIAuthentication is configured for \(hop.host) but unsupported by this "
                    + "engine — ignored")
        }
        if hop.hostbasedAuthenticationRequested {
            log(
                .info,
                "HostbasedAuthentication is configured for \(hop.host) but unsupported by this "
                    + "engine — ignored")
        }
        return CompositeAuthDelegate(
            username: hop.username, inner: inner,
            pubkeyEnabled: hop.pubkeyAuthentication,
            kbdInteractiveEnabled: hop.kbdInteractiveAuthentication,
            passwordEnabled: hop.passwordAuthentication,
            prompter: prompter,
            log: log, awaitingInput: awaitingInput)
    }

    /// Implements `ServerAliveInterval` as an OpenSSH-style `keepalive@openssh.com`
    /// global request sent on `channel`'s own SSH connection every `interval`
    /// seconds. Any reply at all — success *or* the REQUEST_FAILURE a server sends
    /// for a request name it doesn't recognise — proves the link round-trips and
    /// resets the watchdog *and* the missed-probe counter; getting no reply within
    /// one more interval counts as one missed probe. `ServerAliveCountMax` misses in
    /// a row (default 3, matching ssh_config(5)) close `channel`.
    ///
    /// The `NIOSSHHandler` is resolved from the pipeline exactly once, up front, and
    /// captured into every tick — not re-resolved on each tick — since it never
    /// changes for the life of `channel`. The returned `RepeatedTask` is stashed in
    /// `_keepaliveTasks` so `shutdown()` can cancel it immediately instead of the
    /// loop waiting up to one more `interval` to notice `_shutdown` on its own.
    private func scheduleKeepalive(for hop: ConnectionHop, over channel: Channel) {
        guard let interval = hop.serverAliveInterval, interval > 0 else { return }
        let loop = channel.eventLoop
        let log = self.log
        let hopLabel = "\(hop.host):\(hop.port)"
        let countMax = max(hop.serverAliveCountMax, 1)
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self, case .success(let handler) = result else { return }
            // The connection may have already torn down while the handler lookup
            // was in flight (a fast connect-then-stop race) — don't start a loop
            // `shutdown()` will never get a chance to cancel.
            self.stateLock.lock()
            let alreadyShutdown = self._shutdown
            self.stateLock.unlock()
            guard !alreadyShutdown else { return }
            // Shared across ticks (not re-declared per tick) so misses accumulate;
            // every access happens on `loop`'s own thread (the repeated task, the
            // watchdog, and the reply callback are all scheduled on it), so this
            // needs no additional synchronization.
            var missedProbes = 0
            let task = loop.scheduleRepeatedTask(
                initialDelay: .seconds(Int64(interval)), delay: .seconds(Int64(interval))
            ) { [weak self] repeatedTask in
                guard let self else {
                    repeatedTask.cancel()
                    return
                }
                self.stateLock.lock()
                let shutdown = self._shutdown
                self.stateLock.unlock()
                guard !shutdown else {
                    repeatedTask.cancel()
                    return
                }
                let promise = loop.makePromise(of: ByteBuffer?.self)
                handler.sendGlobalRequest(named: "keepalive@openssh.com", promise: promise)
                let watchdog = loop.scheduleTask(in: .seconds(Int64(interval))) {
                    missedProbes += 1
                    if missedProbes >= countMax {
                        log(
                            .error,
                            "No keepalive reply from \(hopLabel) after \(missedProbes) "
                                + "missed probe(s) — closing")
                        channel.close(promise: nil)
                    } else {
                        log(
                            .detail,
                            "No keepalive reply from \(hopLabel) "
                                + "(\(missedProbes)/\(countMax) missed probes)")
                    }
                }
                promise.futureResult.whenComplete { _ in
                    watchdog.cancel()
                    missedProbes = 0
                }
            }
            self.stateLock.lock()
            self._keepaliveTasks.append(task)
            self.stateLock.unlock()
        }
    }

    private func hostKeyDelegate(for hop: ConnectionHop) -> NIOSSHClientServerAuthenticationDelegate {
        let matchHost = hop.hostKeyAlias ?? hop.host
        return KnownHostsValidatingDelegate(
            host: matchHost, port: hop.port,
            entries: knownHosts + hop.extraKnownHostsEntries,
            realHost: hop.host, policy: hop.strictHostKeyChecking,
            skipForLocalhost: hop.noHostAuthenticationForLocalhost, log: log,
            persistTrustedKey: { [persistTrustedKey] openSSHKeyLine in
                persistTrustedKey(matchHost, hop.port, hop.hashKnownHosts, openSSHKeyLine)
            })
    }

    /// Everything this engine can offer, in preference order.
    ///
    /// `chacha20-poly1305@openssh.com` is OpenSSH's own first preference, but it sits behind
    /// the AES-GCM schemes here on purpose: AES-GCM runs on BoringSSL through swift-crypto,
    /// while this one's Poly1305 comes from a pure-Swift library. Both are fine for a control
    /// connection; the difference shows up on a tunnel moving real traffic. It is offered so a
    /// server that has nothing else still connects, not to become the everyday cipher.
    public static var allTransportProtectionSchemes: [NIOSSHTransportProtection.Type] {
        var schemes: [NIOSSHTransportProtection.Type] = []
        for scheme in Constants.bundledTransportProtectionSchemes {
            schemes.append(scheme)
            if scheme.cipherName == "aes128-gcm@openssh.com" {
                schemes.append(ChaCha20Poly1305TransportProtection.self)
            }
        }
        return schemes
    }

    /// Implements `Ciphers` and `MACs`: restricts the offered/accepted transport scheme
    /// list to whichever of this fork's bundled schemes the user actually asked for. An
    /// empty list means the directive is unset — no restriction. If the user's list
    /// matches none of the bundled schemes, fail loudly rather than silently connecting
    /// with an unrequested algorithm (same "hard stop, not silent" precedent as
    /// `ProxyCommand`).
    ///
    /// A scheme here is a (cipher, MAC) pair, so the two directives filter the same
    /// array. The AEAD schemes (`aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`,
    /// `chacha20-poly1305@openssh.com`) authenticate the packet themselves and have no
    /// MAC name — `MACs` must not filter them out, matching OpenSSH, which skips MAC
    /// negotiation entirely whenever the chosen cipher is an AEAD.
    private static func transportProtectionSchemes(for hop: ConnectionHop) throws -> [NIOSSHTransportProtection.Type] {
        var schemes: [NIOSSHTransportProtection.Type] = Self.allTransportProtectionSchemes

        // Plain loops, not `.filter`/`.map` closures over the existential-metatype
        // array — those trigger a Swift compiler SIL crash on an opened existential
        // in this toolchain (confirmed while implementing this).
        if !hop.ciphers.isEmpty {
            var supportedNames: [String] = []
            var filtered: [NIOSSHTransportProtection.Type] = []
            for scheme in schemes {
                let name = scheme.cipherName
                if !supportedNames.contains(name) { supportedNames.append(name) }
                if hop.ciphers.contains(name) {
                    filtered.append(scheme)
                }
            }
            guard !filtered.isEmpty else {
                throw NIOTunnelError.noSupportedCiphers(requested: hop.ciphers, supported: supportedNames)
            }
            schemes = filtered
        }

        if !hop.macs.isEmpty {
            var supportedNames: [String] = []
            var filtered: [NIOSSHTransportProtection.Type] = []
            for scheme in schemes {
                guard let name = scheme.macName else {
                    filtered.append(scheme)
                    continue
                }
                if !supportedNames.contains(name) { supportedNames.append(name) }
                if hop.macs.contains(name) {
                    filtered.append(scheme)
                }
            }
            // Surviving with only AEAD schemes is not a failure: the MACs list matched
            // nothing it could constrain, and a negotiated AEAD cipher never consults it.
            // Only an empty list — every cipher already ruled out by `Ciphers` too — fails.
            guard !filtered.isEmpty else {
                throw NIOTunnelError.noSupportedAlgorithms(
                    directive: "MACs", requested: hop.macs, supported: supportedNames)
            }
            schemes = filtered
        }

        return schemes
    }

    /// Implements `KexAlgorithms`/`HostKeyAlgorithms` by setting
    /// `SSHClientConfiguration.keyExchangeAlgorithmsOverride`/`hostKeyAlgorithmsOverride`
    /// (vendored NIOSSH patch — see `Vendor/PATCH.md` Patch 7). Validated the same way
    /// as `Ciphers`: an empty `hop.kexAlgorithms`/`hop.hostKeyAlgorithms` means unset (no
    /// restriction, `clientConfig`'s override stays nil); a non-empty list that shares no
    /// algorithm with what this fork actually supports fails loudly before connecting,
    /// rather than silently offering zero algorithms mid-handshake.
    private static func applyAlgorithmOverrides(to clientConfig: inout SSHClientConfiguration, for hop: ConnectionHop)
        throws
    {
        if !hop.kexAlgorithms.isEmpty {
            let supported = SSHClientConfiguration.supportedKeyExchangeAlgorithms
            guard hop.kexAlgorithms.contains(where: { supported.contains($0) }) else {
                throw NIOTunnelError.noSupportedAlgorithms(
                    directive: "KexAlgorithms", requested: hop.kexAlgorithms, supported: supported)
            }
            clientConfig.keyExchangeAlgorithmsOverride = hop.kexAlgorithms
        }
        if !hop.hostKeyAlgorithms.isEmpty {
            let supported = SSHClientConfiguration.supportedHostKeyAlgorithms
            guard hop.hostKeyAlgorithms.contains(where: { supported.contains($0) }) else {
                throw NIOTunnelError.noSupportedAlgorithms(
                    directive: "HostKeyAlgorithms", requested: hop.hostKeyAlgorithms, supported: supported)
            }
            clientConfig.hostKeyAlgorithmsOverride = hop.hostKeyAlgorithms
        }
    }

    /// Cancels keepalive loops and releases the event-loop group. Idempotent and
    /// safe to call from any thread. Doesn't close any hop's channel — the caller
    /// (which received them via `onEachHopEstablished`/`connect`'s completion)
    /// owns that.
    public func shutdown() {
        stateLock.lock()
        if _shutdown {
            stateLock.unlock()
            return
        }
        _shutdown = true
        let keepalives = _keepaliveTasks
        _keepaliveTasks = []
        stateLock.unlock()

        for task in keepalives { task.cancel() }
        group.shutdownGracefully { _ in }
    }
}
