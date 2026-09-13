//
//  HostKeyScanner.swift
//  SSHConfigMacUI
//
//  An in-process `ssh-keyscan`: opens an SSH connection to host:port, captures the
//  host key the server actually presents during the handshake, and aborts *before*
//  user authentication — so it never logs in, never needs a key, and finishes in one
//  round-trip. Powers the Known Hosts "Verify" action, which compares the live key
//  against what `known_hosts` records (Match / CHANGED / not-stored).
//
//  Why in-process and not `ssh-keyscan`: the sandbox forbids launching subprocesses,
//  and the app already carries the NIOSSH stack for tunnels. The host-key validation
//  delegate is the exact seam where NIOSSH hands us the server's key, so we grab it
//  there and fail the validation promise to tear the connection down immediately.
//

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NIOSSHRSA
import SSHConfigCore
import SSHConfigCrypto

public enum HostKeyScanner {
    /// What the server presented: the key type (`ssh-ed25519`, …) and its `SHA256:`
    /// fingerprint, computed with the same function that fingerprints stored entries
    /// so the comparison is apples-to-apples.
    public struct Probe: Sendable, Equatable {
        public let keyType: String
        public let fingerprint: String
        /// The full `type base64` line, so the UI can offer to trust (append) the key.
        public let openSSH: String
        /// Everything the server advertised in its KEXINIT. Empty when the handshake ended
        /// before it arrived, so callers must treat it as best-effort.
        public var offer = PeerAlgorithmOffer()

        public init(
            keyType: String, fingerprint: String, openSSH: String,
            offer: PeerAlgorithmOffer = PeerAlgorithmOffer()
        ) {
            self.keyType = keyType
            self.fingerprint = fingerprint
            self.openSSH = openSSH
            self.offer = offer
        }
    }

    public enum ScanError: Error, Equatable {
        case unreachable(String) // TCP connect failed / refused
        case timedOut
        case handshakeFailed // TCP opened but the SSH handshake never offered a key
        case unreadableKey // the offered key couldn't be fingerprinted

        public var message: String {
            switch self {
            case .unreachable(let why): return why.isEmpty ? "Host unreachable." : why
            case .timedOut: return "Timed out waiting for the server."
            case .handshakeFailed: return "The server didn't complete an SSH handshake."
            case .unreadableKey: return "Couldn't read the server's host key."
            }
        }
    }

    /// Registers RSA host-key parsing with NIOSSH once (NIOSSH ships no RSA). Shares the
    /// same custom-key implementation the tunnel engine uses, so an `ssh-rsa` host key is
    /// readable off the wire. Idempotent via `static let`.
    nonisolated private static let registerCustomAlgorithms: Void = { Insecure.RSA.register() }()

    /// Connects to `host:port`, returns the offered host key — or why it couldn't.
    /// Cancellation-aware: cancelling the surrounding task tears the connection down.
    public nonisolated static func scan(host: String, port: Int, timeout: TimeInterval = 8) async -> Result<
        Probe, ScanError
    > {
        _ = registerCustomAlgorithms
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let box = ResultBox(group: group)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Probe, ScanError>, Never>) in
                guard box.attach(continuation) else { return }

