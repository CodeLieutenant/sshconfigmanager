//
//  NIOTunnelEngine.swift
//  sshconfigmanager
//
//  Option A: an in-process SSH tunnel engine built on swift-nio-ssh. It opens
//  the SSH connection itself (publickey auth with an ed25519/ECDSA key parsed
//  from ~/.ssh) with no `ssh` subprocess, so it stays inside the sandbox.
//  Supports all three forward modes:
//    -L  local listener → direct-tcpip to a fixed remote target
//    -D  local SOCKS5 listener → direct-tcpip to each requested target
//    -R  remote listener (tcpip-forward) → forwarded-tcpip dialled to a local target
//
//  Status: EXPERIMENTAL, behind a Settings flag. Host keys are verified against
//  known_hosts (KnownHostsValidatingDelegate), trust-on-first-use for unknown
//  hosts. All three modes (-L, -D, -R) are verified end-to-end against a live
//  server. Glue adapted from the swift-nio-ssh example.
//

import AppKit
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NIOSSHRSA
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigEngine
import SSHConfigServices
import os

@MainActor
final class NIOTunnelEngine: TunnelEngine {
    // `nonisolated`: the Logger is Sendable and is read from off-main NIO callbacks.
    nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sshconfigmanager", category: "tunnel")

    #if UNSANDBOXED
        nonisolated static let subprocessCapable = true
    #else
        nonisolated static let subprocessCapable = false
    #endif

    /// Registers RSA (ssh-rsa key blobs authenticating as rsa-sha2-256) with NIOSSH
    /// exactly once. NIOSSH ships no RSA; this plugs in the NIOSSHRSA custom-key
    /// implementation so RSA identities — from a key file or ssh-agent — can be parsed
    /// off the wire and offered. Triggered from `start`. Idempotent. `nonisolated`
    /// so the connection (off the main actor) can trigger it.
    nonisolated private static let registerCustomAlgorithms: Void = {
        Insecure.RSA.register()
        // Installs a portable ML-KEM-768 below macOS 26, where CryptoKit has none, so the
        // post-quantum key exchange is offered on every system the app supports.
        MLKEMBackendRegistration.install
    }()

    let capabilities = TunnelEngineCapabilities(
        reportsLiveness: true, canStop: true, survivesAppQuit: false, reportsThroughput: true
    )

