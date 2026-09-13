//
//  SSHAuthDelegates.swift
//  sshconfigmanager
//
//  NIOSSH user-auth + host-key delegates (publickey, agent, keyboard-interactive, known_hosts).
//  Split out of NIOTunnelEngine.swift.
//

import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import NIOSSHRSA
import SSHConfigCore
import SSHConfigCrypto

// MARK: - Auth & host-key delegates

public nonisolated final class PublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    /// The parsed `CertificateFile` (or `<identity>-cert.pub` convention) paired
    /// with `privateKey`, if any — see `NIOTunnelEngine.planHops`. When present, the
    /// offer's public key is the certified key, not the bare one, so the server
    /// authenticates against the CA-signed certificate.
    private let certifiedKey: NIOSSHCertifiedPublicKey?
    private var offered = false

    public init(username: String, privateKey: NIOSSHPrivateKey, certifiedKey: NIOSSHCertifiedPublicKey? = nil) {
        self.username = username
        self.privateKey = privateKey
        self.certifiedKey = certifiedKey
    }

    public func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), !offered else {
            nextChallengePromise.succeed(nil) // nothing left to try
            return
        }
        offered = true
        let offer: NIOSSHUserAuthenticationOffer.Offer.PrivateKey =
            certifiedKey.map {
                .init(privateKey: privateKey, certifiedKey: $0)
            } ?? .init(privateKey: privateKey)
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(offer)))
    }
}

/// Authenticates by delegating signing to the ssh-agent: offers each identity's
/// public key with an external signer that asks the agent to sign the challenge.
/// The private key never enters this process. Offers identities in order, one per
/// `nextAuthenticationType` call, then gives up. Relies on the vendored swift-nio-ssh
/// `externalKey` offer (see Vendor/PATCH.md).
public nonisolated final class AgentAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let identities: [AgentIdentity]
    /// Overrides `SSH_AUTH_SOCK` for every sign request this delegate issues — set
    /// when the hop configures `IdentityAgent <path>` (nil keeps default behavior).
    private let socketPath: String?
    /// Supplies the signature; the agent itself lives outside the engine.
    private let signer: SSHAgentSigning
    private var index = 0

    public init(
        username: String, identities: [AgentIdentity], socketPath: String? = nil,
        signer: SSHAgentSigning
    ) {
        self.username = username
        self.identities = identities
        self.socketPath = socketPath
        self.signer = signer
    }

    public func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        while index < identities.count {
            let identity = identities[index]
            index += 1
            let openSSH = "\(identity.keyType) \(Data(identity.keyBlob).base64EncodedString())"
            guard let publicKey = try? NIOSSHPublicKey(openSSHPublicKey: openSSH) else { continue }
            let keyBlob = identity.keyBlob
            let socketPath = self.socketPath
            let signer = self.signer
            // RSA agent identities must request rsa-sha2-256; flags=0 yields a legacy
            // SHA-1 signature the server (and our RSA plugin) rejects, so RSA agent
            // keys could never authenticate (audit #20).
            let signFlags = SSHAgentProtocol.signFlags(forKeyType: identity.keyType)
            let externalKey = NIOSSHUserAuthenticationOffer.Offer.ExternalKey(
                publicKey: publicKey,
                sign: { buffer in
                    let signature = try await signer.sign(
                        keyBlob: keyBlob, data: Array(buffer.readableBytesView), flags: signFlags,
                        socketPath: socketPath)
                    return try NIOSSHSignature(sshWire: signature)
                })
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username, serviceName: "ssh-connection", offer: .externalKey(externalKey)))
            return
        }
        nextChallengePromise.succeed(nil) // nothing left to try
    }
}

