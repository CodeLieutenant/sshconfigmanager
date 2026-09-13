//
//  TunnelJumpChain.swift
//  sshconfigmanager
//
//  Resolves the ordered connection path for a tunnel host, following `ProxyJump`
//  the way ssh does: jump hops first, the final target last. Each hop's
//  host/port/user/identity is resolved through EffectiveConfigResolver, so a jump
//  alias inherits its own config (including its own ProxyJump, recursively). Pure
//  and testable; the in-process engine walks the result to nest SSH connections.
//
//  ProxyCommand is rejected here — it's an arbitrary subprocess the sandboxed
//  in-process engine can't run.
//

import Foundation

public enum ProxyCommandTransportKind: Sendable, Equatable {
    case socks5(host: String, port: Int)
    case httpConnect(host: String, port: Int)
    case rawSubprocess(String)
}

/// One node in a tunnel's connection path: a jump host or the final target.
public struct TunnelHop: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    /// Last path component of the resolved IdentityFile, if any (used to load the
    /// on-disk key and to match an agent identity).
    public var identityFileName: String?
    /// Raw `IdentityAgent` value, unexpanded. Per ssh_config(5) this is either
    /// `none` (disable agent auth for this hop), the literal string
    /// `SSH_AUTH_SOCK` (explicitly "use the default agent"), or a socket path that
    /// may contain `~` and `%`-tokens. Expanding `~` needs the *real* home
    /// directory, which this platform-agnostic package has no notion of — that's
    /// the app layer's job (NIOTunnelEngine, backed by SSHFileAccess).
    public var identityAgentRaw: String?
    /// `IdentitiesOnly yes` — only the configured `IdentityFile`(s) may be used,
    /// even when an agent is available and offers a match (or more identities).
    public var identitiesOnly: Bool
    /// `ConnectTimeout` in seconds, or nil if unset.
    public var connectTimeout: Int?
    /// `ServerAliveInterval` in seconds, or nil if unset — cadence for a
    /// keepalive probe once this hop's SSH connection is up.
    public var serverAliveInterval: Int?
    /// `BindAddress` — local source address for this hop's outbound connection,
    /// or nil if unset.
    public var bindAddress: String?
    /// `StrictHostKeyChecking` — unset degrades to `.acceptNew` (today's TOFU
    /// behavior), since this engine has no TTY prompt mid-handshake for `ask`.
    public var strictHostKeyChecking: HostKeyCheckingPolicy
    /// `HostKeyAlias` — substitutes for `host` when matching/writing known_hosts
    /// entries, so a rotating/round-robin `HostName` doesn't invalidate the entry.
    public var hostKeyAlias: String?
    /// `NoHostAuthenticationForLocalhost` — skips host-key verification entirely
    /// when `host` is `localhost`/`127.0.0.1`/`::1`.
    public var noHostAuthenticationForLocalhost: Bool
    /// `HashKnownHosts` — hash the hostname when a new entry is written. Parsed and
    /// carried here, but currently inert: the engine never persists a newly-trusted
    /// TOFU key to known_hosts (that's a deliberate, separate product decision —
    /// see docs/plans — not something this directive alone should silently add).
    public var hashKnownHosts: Bool
    /// `UserKnownHostsFile` — additional known_hosts file path(s) (space-separated
    /// per ssh_config(5)) to consult alongside the app's managed known_hosts.
    public var userKnownHostsFile: [String]
    /// `RevokedHostKeys` — a known_hosts-formatted file of keys to always refuse,
    /// regardless of `StrictHostKeyChecking`.
    public var revokedHostKeys: String?
    /// `ServerAliveCountMax` — missed keepalive probes tolerated before the
    /// connection is dropped. ssh_config(5) default is 3.
    public var serverAliveCountMax: Int
    /// `TCPKeepAlive` — OS-level `SO_KEEPALIVE` on the underlying socket. Only
    /// meaningful on hop 0 (later hops have no raw socket of their own — see
    /// `connectTimeout`/`bindAddress`). ssh_config(5) default is `yes`.
    public var tcpKeepAlive: Bool
    /// `Ciphers` — restricts which transport ciphers may be offered/accepted, or
    /// empty if unset (no restriction beyond whatever the engine already supports).
    public var ciphers: [String]
    /// `MACs` — restricts which integrity algorithms may be offered/accepted, or empty
    /// if unset. Has no effect on an AEAD cipher (AES-GCM, ChaCha20-Poly1305), which
    /// authenticates the packet itself and skips MAC negotiation entirely.
    public var macs: [String]
    /// `PubkeyAuthentication` — `no` removes both key-file and agent auth from the
    /// fallback chain. Default `true`.
    public var pubkeyAuthentication: Bool
    /// `KbdInteractiveAuthentication` — `no` removes the keyboard-interactive
    /// fallback. Default `true`.
    public var kbdInteractiveAuthentication: Bool
    /// `PasswordAuthentication` — `no` removes the password-prompt fallback.
    /// Default `true`.
    public var passwordAuthentication: Bool
    /// Set when `GSSAPIAuthentication yes`/`HostbasedAuthentication yes` is
    /// explicitly configured — neither method exists in this engine (no GSS-API
    /// binding, and the vendored NIOSSH fork's hostbased auth is an unimplemented
    /// stub), so this only drives a one-line "unsupported, ignored" log notice
    /// rather than changing auth behavior. `=no` needs no flag: it already matches
    /// current behavior since neither method is ever offered.
    public var gssapiAuthenticationRequested: Bool
    public var hostbasedAuthenticationRequested: Bool
    /// `ExitOnForwardFailure` — tear down the whole connection if any one port
    /// forward fails to establish, instead of continuing with the others active.
    public var exitOnForwardFailure: Bool
    /// `CertificateFile` — last path component of an OpenSSH certificate to pair
    /// with `identityFileName`'s private key, or nil to use the `<identity>-cert.pub`
    /// convention (checked automatically; this field only overrides that default).
    public var certificateFile: String?
    /// `KexAlgorithms` — restricts which key-exchange algorithms are offered to the
    /// server, or empty if unset (no restriction beyond whatever the engine already
    /// supports).
    public var kexAlgorithms: [String]
    /// `HostKeyAlgorithms` — restricts which server host-key algorithms this client
    /// will accept, or empty if unset.
    public var hostKeyAlgorithms: [String]
    /// `PubkeyAcceptedAlgorithms` — restricts which of the client's own key
    /// types/algorithms may be offered during public-key auth, or empty if unset.
    /// Parsed and threaded through to `ConnectionHop`, but not yet enforced: the
    /// vendored NIOSSH fork exposes no public API to read a loaded key's algorithm
    /// name, so filtering would need another vendored patch. Tracked as a follow-up.
    public var pubkeyAcceptedAlgorithms: [String]
    public var proxyCommandTransport: ProxyCommandTransportKind?

    public init(
        host: String, port: Int, user: String, identityFileName: String? = nil,
        identityAgentRaw: String? = nil, identitiesOnly: Bool = false,
        connectTimeout: Int? = nil, serverAliveInterval: Int? = nil,
        bindAddress: String? = nil,
        strictHostKeyChecking: HostKeyCheckingPolicy = .acceptNew,
        hostKeyAlias: String? = nil, noHostAuthenticationForLocalhost: Bool = false,
        hashKnownHosts: Bool = false, userKnownHostsFile: [String] = [],
        revokedHostKeys: String? = nil, serverAliveCountMax: Int = 3,
        tcpKeepAlive: Bool = true, ciphers: [String] = [], macs: [String] = [],
        pubkeyAuthentication: Bool = true, kbdInteractiveAuthentication: Bool = true,
        passwordAuthentication: Bool = true, gssapiAuthenticationRequested: Bool = false,
        hostbasedAuthenticationRequested: Bool = false,
        exitOnForwardFailure: Bool = false, certificateFile: String? = nil,
        kexAlgorithms: [String] = [], hostKeyAlgorithms: [String] = [],
        pubkeyAcceptedAlgorithms: [String] = [], proxyCommandTransport: ProxyCommandTransportKind? = nil
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFileName = identityFileName
        self.identityAgentRaw = identityAgentRaw
        self.identitiesOnly = identitiesOnly
        self.connectTimeout = connectTimeout
        self.serverAliveInterval = serverAliveInterval
        self.bindAddress = bindAddress
        self.strictHostKeyChecking = strictHostKeyChecking
        self.hostKeyAlias = hostKeyAlias
        self.noHostAuthenticationForLocalhost = noHostAuthenticationForLocalhost
        self.hashKnownHosts = hashKnownHosts
        self.userKnownHostsFile = userKnownHostsFile
        self.revokedHostKeys = revokedHostKeys
        self.serverAliveCountMax = serverAliveCountMax
        self.tcpKeepAlive = tcpKeepAlive
        self.ciphers = ciphers
        self.macs = macs
        self.pubkeyAuthentication = pubkeyAuthentication
        self.kbdInteractiveAuthentication = kbdInteractiveAuthentication
        self.passwordAuthentication = passwordAuthentication
        self.gssapiAuthenticationRequested = gssapiAuthenticationRequested
        self.hostbasedAuthenticationRequested = hostbasedAuthenticationRequested
        self.exitOnForwardFailure = exitOnForwardFailure
        self.certificateFile = certificateFile
        self.kexAlgorithms = kexAlgorithms
        self.hostKeyAlgorithms = hostKeyAlgorithms
        self.pubkeyAcceptedAlgorithms = pubkeyAcceptedAlgorithms
        self.proxyCommandTransport = proxyCommandTransport
    }
}