    private var connections: [UUID: NIOTunnelConnection] = [:]
    /// Monotonic token bumped by every `start` and `stop`, so a connect that
    /// finishes building off-thread can tell whether it's still the current attempt
    /// before installing itself. Without this, a `stop` (or fast retry) racing the
    /// detached connect would either leak the connection's event-loop group or
    /// clobber `connections[id]` with an abandoned connection that `stop` then misses.
    private var connectGenerations: [UUID: Int] = [:]
    /// Per-tunnel liveness event streams, created in `start`, consumed by the
    /// supervisor via `events(for:)`, torn down in `stop`.
    private var eventStreams: [UUID: AsyncStream<EngineEvent>] = [:]
    private var eventContinuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    func start(_ preset: TunnelPreset) throws {
        _ = Self.registerCustomAlgorithms // ensure RSA is registered before connecting
        guard preset.isValid, !preset.mappings.isEmpty else {
            throw TunnelEngineError.invalidPreset
        }
        // Resolve the full connection path (jump hops first, target last). Throws
        // synchronously on ProxyCommand / a looping chain.
        let hops = try TunnelJumpChain.resolve(alias: preset.hostAlias, in: ConfigStore.shared.configGraph)

        // Every mapping becomes a forward over the same SSH link (like `ssh -L … -L …`).
        // Read once on the main actor, before the connect hops off it.
        let refuseWeakAlgorithms =
            AppSettings.shared.auditServerAlgorithms
            && AppSettings.shared.strictServerAlgorithms
        let forwards = preset.mappings.map { mapping in
            PortForward(
                bindHost: mapping.bindAddress.isEmpty ? "127.0.0.1" : mapping.bindAddress,
                bindPort: mapping.listenPort,
                targetHost: mapping.targetHost, targetPort: mapping.targetPort)
        }
        let id = preset.id

        // Claim this attempt's generation; the detached connect below installs
        // itself only if no later start/stop superseded it.
        connectGenerations[id, default: 0] += 1
        let generation = connectGenerations[id] ?? 0

        // A fresh event stream for this run; the connection (and the off-thread
        // auth/connect failure path) feed it. yield is thread-safe, but the
        // continuation lookup is main-isolated, so emit hops to the main actor.
        finishStream(id)
        let stream = AsyncStream<EngineEvent> { self.eventContinuations[id] = $0 }
        eventStreams[id] = stream
        let name = preset.displayName
        let emit: @Sendable (EngineEvent) -> Void = { [weak self] event in
            switch event {
            case .failed(let reason):
                Self.log.error("tunnel '\(name, privacy: .private)' FAILED: \(reason, privacy: .public)")
            case .closed(let reason):
                Self.log.notice("tunnel '\(name, privacy: .private)' closed: \(reason ?? "-", privacy: .public)")
            case .connected:
                Self.log.notice("tunnel '\(name, privacy: .private)' connected")
            case .log(let level, let message):
                // Carry the console line's own severity into the unified log rather
                // than flattening everything to `.info`: `.info` isn't persisted to
                // disk, so an engine error only visible there vanished from bug
                // reports and from the Log window's "Errors only" filter.
                // Spelled out per level rather than via a pre-built String: composing
                // the message first would strip the `.private` redaction off `name`.
                switch level {
                case .error:
                    Self.log.error("tunnel '\(name, privacy: .private)': \(message, privacy: .public)")
                case .status:
                    Self.log.notice("tunnel '\(name, privacy: .private)': \(message, privacy: .public)")
                case .info:
                    Self.log.info("tunnel '\(name, privacy: .private)': \(message, privacy: .public)")
                case .detail:
                    // `.info`, not `.debug`: OSLogStore only hands back debug entries
                    // when debug logging is explicitly enabled for the subsystem, so a
                    // `.debug` line would never reach the in-app Log window.
                    Self.log.info("tunnel '\(name, privacy: .private)': \(message, privacy: .public)")
                }
            case .awaitingInput(let waiting):
                Self.log.info("tunnel '\(name, privacy: .private)' awaiting input: \(waiting, privacy: .public)")
            }
            Task { @MainActor [weak self] in self?.eventContinuations[id]?.yield(event) }
        }

        // Auth planning (agent query + per-hop key load/prompt) and the heavy
        // bcrypt KDF + SSH connection run off the main thread so the UI stays
        // responsive; passphrase prompts hop back to the main actor.
        Task.detached(priority: .userInitiated) {
            do {
                // Prefer the agent: list each hop's identities once, honoring a
                // per-hop `IdentityAgent` override/disable. Off the main thread
                // (network I/O over the agent socket).
                let agentByHop = await Self.resolveAgentIdentities(for: hops, emit: emit)
                let plans = try await MainActor.run {
                    try Self.planHops(hops, agentByHop: agentByHop, emit: emit)
                }
                for plan in plans {
                    switch plan.auth {
                    case .agent: emit(.log(.detail, "Auth \(plan.username)@\(plan.host): ssh-agent"))
                    case .keyFile: emit(.log(.detail, "Auth \(plan.username)@\(plan.host): key file"))
                    case .keyboardInteractive:
                        emit(.log(.detail, "Auth \(plan.username)@\(plan.host): keyboard-interactive"))
                    }
                }
                let knownHosts = await MainActor.run { ConfigStore.shared.knownHosts }
                let extraEntriesByHop = await Self.loadExtraKnownHostsEntries(for: hops)

                // `hops` and `plans` are index-aligned (`planHops` maps 1:1, preserving
                // order), so the zip carries each hop's ConnectTimeout/BindAddress/
                // ServerAliveInterval alongside its resolved auth plan.
                let connectionHops: [ConnectionHop] = try zip(zip(hops, plans), extraEntriesByHop).map {
                    pair, extraEntries in
                    let (hop, plan) = pair
                    let auth: HopAuth
                    switch plan.auth {
                    case .agent(let identities, let socketPath):
                        auth = .agent(identities, socketPath: socketPath)
                    case .keyFile(let pem, let passphrase, let certifiedKey):
                        auth = .key(try Self.makeKey(pem: pem, passphrase: passphrase), certifiedKey: certifiedKey)
                    case .keyboardInteractive:
                        auth = .keyboardInteractive
                    }
                    return ConnectionHop(
                        host: plan.host, port: plan.port, username: plan.username, auth: auth,
                        connectTimeout: hop.connectTimeout, bindAddress: hop.bindAddress,
                        serverAliveInterval: hop.serverAliveInterval,
                        serverAliveCountMax: hop.serverAliveCountMax,
                        tcpKeepAlive: hop.tcpKeepAlive,
                        strictHostKeyChecking: hop.strictHostKeyChecking,
                        hostKeyAlias: hop.hostKeyAlias,
                        noHostAuthenticationForLocalhost: hop.noHostAuthenticationForLocalhost,
                        hashKnownHosts: hop.hashKnownHosts,
                        ciphers: hop.ciphers,
                        macs: hop.macs,
                        kexAlgorithms: hop.kexAlgorithms,
                        hostKeyAlgorithms: hop.hostKeyAlgorithms,
                        pubkeyAcceptedAlgorithms: hop.pubkeyAcceptedAlgorithms,
                        extraKnownHostsEntries: extraEntries,
                        pubkeyAuthentication: hop.pubkeyAuthentication,
                        kbdInteractiveAuthentication: hop.kbdInteractiveAuthentication,
                        passwordAuthentication: hop.passwordAuthentication,
                        gssapiAuthenticationRequested: hop.gssapiAuthenticationRequested,
                        hostbasedAuthenticationRequested: hop.hostbasedAuthenticationRequested,
                        exitOnForwardFailure: hop.exitOnForwardFailure,
                        proxyCommandTransport: hop.proxyCommandTransport)
                }
                let connection = NIOTunnelConnection(
                    mode: preset.mode, hops: connectionHops, knownHosts: knownHosts,
                    forwards: forwards,
                    prompter: MacCredentialPrompter(), signer: MacAgentSigner(),
                    persistTrustedKey: { host, port, hashKnownHosts, openSSHKeyLine in
                        Task { @MainActor in
                            ConfigStore.shared.persistTrustedHostKey(
                                host: host, port: port, hashKnownHosts: hashKnownHosts,
                                openSSHKeyLine: openSSHKeyLine)
                        }
                    },
                    refuseWeakAlgorithms: refuseWeakAlgorithms, subprocessCapable: Self.subprocessCapable)
                connection.setEventHandler(emit)
                // Install + start only if still the current attempt; a stop or a
                // newer start bumps the generation, in which case we tear this one
                // down instead of leaking it or clobbering the live connection.
                await MainActor.run {
                    guard self.connectGenerations[id] == generation else {
                        connection.shutdown()
                        return
                    }
                    self.connections[id] = connection
                    connection.start { _ in } // status drives the E2E test; the store uses events
                }
            } catch {
                emit(.failed(reason: SSHErrorText.describe(error)))
            }
        }
    }