/// Wraps an optional public-key delegate and adds keyboard-interactive as a fallback.
/// Implements both NIOSSHClientUserAuthenticationDelegate (for method selection) and
/// NIOSSHKeyboardInteractiveDelegate (for RFC 4256 challenge prompts).
///
/// Method order: public-key first (agent or file-based), then keyboard-interactive.
/// This handles servers that accept either method, or require both in sequence (2FA).
// @unchecked Sendable: most of this delegate's mutable state (`innerExhausted`,
// `exhaustedAllMethods`) is only ever touched from NIOSSH callbacks, which all
// run on the connection's single event loop. `kiCancelled`/`passwordCancelled`
// are the exception — they're written from a `Task { @MainActor in … }` (the
// Cancel button on the password/2FA alert) that runs off that event loop, so
// those two are guarded by `NIOLockedValueBox` instead of relying on
// single-threaded access (audit #11: they used to be plain `var`s, a real
// cross-thread data race between the alert's Cancel handler and the event
// loop re-reading the flag on the very next auth round).
public nonisolated final class CompositeAuthDelegate:
    NIOSSHClientUserAuthenticationDelegate, NIOSSHKeyboardInteractiveDelegate, @unchecked Sendable
{
    private let username: String
    private let inner: NIOSSHClientUserAuthenticationDelegate?
    /// `PubkeyAuthentication=no` — skip `inner` (key/agent) entirely, same as if it
    /// were already exhausted, and go straight to keyboard-interactive.
    private let pubkeyEnabled: Bool
    /// `KbdInteractiveAuthentication=no` — never offer keyboard-interactive.
    private let kbdInteractiveEnabled: Bool
    /// `PasswordAuthentication=no` — never offer password auth. Tried last, after
    /// pubkey/agent and keyboard-interactive, matching OpenSSH's default
    /// `PreferredAuthentications` ordering.
    private let passwordEnabled: Bool
    private var innerExhausted = false
    // Set on user Cancel (from the @MainActor alert handler) — read back on the
    // NIO event loop, so both need real synchronization (audit #11).
    private let kiCancelled = NIOLockedValueBox(false)
    private let passwordCancelled = NIOLockedValueBox(false)
    /// True once every method (pubkey/agent, keyboard-interactive, password) has
    /// been tried, disabled, or cancelled — i.e. we've told NIOSSH we have nothing
    /// left to offer. `SSHHopChainConnector` reads this to tell a genuine
    /// credential rejection (audit #19) apart from an unrelated pre-auth network
    /// drop when the connection subsequently closes.
    private(set) var exhaustedAllMethods = false
    private let log: @Sendable (TunnelLogLevel, String) -> Void
    /// Signals when we're blocked on a user prompt (true) and when it's answered
    /// (false), so the supervisor doesn't time the tunnel out mid-2FA.
    private let awaitingInput: @Sendable (Bool) -> Void
    /// Asks the user for the password / challenge responses. Supplied by the host
    /// program, so the engine never owns a UI.
    private let prompter: SSHCredentialPrompting

    public init(
        username: String, inner: NIOSSHClientUserAuthenticationDelegate?,
        pubkeyEnabled: Bool = true, kbdInteractiveEnabled: Bool = true, passwordEnabled: Bool = true,
        prompter: SSHCredentialPrompting,
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void,
        awaitingInput: @escaping @Sendable (Bool) -> Void
    ) {
        self.username = username
        self.inner = inner
        self.pubkeyEnabled = pubkeyEnabled
        self.kbdInteractiveEnabled = kbdInteractiveEnabled
        self.passwordEnabled = passwordEnabled
        self.prompter = prompter
        self.log = log
        self.awaitingInput = awaitingInput
    }

    public func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        var methods: [String] = []
        if availableMethods.contains(.publicKey) { methods.append("publickey") }
        if availableMethods.contains(.password) { methods.append("password") }
        if availableMethods.contains(.keyboardInteractive) { methods.append("keyboard-interactive") }
        log(.detail, "Server available methods: [\(methods.joined(separator: ", "))] innerExhausted=\(innerExhausted)")
        if pubkeyEnabled, !innerExhausted, let inner {
            // Proxy through the inner delegate; detect when it gives up via a nil offer.
            let relay = nextChallengePromise.futureResult.eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            relay.futureResult.whenSuccess { [weak self] offer in
                guard let self else { return }
                if offer == nil {
                    self.innerExhausted = true
                    self.tryKeyboardInteractive(
                        availableMethods: availableMethods,
                        promise: nextChallengePromise)
                } else {
                    nextChallengePromise.succeed(offer)
                }
            }
            relay.futureResult.whenFailure { nextChallengePromise.fail($0) }
            inner.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: relay)
        } else {
            tryKeyboardInteractive(availableMethods: availableMethods, promise: nextChallengePromise)
        }
    }

    private func tryKeyboardInteractive(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard kbdInteractiveEnabled, availableMethods.contains(.keyboardInteractive),
            !kiCancelled.withLockedValue({ $0 })
        else {
            if !kbdInteractiveEnabled {
                log(.detail, "kbd-interactive not offered: KbdInteractiveAuthentication=no")
            } else if kiCancelled.withLockedValue({ $0 }) {
                log(.detail, "kbd-interactive not re-offered: user cancelled")
            } else {
                log(
                    .detail, "kbd-interactive not in server's available methods (rawValue=\(availableMethods.rawValue))"
                )
            }
            tryPassword(availableMethods: availableMethods, promise: promise)
            return
        }
        // Allow re-offering keyboard-interactive on each FAILURE round so the user
        // can retry after a wrong TOTP code within the same connection attempt.
        log(.info, "Offering keyboard-interactive auth for \(username)")
        promise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "ssh-connection", offer: .keyboardInteractive))
    }

    /// Last resort in the fallback chain, matching OpenSSH's default
    /// `PreferredAuthentications` ordering (password after pubkey/keyboard-interactive).
    /// Unlike keyboard-interactive, the `password` method has no server-driven
    /// challenge round — the client just prompts locally and submits the offer.
    private func tryPassword(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard passwordEnabled, availableMethods.contains(.password),
            !passwordCancelled.withLockedValue({ $0 })
        else {
            if !passwordEnabled {
                log(.detail, "password not offered: PasswordAuthentication=no")
            } else if passwordCancelled.withLockedValue({ $0 }) {
                log(.detail, "password not re-offered: user cancelled")
            } else {
                log(.detail, "password not in server's available methods (rawValue=\(availableMethods.rawValue))")
            }
            exhaustedAllMethods = true
            promise.succeed(nil)
            return
        }
        log(.info, "Prompting for a password for \(username)")
        awaitingInput(true)
        let username = self.username
        let prompter = self.prompter
        let log = self.log
        let passwordCancelled = self.passwordCancelled
        let awaitingInput = self.awaitingInput
        Task {
            defer { awaitingInput(false) }
            guard let password = await prompter.promptForPassword(username: username) else {
                log(.detail, "password prompt cancelled")
                passwordCancelled.withLockedValue { $0 = true }
                promise.succeed(nil)
                return
            }
            promise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username, serviceName: "ssh-connection", offer: .password(.init(password: password))))
        }
    }

    public func handleChallenge(
        name: String,
        instruction: String,
        prompts: [(text: String, echo: Bool)],
        responsePromise: EventLoopPromise<[String]>
    ) {
        log(
            .info,
            "kbd-interactive challenge: \(prompts.count) prompt(s) — \(prompts.map(\.text).joined(separator: ", "))")
        awaitingInput(true)
        let prompter = self.prompter
        let log = self.log
        let kiCancelled = self.kiCancelled
        let awaitingInput = self.awaitingInput
        let promptValues = prompts.map { SSHAuthPrompt(text: $0.text, echo: $0.echo) }
        Task {
            log(.detail, "Requesting kbd-interactive responses from the host program")
            defer { awaitingInput(false) }
            guard
                let responses = await prompter.promptForChallenges(
                    name: name, instruction: instruction, prompts: promptValues)
            else {
                // User cancelled — mark KI exhausted so we don't re-offer it, then send
                // empty strings so the server sends FAILURE and closes auth cleanly.
                log(.detail, "kbd-interactive alert cancelled")
                kiCancelled.withLockedValue { $0 = true }
                responsePromise.succeed(Array(repeating: "", count: prompts.count))
                return
            }
            log(.detail, "kbd-interactive responses collected, sending to server")
            responsePromise.succeed(responses)
        }
    }

}