                let bootstrap = ClientBootstrap(group: group)
                    .connectTimeout(.seconds(Int64(timeout)))
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            // Ahead of NIOSSHHandler so it sees the server's KEXINIT while
                            // it is still plaintext. One Verify then yields both the host
                            // key and everything the server is willing to speak.
                            try channel.pipeline.syncOperations.addHandler(
                                KexInitCaptureHandler { offer in box.record(offer) })
                            let config = SSHClientConfiguration(
                                userAuthDelegate: DecliningAuthDelegate(),
                                serverAuthDelegate: CapturingHostKeyDelegate(box: box))
                            try channel.pipeline.syncOperations.addHandler(
                                NIOSSHHandler(
                                    role: .client(config), allocator: channel.allocator,
                                    inboundChildChannelInitializer: nil))
                        }
                    }
                    .channelOption(.socketOption(.so_reuseaddr), value: 1)

                bootstrap.connect(host: host, port: port).whenComplete { result in
                    switch result {
                    case .failure(let error):
                        box.finish(.failure(.unreachable(error.localizedDescription)))
                    case .success(let channel):
                        // If the channel closes before a key was captured, the SSH
                        // handshake failed (not an SSH server, version mismatch, …).
                        channel.closeFuture.whenComplete { _ in
                            box.finish(.failure(.handshakeFailed))
                        }
                    }
                }

                // Hard ceiling independent of the TCP connect timeout, in case the
                // server accepts the socket but stalls before offering a key.
                group.next().scheduleTask(in: .seconds(Int64(timeout) + 2)) {
                    box.finish(.failure(.timedOut))
                }
            }
        } onCancel: {
            box.finish(.failure(.unreachable("Cancelled.")))
        }
    }

    // MARK: - Result coordination

    /// Serializes the single allowed completion, hands the result back through the
    /// continuation, and shuts the event-loop group down exactly once. Written from NIO
    /// callbacks on the event loop and from the cancellation handler, so it's locked.
    nonisolated private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var continuation: CheckedContinuation<Result<Probe, ScanError>, Never>?
        private let group: MultiThreadedEventLoopGroup

        /// The server's advertised algorithms, captured before the handshake is abandoned.
        /// Recorded separately from the result because it arrives first — the host key
        /// comes later, and a scan that fails after this point should still report it.
        private var offer = PeerAlgorithmOffer()

        public init(group: MultiThreadedEventLoopGroup) { self.group = group }

        public func record(_ offer: PeerAlgorithmOffer) {
            lock.lock()
            self.offer = offer
            lock.unlock()
        }

        /// Attaches the captured offer to a probe on its way out.
        private func withOffer(_ result: Result<Probe, ScanError>) -> Result<Probe, ScanError> {
            guard case .success(var probe) = result else { return result }
            probe.offer = self.offer
            return .success(probe)
        }

        /// Attaches `continuation` or, if `finish()` has already run, resumes it immediately.
        /// Returns `true` if the caller should proceed to create the bootstrap connection,
        /// or `false` if the box is done and the NIO group is already shutting down.
        @discardableResult
        public func attach(_ continuation: CheckedContinuation<Result<Probe, ScanError>, Never>) -> Bool {
            lock.lock()
            if done {
                lock.unlock()
                continuation.resume(returning: .failure(.unreachable("Cancelled.")))
                return false // NIO group is shutting down; don't create a connection
            } else {
                self.continuation = continuation
                lock.unlock()
                return true
            }
        }

        public func finish(_ incoming: Result<Probe, ScanError>) {
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            let result = withOffer(incoming)
            done = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: result)
            group.shutdownGracefully(queue: .global()) { _ in }
        }
    }

    /// Records the offered host key and then *fails* validation so NIOSSH tears the
    /// connection down immediately — we never proceed to authentication.
    nonisolated private final class CapturingHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate,
        @unchecked Sendable
    {
        private let box: ResultBox
        public init(box: ResultBox) { self.box = box }

        public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            // "ssh-ed25519 <base64>" → fingerprint the blob exactly as stored entries are.
            let openSSH = String(openSSHPublicKey: hostKey)
            let parts = openSSH.split(separator: " ")
            let keyType = parts.first.map(String.init) ?? "unknown"
            let blob = parts.dropFirst().first.map(String.init) ?? ""
            if let fingerprint = KeyFingerprint.sha256(base64Blob: blob) {
                box.finish(.success(Probe(keyType: keyType, fingerprint: fingerprint, openSSH: openSSH)))
            } else {
                box.finish(.failure(.unreadableKey))
            }
            // We have what we came for — abort the handshake.
            validationCompletePromise.fail(ScanAbort.captured)
        }
    }

    /// A no-op user-auth delegate. Never actually reached (we abort at host-key
    /// validation), but `SSHClientConfiguration` requires one.
    nonisolated private final class DecliningAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
        public func nextAuthenticationType(
            availableMethods: NIOSSHAvailableUserAuthenticationMethods,
            nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
        ) {
            nextChallengePromise.succeed(nil)
        }
    }

    private enum ScanAbort: Error { case captured }
}