    /// A resolved per-hop auth decision, captured on the main actor (file reads +
    /// passphrase prompts) and carried into the off-main key derivation.
    private struct HopPlan: Sendable {
        let host: String, port: Int, username: String
        let auth: Plan
        enum Plan: Sendable {
            case agent([AgentIdentity], socketPath: String?) // prefer the agent
            /// `certifiedKey` is the parsed `CertificateFile` (or `<identity>-cert.pub`
            /// convention) paired with this private key, if one was found — see
            /// `planHops`. nil when the identity has no certificate, the common case.
            case keyFile(pem: String, passphrase: String?, certifiedKey: NIOSSHCertifiedPublicKey?)
            case keyboardInteractive // no pre-flight key; server prompts at connect time
        }
    }

    /// A hop's ssh-agent socket decision, resolved from its (possibly empty)
    /// `IdentityAgent` directive. `.disabled` skips the agent outright (ssh_config
    /// `none`); `.socket` carries the override to query and later sign with — nil
    /// means "use the default `SSH_AUTH_SOCK`". Not `private`: exercised directly by
    /// `AgentSocketDecisionTests` (mirrors `matchingAgentIdentities` below).
    nonisolated enum AgentSocketDecision: Equatable {
        case disabled
        case socket(String?)
    }

    /// Resolves a hop's raw `IdentityAgent` value into an agent-socket decision. Per
    /// ssh_config(5): unset → default; the literal string `SSH_AUTH_SOCK` (matched
    /// case-insensitively, like `none` below) also means "use the default env var"
    /// (spelled out so it can override an earlier Host block's setting); `none`
    /// disables the agent entirely for this hop. Any other value is a socket path.
    ///
    /// Tilde-expansion only fires for `~/…` or a bare `~` — mirroring
    /// `SSHFileAccess.resolveIncludes`'s tilde handling — against the *real* home
    /// directory (not the sandbox container home — `SSHFileAccess.realHomeDirectory`).
    /// `~someuser/…` is left untouched rather than naively concatenated: blindly
    /// gluing the real home onto anything starting with `~` would silently produce a
    /// garbage path (no separator, and the wrong user's home besides) instead of
    /// either resolving correctly or erroring.
    ///
    /// %-token substitution is a single pass over the (post-tilde) string — chaining
    /// N sequential `replacingOccurrences` calls would let one token's *replacement*
    /// value (e.g. a HostName that happens to contain the literal text "%p")
    /// get re-scanned and corrupted by a later substitution. We support a
    /// deliberately partial subset (%h host, %p port, %r remote user, %u local user,
    /// %d local home) — full token support (%n, %l, %i…) is a nice-to-have we skip;
    /// unrecognized `%x` sequences pass through unchanged.
    nonisolated static func agentSocketDecision(for hop: TunnelHop) -> AgentSocketDecision {
        // Strip a surrounding quote pair before anything else: a socket path with
        // spaces (e.g. 1Password's under "Group Containers") is written
        // `IdentityAgent "~/…/agent.sock"`, and the quotes would otherwise defeat the
        // `~/` tilde check below and get baked into the socket path we try to reach.
        guard let trimmed = hop.identityAgentRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return .socket(nil)
        }
        let raw = SSHValueQuoting.unquoted(trimmed)
        if raw.caseInsensitiveCompare("none") == .orderedSame { return .disabled }
        if raw.caseInsensitiveCompare("SSH_AUTH_SOCK") == .orderedSame { return .socket(nil) }