/// Verifies the server's host key against a snapshot of known_hosts: trusts a
/// matching key, refuses a changed key (possible MITM), and trusts-on-first-use
/// for hosts not yet in known_hosts.
public nonisolated final class KnownHostsValidatingDelegate: NIOSSHClientServerAuthenticationDelegate {
    /// The name used to match/write known_hosts entries — `HostKeyAlias` when set,
    /// otherwise the real connection target.
    private let host: String
    private let port: Int
    private let entries: [KnownHostEntry]
    private let policy: HostKeyCheckingPolicy
    /// The real connection target, used only for the `NoHostAuthenticationForLocalhost`
    /// loopback check — distinct from `host` since `HostKeyAlias` can rename the
    /// known_hosts lookup key without changing what's actually being connected to.
    private let realHost: String
    /// `NoHostAuthenticationForLocalhost` — when true and `realHost` is loopback,
    /// trust unconditionally without even fingerprinting the key.
    private let skipForLocalhost: Bool
    private let log: @Sendable (TunnelLogLevel, String) -> Void
    /// Called with the accepted key's `"type base64"` line on trust-on-first-use
    /// (audit #9) so the caller can write it back to known_hosts — without this, a
    /// later changed key on the same host is silently re-trusted forever instead of
    /// refused as a possible MITM. Nil in contexts that don't want a write (e.g.
    /// `EmbeddedSSHTestServer`-backed tests).
    private let persistTrustedKey: (@Sendable (String) -> Void)?

    public init(
        host: String, port: Int, entries: [KnownHostEntry], realHost: String? = nil,
        policy: HostKeyCheckingPolicy = .acceptNew, skipForLocalhost: Bool = false,
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void,
        persistTrustedKey: (@Sendable (String) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.entries = entries
        self.policy = policy
        self.realHost = realHost ?? host
        self.skipForLocalhost = skipForLocalhost
        self.log = log
        self.persistTrustedKey = persistTrustedKey
    }

    /// HMAC-SHA1 backing for matching hashed known_hosts entries. Lives here (not
    /// in SSHConfigCore) so the pure core stays Foundation-only and portable.
    public static let hmacSHA1: KnownHostsVerifier.HMACSHA1 = { salt, message in
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: message, using: SymmetricKey(data: salt))
        return Data(mac)
    }

    private static let loopbackHostNames: Set<String> = ["localhost", "127.0.0.1", "::1"]

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if skipForLocalhost, Self.loopbackHostNames.contains(realHost.lowercased()) {
            log(.detail, "Host key check skipped for \(realHost) (NoHostAuthenticationForLocalhost)")
            validationCompletePromise.succeed(())
            return
        }

        // "ssh-ed25519 <base64>" → take the blob and fingerprint it the same way
        // KnownHostsService does, so the comparison is apples to apples.
        let openSSH = String(openSSHPublicKey: hostKey)
        let blob = openSSH.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard !blob.isEmpty, let fingerprint = KeyFingerprint.sha256(base64Blob: blob) else {
            // Couldn't fingerprint the server key — refuse rather than fall through to TOFU.
            log(.error, "Couldn't read \(host)'s host key — refused")
            validationCompletePromise.fail(SSHForwardError.hostKeyMismatch)
            return
        }

        let decision = KnownHostsVerifier.decide(
            host: host, port: port, fingerprint: fingerprint,
            entries: entries, hmacSHA1: Self.hmacSHA1)
        switch (decision, KnownHostsVerifier.action(for: decision, policy: policy, host: host)) {
        case (.match, .trust):
            log(.detail, "Host key verified for \(host) (known_hosts)")
            validationCompletePromise.succeed(())
        case (.unknown, .trust):
            log(.info, "Host key trusted on first use for \(host)")
            persistTrustedKey?(openSSH)
            validationCompletePromise.succeed(())
        case (.mismatch, .trust):
            log(.info, "Host key for \(host) changed but StrictHostKeyChecking=no — trusted anyway")
            validationCompletePromise.succeed(())
        case (_, .refuse(let reason)):
            log(.error, reason)
            validationCompletePromise.fail(SSHForwardError.hostKeyMismatch)
        }
    }
}