/// A parsed `[user@]host[:port]` entry from a `ProxyJump` value.
public struct JumpSpec: Equatable {
    public var user: String?
    public var host: String
    public var port: Int?

    public init(user: String? = nil, host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }
}

public enum TunnelChainError: LocalizedError {
    case proxyCommandUnsupported
    case tooManyHops(Int)

    public var errorDescription: String? {
        switch self {
        case .proxyCommandUnsupported:
            return
                "A jump host in this chain uses ProxyCommand, which only the entry hop can run — "
                + "route through it directly, or set its own ProxyJump instead."
        case .tooManyHops(let cap):
            return "The ProxyJump chain is too long or loops (over \(cap) hops)."
        }
    }
}

public enum TunnelJumpChain {
    public static let defaultMaxDepth = 10

    /// Parses a `ProxyJump` value into ordered hop specs. `none`/empty → `[]`.
    public static func parseProxyJump(_ value: String) -> [JumpSpec] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return [] }

        return trimmed.split(separator: ",").compactMap { token -> JumpSpec? in
            var rest = Substring(token.trimmingCharacters(in: .whitespaces))
            guard !rest.isEmpty else { return nil }

            var user: String?
            if let at = rest.firstIndex(of: "@") {
                let candidate = String(rest[..<at])
                if !candidate.isEmpty { user = candidate }
                rest = rest[rest.index(after: at)...]
            }

            var host = String(rest)
            var port: Int?
            if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                // [ipv6]:port
                let after = host[host.index(after: close)...]
                if after.hasPrefix(":"), let parsed = Int(after.dropFirst()) { port = parsed }
                host = String(host[host.index(after: host.startIndex)..<close])
            } else if let colon = host.lastIndex(of: ":"),
                let parsed = Int(host[host.index(after: colon)...])
            {
                port = parsed
                host = String(host[..<colon])
            }
            guard !host.isEmpty else { return nil }
            return JumpSpec(user: user, host: host, port: port)
        }
    }

    /// Resolves the ordered connection path for `alias`: jump hops first, target
    /// last (always at least the target). Throws on `ProxyCommand` or a chain that
    /// loops / exceeds `maxDepth`.
    ///
    /// Each hop's config is resolved over a ``ConfigGraph`` so includes splice inline
    /// at their `Include` directive's position — the jump chain then matches `ssh -G`
    /// even when an early include outranks a later block in the main file.
    public static func resolve(
        alias: String, in graph: ConfigGraph,
        maxDepth: Int = defaultMaxDepth
    ) throws -> [TunnelHop] {
        var visited: Set<String> = [alias.lowercased()]
        return try resolve(
            alias: alias, overrideUser: nil, overridePort: nil,
            depth: 0, maxDepth: maxDepth, visited: &visited
        ) {
            EffectiveConfigResolver.resolve(target: $0, in: graph)
        }
    }

    /// Flat-list overload (no include positions): resolves each hop over the flat
    /// document list. Prefer the ``ConfigGraph`` overload when include order matters.
    public static func resolve(
        alias: String, in documents: [SSHConfigDocument],
        maxDepth: Int = defaultMaxDepth
    ) throws -> [TunnelHop] {
        var visited: Set<String> = [alias.lowercased()]
        return try resolve(
            alias: alias, overrideUser: nil, overridePort: nil,
            depth: 0, maxDepth: maxDepth, visited: &visited
        ) {
            EffectiveConfigResolver.resolve(target: $0, in: documents)
        }
    }

    /// Shared recursion. `resolveSettings` resolves the effective config for an alias
    /// — backed by either a flat document list or a graph — so both public overloads
    /// share one chain-walking implementation.
    private static func resolve(
        alias: String, overrideUser: String?, overridePort: Int?,
        depth: Int, maxDepth: Int, visited: inout Set<String>,
        settings resolveSettings: (String) -> [ResolvedSetting]
    ) throws -> [TunnelHop] {
        guard depth <= maxDepth else { throw TunnelChainError.tooManyHops(maxDepth) }

        let settings = resolveSettings(alias)
        let explicitProxyJump = settings.firstValue(of: "proxyjump")
        var effectiveProxyJump = explicitProxyJump
        var proxyCommandTransport: ProxyCommandTransportKind?
        if explicitProxyJump == nil, let proxyCommand = settings.firstValue(of: "proxycommand"),
            proxyCommand.trimmingCharacters(in: .whitespaces).lowercased() != "none"
        {
            switch ProxyCommandParser.recognize(proxyCommand) {
            case .sshWJumpHost(let bastion):
                effectiveProxyJump = bastion
            case .socks5(let host, let port):
                guard depth == 0 else { throw TunnelChainError.proxyCommandUnsupported }
                proxyCommandTransport = .socks5(host: host, port: port)
            case .httpConnect(let host, let port):
                guard depth == 0 else { throw TunnelChainError.proxyCommandUnsupported }
                proxyCommandTransport = .httpConnect(host: host, port: port)
            case nil:
                guard depth == 0 else { throw TunnelChainError.proxyCommandUnsupported }
                proxyCommandTransport = .rawSubprocess(proxyCommand)
            }
        }

        let identity = settings.firstValue(of: "identityfile").map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).lastPathComponent
        }
        // `IdentitiesOnly` only meaningfully means "yes" when spelled `yes` — any
        // other value (including unset) leaves the agent in play, matching ssh_config(5).
        let identitiesOnly = settings.firstValue(of: "identitiesonly")?.lowercased() == "yes"
        // Booleans that default `yes` in ssh_config(5) only flip on an explicit `no`;
        // booleans that default `no` only flip on an explicit `yes` — unset always
        // preserves today's behavior either way.
        func flagDefaultingOn(_ keyword: String) -> Bool {
            settings.firstValue(of: keyword)?.lowercased() != "no"
        }
        func flagDefaultingOff(_ keyword: String) -> Bool {
            settings.firstValue(of: keyword)?.lowercased() == "yes"
        }
        let hop = TunnelHop(
            host: settings.firstValue(of: "hostname") ?? alias,
            port: overridePort ?? settings.firstValue(of: "port").flatMap(Int.init) ?? 22,
            user: overrideUser ?? settings.firstValue(of: "user") ?? NSUserName(),
            identityFileName: identity,
            identityAgentRaw: settings.firstValue(of: "identityagent"),
            identitiesOnly: identitiesOnly,
            connectTimeout: settings.firstValue(of: "connecttimeout").flatMap(Int.init),
            serverAliveInterval: settings.firstValue(of: "serveraliveinterval").flatMap(Int.init),
            bindAddress: settings.firstValue(of: "bindaddress"),
            strictHostKeyChecking: HostKeyCheckingPolicy(rawValue: settings.firstValue(of: "stricthostkeychecking")),
            hostKeyAlias: settings.firstValue(of: "hostkeyalias"),
            noHostAuthenticationForLocalhost: flagDefaultingOff("nohostauthenticationforlocalhost"),
            hashKnownHosts: flagDefaultingOff("hashknownhosts"),
            userKnownHostsFile: settings.firstValue(of: "userknownhostsfile")?
                .split(separator: " ").map(String.init) ?? [],
            revokedHostKeys: settings.firstValue(of: "revokedhostkeys"),
            serverAliveCountMax: settings.firstValue(of: "serveralivecountmax").flatMap(Int.init) ?? 3,
            tcpKeepAlive: flagDefaultingOn("tcpkeepalive"),
            ciphers: settings.firstValue(of: "ciphers")?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
            macs: settings.firstValue(of: "macs")?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
            pubkeyAuthentication: flagDefaultingOn("pubkeyauthentication"),
            kbdInteractiveAuthentication: flagDefaultingOn("kbdinteractiveauthentication"),
            passwordAuthentication: flagDefaultingOn("passwordauthentication"),
            gssapiAuthenticationRequested: flagDefaultingOff("gssapiauthentication"),
            hostbasedAuthenticationRequested: flagDefaultingOff("hostbasedauthentication"),
            exitOnForwardFailure: flagDefaultingOff("exitonforwardfailure"),
            certificateFile: settings.firstValue(of: "certificatefile"),
            kexAlgorithms: settings.firstValue(of: "kexalgorithms")?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
            hostKeyAlgorithms: settings.firstValue(of: "hostkeyalgorithms")?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
            pubkeyAcceptedAlgorithms: settings.firstValue(of: "pubkeyacceptedalgorithms")?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
            proxyCommandTransport: proxyCommandTransport)

        var chain: [TunnelHop] = []
        if let proxyJump = effectiveProxyJump {
            for spec in parseProxyJump(proxyJump) {
                let key = spec.host.lowercased()
                guard !visited.contains(key) else { throw TunnelChainError.tooManyHops(maxDepth) }
                visited.insert(key)
                chain += try resolve(
                    alias: spec.host, overrideUser: spec.user, overridePort: spec.port,
                    depth: depth + 1, maxDepth: maxDepth, visited: &visited,
                    settings: resolveSettings)
            }
        }
        chain.append(hop) // target (or this jump) goes after the hops that front it
        return chain
    }
}