        let realHome = SSHFileAccess.realHomeDirectory.path
        let afterTilde: String
        if raw.hasPrefix("~/") {
            afterTilde = realHome + String(raw.dropFirst(1))
        } else if raw == "~" {
            afterTilde = realHome
        } else {
            afterTilde = raw
        }

        let substitutions: [Character: String] = [
            "h": hop.host, "p": String(hop.port), "r": hop.user,
            "u": NSUserName(), "d": realHome,
        ]
        var result = ""
        result.reserveCapacity(afterTilde.count)
        var index = afterTilde.startIndex
        while index < afterTilde.endIndex {
            let char = afterTilde[index]
            if char == "%" {
                let next = afterTilde.index(after: index)
                if next < afterTilde.endIndex, let replacement = substitutions[afterTilde[next]] {
                    result += replacement
                    index = afterTilde.index(after: next)
                    continue
                }
            }
            result.append(char)
            index = afterTilde.index(after: index)
        }
        return .socket(result)
    }

    /// Tilde-expands a `UserKnownHostsFile`/`RevokedHostKeys` path against the real
    /// home directory — same `~/`/bare-`~` handling as `agentSocketDecision`, minus
    /// the `%`-token substitution (ssh_config(5) doesn't document tokens for these
    /// two directives).
    nonisolated static func expandTildeOnly(_ rawValue: String) -> String {
        // Drop a surrounding quote pair first (a path with spaces is written quoted),
        // so the tilde check and the resulting filesystem path both see the bare path.
        let raw = SSHValueQuoting.unquoted(rawValue)
        let realHome = SSHFileAccess.realHomeDirectory.path
        if raw.hasPrefix("~/") { return realHome + String(raw.dropFirst(1)) }
        if raw == "~" { return realHome }
        return raw
    }

    /// Reads each hop's `UserKnownHostsFile`(s) and `RevokedHostKeys` file (via
    /// `ConfigStore`, so a sandbox-denied path queues the same "Grant Access" prompt
    /// `resolveAgentIdentities` uses for an unreachable `IdentityAgent` socket) and
    /// returns one merged `[KnownHostEntry]` list per hop, index-aligned with `hops`.
    /// `RevokedHostKeys` entries are forced to the `.revoked` marker regardless of
    /// what's actually written in that file — the directive's entire purpose is
    /// "these keys are always refused," not "respect whatever marker happens to be
    /// on each line."
    private static func loadExtraKnownHostsEntries(for hops: [TunnelHop]) async -> [[KnownHostEntry]] {
        var result: [[KnownHostEntry]] = []
        for hop in hops {
            var entries: [KnownHostEntry] = []
            for raw in hop.userKnownHostsFile {
                let path = expandTildeOnly(raw)
                if let parsed = await MainActor.run(body: {
                    ConfigStore.shared.readExternalKnownHostsEntries(atPath: path)
                }) {
                    entries += parsed
                } else {
                    await MainActor.run {
                        ConfigStore.shared.reportUnreachableExternalPath(
                            path, reason: .userKnownHostsFile(hopDescription: "\(hop.user)@\(hop.host)"))
                    }
                }
            }
            if let raw = hop.revokedHostKeys {
                let path = expandTildeOnly(raw)
                // RevokedHostKeys is a bare-pubkey-per-line file (NOT known_hosts format),
                // and a revoked key is refused for EVERY host. Parse it into fingerprints
                // and record each as a wildcard-host revoked entry, so
                // KnownHostsVerifier.decide refuses any presented key whose fingerprint
                // matches, on any connection target (audit #8).
                if let fingerprints = await MainActor.run(body: {
                    ConfigStore.shared.readExternalRevokedFingerprints(atPath: path)
                }) {
                    entries += fingerprints.map { fp in
                        KnownHostEntry(
                            lineIndex: 0, raw: "", marker: KnownHostMarker.revoked.rawValue,
                            hostsDisplay: "*", isHashed: false, keyType: "", fingerprint: fp)
                    }
                } else {
                    await MainActor.run {
                        ConfigStore.shared.reportUnreachableExternalPath(
                            path, reason: .revokedHostKeys(hopDescription: "\(hop.user)@\(hop.host)"))
                    }
                }
            }
            result.append(entries)
        }
        return result
    }

    /// Queries each hop's ssh-agent — its own socket when `IdentityAgent` overrides
    /// it, the default `SSH_AUTH_SOCK` otherwise, or skipped for `none` — exactly
    /// once per distinct socket (jump chains commonly share the default agent, so
    /// this avoids redundant round-trips). Runs off the main actor: each query is a
    /// blocking socket round-trip. A *custom* socket (explicit `IdentityAgent path`)
    /// that can't be reached is logged — mirroring the "IdentityFile unreadable" log
    /// in `planHops` below — so a misconfigured/not-running third-party agent (e.g.
    /// 1Password) doesn't silently fall back to keyboard-interactive with zero
    /// indication why. The default socket failing is left quiet, as before: "no
    /// agent running" is the common, unremarkable case.
    nonisolated private static func resolveAgentIdentities(
        for hops: [TunnelHop], emit: @Sendable (EngineEvent) -> Void
    ) async -> [(identities: [AgentIdentity], socketPath: String?)] {
        var cache: [String: [AgentIdentity]] = [:] // keyed by socketPath ?? "" (default)
        var result: [(identities: [AgentIdentity], socketPath: String?)] = []
        for hop in hops {
            switch agentSocketDecision(for: hop) {
            case .disabled:
                result.append(([], nil))
            case .socket(let path):
                let key = path ?? ""
                if let cached = cache[key] {
                    result.append((cached, path))
                } else {
                    do {
                        let identities = try await SSHAgentService().listIdentities(socketPath: path)
                        cache[key] = identities
                        result.append((identities, path))
                    } catch {
                        if let path {
                            emit(
                                .log(
                                    .error,
                                    "IdentityAgent “\(path)” for \(hop.user)@\(hop.host) isn’t reachable "
                                        + "(\(SSHErrorText.describe(error))) — continuing without agent auth for this hop."
                                ))
                            await MainActor.run {
                                ConfigStore.shared.reportUnreachableExternalPath(
                                    path, reason: .agentSocket(hopDescription: "\(hop.user)@\(hop.host)"))
                            }
                        }
                        cache[key] = []
                        result.append(([], path))
                    }
                }
            }
        }
        return result
    }

    /// Decides per hop how to authenticate: prefer the agent when it holds a usable
    /// identity, otherwise fall back to the on-disk key (prompting once per key).
    /// `agentByHop` is index-aligned with `hops` (see `resolveAgentIdentities`).
    /// Runs on the main actor (ConfigStore + NSAlert). Dedupes key load/prompt by name.
    @MainActor
    private static func planHops(
        _ hops: [TunnelHop], agentByHop: [(identities: [AgentIdentity], socketPath: String?)],
        emit: @Sendable (EngineEvent) -> Void
    ) throws -> [HopPlan] {
        var pemByName: [String: String] = [:]
        var passByName: [String: String?] = [:]
        return try zip(hops, agentByHop).map { hop, agentQuery in
            if !Self.identitiesOnlySuppressesAgent(for: hop),
                let identities = Self.agentIdentities(for: hop, among: agentQuery.identities), !identities.isEmpty
            {
                return HopPlan(
                    host: hop.host, port: hop.port, username: hop.user,
                    auth: .agent(identities, socketPath: agentQuery.socketPath))
            }
            let name = hop.identityFileName ?? "id_ed25519"
            guard let loaded = ConfigStore.shared.grantedFileText(named: name) else {
                // No key file found — fall back to keyboard-interactive (PAM/TOTP servers).
                // When the user *explicitly* configured an IdentityFile, surface the
                // miss loudly: the silent fallback to a password/2FA prompt is
                // surprising (and phishing-shaped) when key-only auth was intended.
                if hop.identityFileName != nil {
                    emit(
                        .log(
                            .error,
                            "IdentityFile “\(name)” for \(hop.user)@\(hop.host) isn’t readable — "
                                + "falling back to keyboard-interactive. Grant access to ~/.ssh or fix the path."))
                }
                return HopPlan(host: hop.host, port: hop.port, username: hop.user, auth: .keyboardInteractive)
            }
            let pem: String
            if let cached = pemByName[name] {
                pem = cached
            } else {
                pem = loaded
                pemByName[name] = loaded
            }
            var passphrase: String?
            if OpenSSHPrivateKey.isEncrypted(pem: pem) == true {
                if let cached = passByName[name] {
                    passphrase = cached
                } else {
                    guard let entered = promptForPassphrase(keyName: name) else {
                        throw NIOTunnelError.keyLoadFailed("Passphrase entry was cancelled.")
                    }
                    passphrase = entered
                    passByName[name] = entered
                }
            }
            // `CertificateFile`, or the `<identity>-cert.pub` convention when unset.
            // `NIOSSHCertifiedPublicKey` fully implements OpenSSH-certificate parsing
            // and CA validation in the vendored fork already — this just loads and
            // pairs it with the private key above; most identities have no
            // certificate, so a missing default-convention file is not an error.
            var certifiedKey: NIOSSHCertifiedPublicKey?
            let certName = hop.certificateFile ?? "\(name)-cert.pub"
            if let certText = ConfigStore.shared.grantedFileText(named: certName) {
                if let publicKey = try? NIOSSHPublicKey(
                    openSSHPublicKey: certText.trimmingCharacters(in: .whitespacesAndNewlines)),
                    let certified = NIOSSHCertifiedPublicKey(publicKey)
                {
                    certifiedKey = certified
                } else {
                    emit(
                        .log(
                            .error,
                            "Couldn’t parse “\(certName)” as an OpenSSH certificate for "
                                + "\(hop.user)@\(hop.host) — continuing without it."))
                }
            } else if hop.certificateFile != nil {
                emit(
                    .log(
                        .error,
                        "CertificateFile “\(certName)” for \(hop.user)@\(hop.host) isn’t readable — "
                            + "continuing without it."))
            }
            return HopPlan(
                host: hop.host, port: hop.port, username: hop.user,
                auth: .keyFile(pem: pem, passphrase: passphrase, certifiedKey: certifiedKey))
        }
    }

    /// The agent identities to offer for a hop, or nil to fall back to a key file.
    /// Reads the hop's `.pub` (main actor) and defers the decision to the pure
    /// `matchingAgentIdentities`.
    @MainActor
    private static func agentIdentities(for hop: TunnelHop, among identities: [AgentIdentity]) -> [AgentIdentity]? {
        let pubText = hop.identityFileName.flatMap { ConfigStore.shared.grantedFileText(named: $0 + ".pub") }
        return matchingAgentIdentities(identityFileName: hop.identityFileName, pubText: pubText, among: identities)
    }

    /// Pure agent-vs-key selection (prefer the agent). With an explicit IdentityFile
    /// we offer only the agent key whose fingerprint matches its `.pub` (else nil →
    /// key file); with none, we offer every agent identity in turn; with no agent
    /// identities at all, nil.
    ///
    /// Matching goes through `AgentKeyCorrelation.matchesFingerprint`, the single
    /// canonical "is this disk key the agent's key?" test shared with the Agent UI
    /// (`AgentKeyCorrelation.merge`), so the engine and the UI can never disagree
    /// about what's loaded — the exact "works in my terminal but not here" confusion
    /// the Agent screen exists to dispel (review finding M2).
    nonisolated static func matchingAgentIdentities(
        identityFileName: String?, pubText: String?,
        among identities: [AgentIdentity]
    ) -> [AgentIdentity]? {
        guard !identities.isEmpty else { return nil }
        guard identityFileName != nil else { return identities }
        let fields = (pubText ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2,
            let wantFingerprint = KeyFingerprint.sha256(base64Blob: String(fields[1]))
        else { return nil }
        return identities.first {
            AgentKeyCorrelation.matchesFingerprint($0, wantFingerprint)
        }.map { [$0] }
    }

    /// Whether `IdentitiesOnly` should suppress the agent for this hop. Per
    /// ssh_config(5), `IdentitiesOnly yes` restricts authentication to the
    /// configured `IdentityFile`(s) — or, when none are configured, the *default*
    /// identity files ssh(1) would otherwise try (`~/.ssh/id_rsa`, `id_ed25519`, …)
    /// — either way excluding the agent. This app always has an effective
    /// identity-file candidate for a hop (an explicit `IdentityFile`, or the
    /// `id_ed25519` default `planHops` falls back to below), so `IdentitiesOnly yes`
    /// suppresses the agent unconditionally: there is no case where "no explicit
    /// IdentityFile was written" should leave the agent in play. Not `private`:
    /// exercised directly by `IdentitiesOnlyGatingTests`.
    nonisolated static func identitiesOnlySuppressesAgent(for hop: TunnelHop) -> Bool {
        hop.identitiesOnly
    }

    func stop(_ preset: TunnelPreset) {
        // Bump the generation first so a connect still building off-thread sees
        // it's been superseded and shuts itself down instead of installing.
        connectGenerations[preset.id, default: 0] += 1
        connections[preset.id]?.shutdown()
        connections[preset.id] = nil
        finishStream(preset.id)
    }

    func events(for preset: TunnelPreset) -> AsyncStream<EngineEvent>? {
        eventStreams[preset.id]
    }

    func throughput(for preset: TunnelPreset) -> TunnelThroughput? {
        guard let counts = connections[preset.id]?.byteCounts else { return nil }
        return TunnelThroughput(bytesIn: counts.in, bytesOut: counts.out)
    }

    private func finishStream(_ id: UUID) {
        eventContinuations[id]?.finish()
        eventContinuations[id] = nil
        eventStreams[id] = nil
    }

    /// Parses the key and builds a NIO key. For encrypted keys this runs
    /// bcrypt_pbkdf, so it must be called off the main thread.
    nonisolated private static func makeKey(pem: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        // Loading any key may yield an RSA identity, and the client must parse the
        // server's PK_OK echo (ssh-rsa) — so register RSA here too, not only in
        // `start(_:)`. Idempotent; covers the connection-building paths.
        _ = Self.registerCustomAlgorithms
        do {
            let parsed = try OpenSSHPrivateKey.parse(pem: pem, passphrase: passphrase)
            switch parsed.material {
            case .ed25519(let seed):
                return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed)))
            case .ecdsa(let curve, let scalar):
                switch curve {
                case .p256:
                    return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: Data(scalar)))
                case .p384:
                    return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: Data(scalar)))
                case .p521:
                    return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: Data(scalar)))
                }
            case .rsa(let n, let e, let d, let p, let q):
                let rsaKey = try Insecure.RSA.PrivateKey(
                    modulus: Data(n), publicExponent: Data(e), privateExponent: Data(d),
                    prime1: Data(p), prime2: Data(q))
                return NIOSSHPrivateKey(custom: rsaKey)
            }
        } catch {
            throw NIOTunnelError.keyLoadFailed(SSHErrorText.describe(error))
        }
    }

    #if DEBUG
        /// Builds a connection straight from a PEM string, for the end-to-end test
        /// (so the test target doesn't need to link NIOSSH).
        /// Test seam: parse a PEM into a key so a test can build hops by hand.
        nonisolated static func makeKeyForTesting(pem: String, passphrase: String?) throws -> NIOSSHPrivateKey {
            try makeKey(pem: pem, passphrase: passphrase)
        }

        nonisolated static func makeConnectionForTesting(
            mode: TunnelMode = .local,
            pem: String, passphrase: String?,
            sshHost: String, sshPort: Int, username: String,
            bindHost: String, bindPort: Int, targetHost: String, targetPort: Int,
            ciphers: [String] = [], macs: [String] = [], kexAlgorithms: [String] = []
        ) throws -> NIOTunnelConnection {
            let key = try makeKey(pem: pem, passphrase: passphrase)
            return NIOTunnelConnection(
                mode: mode,
                hops: [
                    ConnectionHop(
                        host: sshHost, port: sshPort, username: username, auth: .key(key),
                        ciphers: ciphers, macs: macs, kexAlgorithms: kexAlgorithms)
                ],
                knownHosts: [],
                forwards: [
                    PortForward(
                        bindHost: bindHost, bindPort: bindPort,
                        targetHost: targetHost, targetPort: targetPort)
                ],
                signer: MacAgentSigner())
        }

        /// One PEM-authenticated hop spec for the multi-hop end-to-end test.
        nonisolated struct TestHop: Sendable {
            let pem: String, passphrase: String?
            let host: String, port: Int, username: String
            init(pem: String, passphrase: String?, host: String, port: Int, username: String) {
                self.pem = pem
                self.passphrase = passphrase
                self.host = host
                self.port = port
                self.username = username
            }
        }

        /// Builds a multi-hop (ProxyJump) connection from PEM hops — jumps first,
        /// target last — for the end-to-end test.
        nonisolated static func makeConnectionForTesting(
            mode: TunnelMode = .local, hops: [TestHop],
            bindHost: String, bindPort: Int, targetHost: String, targetPort: Int
        ) throws -> NIOTunnelConnection {
            let connectionHops = try hops.map {
                ConnectionHop(
                    host: $0.host, port: $0.port, username: $0.username,
                    auth: .key(try makeKey(pem: $0.pem, passphrase: $0.passphrase)))
            }
            return NIOTunnelConnection(
                mode: mode, hops: connectionHops, knownHosts: [],
                forwards: [
                    PortForward(
                        bindHost: bindHost, bindPort: bindPort,
                        targetHost: targetHost, targetPort: targetPort)
                ],
                signer: MacAgentSigner())
        }

        /// Builds an agent-authenticated single-hop connection for the end-to-end test.
        nonisolated static func makeAgentConnectionForTesting(
            mode: TunnelMode = .local, identities: [AgentIdentity], agentSocketPath: String? = nil,
            sshHost: String, sshPort: Int, username: String,
            bindHost: String, bindPort: Int, targetHost: String, targetPort: Int
        ) -> NIOTunnelConnection {
            NIOTunnelConnection(
                mode: mode,
                hops: [
                    ConnectionHop(
                        host: sshHost, port: sshPort, username: username,
                        auth: .agent(identities, socketPath: agentSocketPath))
                ],
                knownHosts: [],
                forwards: [
                    PortForward(
                        bindHost: bindHost, bindPort: bindPort,
                        targetHost: targetHost, targetPort: targetPort)
                ],
                signer: MacAgentSigner())
        }
    #endif

    @MainActor
    private static func promptForPassphrase(keyName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Passphrase for \(keyName)"
        alert.informativeText = "This key is encrypted. Enter its passphrase to start the tunnel."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
