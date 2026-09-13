//
//  TunnelPrimitives.swift
//  SSHConfigEngine
//
//  The error and counter types the connection, channel handlers, and hop-chain
//  connector all share. They used to sit at the top of NIOTunnelEngine.swift;
//  they moved here when the engine split out of the macOS app, because every one
//  of their users is now in this module and none of them needs AppKit.
//

import Foundation

public enum NIOTunnelError: LocalizedError {
    case noIdentityKey
    case keyLoadFailed(String)
    case noSupportedCiphers(requested: [String], supported: [String])
    case noSupportedAlgorithms(directive: String, requested: [String], supported: [String])

    public var errorDescription: String? {
        switch self {
        case .noIdentityKey:
            return
                "No usable key was found for this host — add an ssh-agent identity or an IdentityFile (ed25519/ECDSA)."
        case .keyLoadFailed(let detail):
            return "Couldn't load the private key: \(detail)"
        case .noSupportedCiphers(let requested, let supported):
            return "None of the configured Ciphers (\(requested.joined(separator: ", "))) are supported — "
                + "this engine only offers \(supported.joined(separator: ", "))."
        case .noSupportedAlgorithms(let directive, let requested, let supported):
            return "None of the configured \(directive) (\(requested.joined(separator: ", "))) are supported — "
                + "this engine only offers \(supported.joined(separator: ", "))."
        }
    }
}

public enum SSHForwardError: Error { case invalidChannelType, invalidData, hostKeyMismatch }

/// Thread-safe byte tallies, incremented from NIO event-loop callbacks and read
/// from the @MainActor store. `in`/`out` are relative to the SSH link.
/// `nonisolated` so it isn't swept up by default main-actor isolation — it's
/// constructed and mutated off the main actor (on NIO event loops).
public nonisolated final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _in: UInt64 = 0
    private var _out: UInt64 = 0

    public init() {}

    public func addIn(_ n: Int) {
        lock.lock()
        _in &+= UInt64(n)
        lock.unlock()
    }
    public func addOut(_ n: Int) {
        lock.lock()
        _out &+= UInt64(n)
        lock.unlock()
    }
    public func snapshot() -> (in: UInt64, out: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (_in, _out)
    }
}
