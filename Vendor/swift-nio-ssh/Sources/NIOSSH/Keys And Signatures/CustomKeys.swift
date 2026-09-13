//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// NIOSSH patch (sshconfigmanager): CustomKeys. Not in upstream swift-nio-ssh
// 0.13.0. Ported from the Citadel `citadel2` fork's custom-key extension point so
// app code can plug in key/signature types NIOSSH doesn't ship (notably RSA, see
// the NIOSSHRSA target). The RFC 8332 hooks (`acceptedSignaturePrefixes`,
// `publicKeyAuthAlgorithmName`) are folded in from Wellz26/swift-nio-ssh PR #3.
// See Vendor/PATCH.md.
//

import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// A signature is a mathematical scheme for verifying the authenticity of digital messages or documents.
///
/// This protocol can be implemented by a type that represents such a signature to NIOSSH.
///
/// - See: https://en.wikipedia.org/wiki/Digital_signature
public protocol NIOSSHSignatureProtocol: Sendable {
    /// An identifier that represents the type of signature used in an SSH packet.
    /// This identifier MUST be unique to the signature implementation.
    /// The returned value MUST NOT overlap with other signature implementations or a specification that the signature does not implement.
    /// This is the value written on the wire when serializing a signature produced by this type.
    static var signaturePrefix: String { get }

    /// The complete set of signature-format identifiers that this type is willing to parse
    /// from the wire. A type MAY accept several identifiers (for example an RSA signature
    /// that writes "rsa-sha2-256" but still accepts legacy "ssh-rsa" signatures during
    /// verification). Defaults to just `signaturePrefix`.
    static var acceptedSignaturePrefixes: [String] { get }

    /// The raw representation of this signature as a blob.
    var rawRepresentation: Data { get }

    /// Serializes and writes the signature to the buffer. The calling function SHOULD NOT keep track of the size of the written blob.
    /// If the result is not a fixed size, the serialized format SHOULD include a length.
    func write(to buffer: inout ByteBuffer) -> Int

    /// Reads this Signature from the buffer using the same format implemented in `write(to:)`
    static func read(from buffer: inout ByteBuffer) throws -> Self
}

public extension NIOSSHSignatureProtocol {
    /// By default a signature type only accepts its own `signaturePrefix` on the wire.
    static var acceptedSignaturePrefixes: [String] {
        [Self.signaturePrefix]
    }
}

internal extension NIOSSHSignatureProtocol {
    var signaturePrefix: String {
        Self.signaturePrefix
    }
}

public protocol NIOSSHPublicKeyProtocol: Sendable {
    /// An identifier that represents the type of public key used in an SSH packet.
    /// This identifier MUST be unique to the public key implementation.
    /// The returned value MUST NOT overlap with other public key implementations or a specification that the public key does not implement.
    static var publicKeyPrefix: String { get }

    /// The algorithm name advertised in the "public key algorithm name" field of an
    /// SSH_MSG_USERAUTH_REQUEST and in the signable payload. For most key types this is
    /// identical to `publicKeyPrefix`, but RFC 8332 allows a key whose blob format is
    /// "ssh-rsa" to authenticate with a stronger signature algorithm such as
    /// "rsa-sha2-256" or "rsa-sha2-512". Defaults to `publicKeyPrefix`.
    static var publicKeyAuthAlgorithmName: String { get }

    /// The raw representation of this public key as a blob.
    var rawRepresentation: Data { get }

    /// Verifies that `signature` is the result of signing `data` using the private key that this public key is derived from.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool

    /// Serializes and writes the public key to the buffer. The calling function SHOULD NOT keep track of the size of the written blob.
    /// If the result is not a fixed size, the serialized format SHOULD include a length.
    func write(to buffer: inout ByteBuffer) -> Int

    /// Reads this Public Key from the buffer using the same format implemented in `write(to:)`
    static func read(from buffer: inout ByteBuffer) throws -> Self
}

public extension NIOSSHPublicKeyProtocol {
    /// Defaults the userauth algorithm name to the public key blob prefix.
    static var publicKeyAuthAlgorithmName: String {
        Self.publicKeyPrefix
    }
}

internal extension NIOSSHPublicKeyProtocol {
    var publicKeyPrefix: String {
        Self.publicKeyPrefix
    }

    var publicKeyAuthAlgorithmName: String {
        Self.publicKeyAuthAlgorithmName
    }
}

public protocol NIOSSHPrivateKeyProtocol: Sendable {
    /// An identifier that represents the type of private key used in an SSH packet.
    /// This identifier MUST be unique to the private key implementation.
    /// The returned value MUST NOT overlap with other private key implementations or a specification that the private key does not implement.
    static var keyPrefix: String { get }

    /// A public key instance that is able to verify signatures that are created using this private key.
    var publicKey: NIOSSHPublicKeyProtocol { get }

    /// Creates a signature, proving that `data` has been sent by the holder of this private key, and can be verified by `publicKey`.
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol
}

internal extension NIOSSHPrivateKeyProtocol {
    var keyPrefix: String {
        Self.keyPrefix
    }
}

/// The process-wide registry of custom public-key / signature types.
///
/// Scoped intentionally to public-key authentication only — unlike the upstream
/// `citadel2` fork we do not register custom key-exchange or transport-protection
/// schemes, which NIOSSH 0.13 already covers for our needs.
public enum NIOSSHAlgorithms {
    /// Registers a custom public-key + signature type pair for use in public-key authentication.
    public static func register<
        PublicKey: NIOSSHPublicKeyProtocol,
        Signature: NIOSSHSignatureProtocol
    >(
        publicKey type: PublicKey.Type,
        signature: Signature.Type
    ) {
        _CustomAlgorithms.lock.withLockVoid {
            // Dedup by wire prefix, not type identity: the lookups in
            // readSSHHostKey / readSSHSignature match by prefix and take the first
            // hit, so registering a second type for an already-claimed prefix would
            // be silently shadowed. Reject that (first registration wins) and keep
            // re-registering the same type idempotent.
            guard !_CustomAlgorithms.publicKeyAlgorithms.contains(where: { $0.publicKeyPrefix == type.publicKeyPrefix }) else {
                return
            }
            _CustomAlgorithms.publicKeyAlgorithms.append(type)
            _CustomAlgorithms.signatures.append(signature)
        }
    }

    /// Removes all registered custom algorithms. Used by unit tests.
    internal static func unregisterAlgorithms() {
        _CustomAlgorithms.lock.withLockVoid {
            _CustomAlgorithms.publicKeyAlgorithms = []
            _CustomAlgorithms.signatures = []
        }
    }
}

private enum _CustomAlgorithms {
    static let lock = NIOLock()
    nonisolated(unsafe) static var publicKeyAlgorithms: [NIOSSHPublicKeyProtocol.Type] = []
    nonisolated(unsafe) static var signatures: [NIOSSHSignatureProtocol.Type] = []
}

extension NIOSSHPublicKey {
    static var customPublicKeyAlgorithms: [NIOSSHPublicKeyProtocol.Type] {
        _CustomAlgorithms.lock.withLock { _CustomAlgorithms.publicKeyAlgorithms }
    }

    static var customSignatures: [NIOSSHSignatureProtocol.Type] {
        _CustomAlgorithms.lock.withLock { _CustomAlgorithms.signatures }
    }
}
