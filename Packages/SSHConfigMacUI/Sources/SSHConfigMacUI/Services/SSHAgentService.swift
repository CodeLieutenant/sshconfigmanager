//
//  SSHAgentService.swift
//  sshconfigmanager
//
//  Talks to the running ssh-agent over the SSH_AUTH_SOCK Unix-domain socket.
//  Used to (1) list loaded identities for the agent-integration UI and (2) sign
//  authentication challenges for the in-process tunnel engine without ever
//  touching private-key material.
//
//  An `actor` so concurrent callers (the engine's auth path and the Agent UI's
//  refresh) are serialized and there's a single home for the socket hardening.
//  The blocking socket syscalls themselves run off the actor's executor (on a
//  global queue via a continuation) so neither the actor nor the cooperative
//  thread pool is ever blocked on I/O.
//
//  Sandbox note: reaching the agent socket works inside the App Sandbox — the
//  tunnel engine already signs over this path — so Option A (live list/remove) is
//  viable. See docs/plans/keys/agent-integration.md and docs/plans/tunneling/engine.md.
//

import Darwin
import Foundation
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigEngine

actor SSHAgentService {
    /// How long a single request/reply may take before we give up, so a wedged or
    /// hostile agent can't hang the calling Task forever (review finding H3).
    private static let timeoutSeconds = 5

    /// SIGN_REQUEST's reply can block on a human approval/Touch ID prompt —
    /// 1Password and Secretive both hold the reply open until the user responds,
    /// routinely well past 5s. Bounding it at `timeoutSeconds` made a *successful*
    /// approval at t=6s look identical to a wedged agent: `read` returned EAGAIN,
    /// auth failed, even though the user had just clicked Approve (audit #23).
    /// OpenSSH applies no such timeout to sign requests either.
    private static let signTimeoutSeconds = 120

    /// Which agent operation a socket round-trip is for — only affects the
    /// *receive* timeout (see `signTimeoutSeconds`); the send side and every
    /// other operation keep the short `timeoutSeconds` bound. Not `private` so
    /// the sign-vs-everything-else selection below is unit-testable through
    /// `@testable import` without a real socket (audit #23).
    enum Operation { case sign, other }

    /// The `SO_RCVTIMEO` bound (in seconds) for `operation` — pulled out as a pure
    /// function for the same testability reason as `Operation`.
    static func receiveTimeoutSeconds(for operation: Operation) -> Int {
        switch operation {
        case .sign: return signTimeoutSeconds
        case .other: return timeoutSeconds
        }
    }

    /// The agent socket path from the environment, if present. Fixed for the
    /// process lifetime, but read live so tests/lazily-launched agents are picked up.
    nonisolated static var socketPath: String? {
        ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
    }

    nonisolated static var isAvailable: Bool { socketPath != nil }

    /// Lists the identities the agent currently holds. `socketPath` overrides the
    /// default `SSH_AUTH_SOCK` env var — used by the tunnel engine when a hop's
    /// `IdentityAgent` directive points at a different agent (e.g. 1Password's
    /// per-app socket); nil keeps the existing default-agent behavior.
    func listIdentities(socketPath: String? = nil) async throws -> [AgentIdentity] {
        do {
            let response = try await send(SSHAgentProtocol.requestIdentitiesMessage(), socketPath: socketPath)
            let identities = try SSHAgentProtocol.parseIdentities(response)
            Log.agent.info(
                "listed \(identities.count, privacy: .public) identity(s) from \(socketPath ?? "$SSH_AUTH_SOCK", privacy: .public)"
            )
            return identities
        } catch {
            Log.agent.error("listing identities failed: \(SSHErrorText.describe(error), privacy: .public)")
            throw error
        }
    }

    /// Asks the agent to sign `data` with the key identified by `keyBlob`. See
    /// `listIdentities(socketPath:)` for what `socketPath` overrides.
    func sign(keyBlob: [UInt8], data: [UInt8], flags: UInt32 = 0, socketPath: String? = nil) async throws -> [UInt8] {
        let message = SSHAgentProtocol.signRequestMessage(keyBlob: keyBlob, data: data, flags: flags)
        // A sign request is the agent's half of public-key auth: when a tunnel says
        // "the server rejected every credential", this is where to look for whether
        // the agent was even asked.
        Log.agent.info(
            "sign request (\(data.count, privacy: .public) bytes, flags \(flags, privacy: .public))")
        do {
            let response = try await send(message, socketPath: socketPath, operation: .sign)
            let signature = try SSHAgentProtocol.parseSignature(response)
            Log.agent.info("agent returned a signature")
            return signature
        } catch {
            Log.agent.error("sign request failed: \(SSHErrorText.describe(error), privacy: .public)")
            throw error
        }
    }

    /// Loads a private key into the agent over the socket (no `ssh-add` subprocess).
    /// `body` is the ADD_IDENTITY payload from `AgentKeySerializer.addIdentityBody`.
    /// The key is loaded for the current agent session only — this does not persist
    /// the passphrase to the Keychain the way `ssh-add --apple-use-keychain` does.
    func addIdentity(body: [UInt8], socketPath: String? = nil) async throws {
        let response = try await send(SSHAgentProtocol.addIdentityMessage(body: body), socketPath: socketPath)
        try SSHAgentProtocol.parseStatus(response)
        Log.agent.notice("added an identity to the agent")
    }

    /// Unloads a single identity from the agent. Non-destructive to disk — it only
    /// drops the in-memory copy. Throws `.agentFailure` if the agent refuses (some
    /// agents, like 1Password, manage their own identities and reject removal).
    func removeIdentity(keyBlob: [UInt8], socketPath: String? = nil) async throws {
        let response = try await send(SSHAgentProtocol.removeIdentityMessage(keyBlob: keyBlob), socketPath: socketPath)
        try SSHAgentProtocol.parseStatus(response)
        Log.agent.notice("removed an identity from the agent")
    }

    /// Unloads every identity the agent currently holds.
    func removeAll(socketPath: String? = nil) async throws {
        let response = try await send(SSHAgentProtocol.removeAllIdentitiesMessage(), socketPath: socketPath)
        try SSHAgentProtocol.parseStatus(response)
        Log.agent.notice("removed every identity from the agent")
    }

    /// The `ssh-add` invocation that loads `key` into the agent. We can't add keys
    /// over the agent socket without owning the private-key/passphrase secret, and
    /// the sandbox forbids spawning `ssh-add` ourselves — so we hand the user the
    /// exact command to run in their terminal, letting `ssh-add`/Keychain own the
    /// passphrase (Option D in docs/plans/keys/agent-integration.md).
    /// `useKeychain` adds macOS's `--apple-use-keychain` so the passphrase is
    /// remembered. Returns nil if the key has no private file to load.
    nonisolated static func addCommand(for key: SSHPublicKey, useKeychain: Bool) -> String? {
        guard key.privateKeyURL != nil else { return nil }
        let keychainFlag = useKeychain ? "--apple-use-keychain " : ""
        return "ssh-add \(keychainFlag)\(shellQuote(key.identityFilePath))"
    }

    /// POSIX-sh-quotes a path so it survives being pasted into a shell verbatim,
    /// even with spaces or metacharacters (review finding C1) — see
    /// `ShellQuoting.homePath`, which keeps a leading `~/` outside the quotes.
    nonisolated static func shellQuote(_ path: String) -> String {
        ShellQuoting.homePath(path)
    }

    // MARK: - Socket I/O (blocking syscalls run off the actor's executor)

    /// Sends a framed request and returns the framed response's payload. The
    /// blocking round-trip runs on a global queue so the actor stays responsive.
    /// `socketPath`, when non-nil, overrides `Self.socketPath` for this one call.
    private func send(_ request: [UInt8], socketPath: String? = nil, operation: Operation = .other) async throws
        -> [UInt8]
    {
        guard let path = socketPath ?? Self.socketPath else { throw SSHAgentError.socketUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.roundTrip(request, socketPath: path, operation: operation))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Opens the socket, writes the request, reads one framed reply, closes.
    private static func roundTrip(_ request: [UInt8], socketPath path: String, operation: Operation) throws -> [UInt8] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHAgentError.connectionFailed(errnoText()) }
        defer { close(fd) }

        // A write to a peer that has closed (agent restart, 1Password quit) would
        // otherwise raise SIGPIPE and terminate the whole process (finding H1).
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Bound write so a stalled agent can't hang us indefinitely writing the
        // request (H3) — sending never blocks on human approval, so this always
        // uses the short bound regardless of `operation`.
        var sendTimeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        // The *reply*, though, can legitimately take much longer for SIGN_REQUEST
        // (audit #23) — see `receiveTimeoutSeconds(for:)`.
        var receiveTimeout = timeval(tv_sec: receiveTimeoutSeconds(for: operation), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else {
            throw SSHAgentError.connectionFailed("socket path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src, maxLen)
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                retrying { connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }
        guard connectResult == 0 else { throw SSHAgentError.connectionFailed(errnoText()) }

        try writeAll(fd, request)

        // Read the 4-byte length prefix, then that many payload bytes. The < 1 MB
        // cap is the real DoS guard: it stops a hostile 4-byte length prefix from
        // forcing a multi-gigabyte allocation in `readExactly`. Don't remove it.
        let lengthBytes = try readExactly(fd, 4)
        var reader = ByteReader(lengthBytes)
        let length = try reader.readUInt32()
        guard length > 0, length < 1_048_576 else { throw SSHAgentError.truncated }
        return try readExactly(fd, Int(length))
    }

    /// Retries a syscall that was interrupted by a signal (EINTR) (finding H2).
    private static func retrying<T: SignedInteger>(_ call: () -> T) -> T {
        while true {
            let result = call()
            if result < 0 && errno == EINTR { continue }
            return result
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let n = retrying { write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if n <= 0 { throw SSHAgentError.connectionFailed(errnoText()) }
                offset += n
            }
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        try buffer.withUnsafeMutableBytes { raw in
            while offset < count {
                let n = retrying { read(fd, raw.baseAddress!.advanced(by: offset), count - offset) }
                if n == 0 { throw SSHAgentError.truncated }
                if n < 0 { throw SSHAgentError.connectionFailed(errnoText()) }
                offset += n
            }
        }
        return buffer
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }

    #if DEBUG
        /// Test seam: drive the real socket round-trip against an explicit path (a
        /// loopback fake agent) so the connect/write/read/framing layer is covered
        /// without depending on the user's live `SSH_AUTH_SOCK`.
        static func roundTripForTesting(_ request: [UInt8], socketPath: String, isSign: Bool = false) throws -> [UInt8]
        {
            try roundTrip(request, socketPath: socketPath, operation: isSign ? .sign : .other)
        }
    #endif
}
