//===----------------------------------------------------------------------===//
//
// This file is part of the vendored, patched swift-nio-ssh. See Vendor/PATCH.md.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOCore

/// RFC 4253 § 7.2 key derivation, shared by every key exchange method.
///
/// Extracted from `EllipticCurveKeyExchange` so the post-quantum hybrid exchange derives
/// its keys through exactly the same code. The only thing a method has to do differently is
/// how it folds `K` into `baseHasher` — an mpint for ECDH, a string for the hybrid — which
/// is why that step stays with the caller.
enum SSHKeyDerivation {
    /// Derives all six session keys.
    ///
    /// - Parameters:
    ///   - baseHasher: a hasher already updated with `K || H`.
    ///   - sessionID: the connection's session identifier.
    ///   - ourRole: decides which of each pair is inbound and which outbound.
    ///   - expectedKeySizes: how many bytes the negotiated transport protection wants.
    static func sessionKeys<Hasher: HashFunction>(
        baseHasher: Hasher,
        sessionID: ByteBuffer,
        ourRole: SSHConnectionRole,
        expectedKeySizes: ExpectedKeySizes
    ) -> NIOSSHSessionKeys {
        // - Initial IV client to server: HASH(K || H || "A" || session_id)
        // - Initial IV server to client: HASH(K || H || "B" || session_id)
        // - Encryption key client to server: HASH(K || H || "C" || session_id)
        // - Encryption key server to client: HASH(K || H || "D" || session_id)
        // - Integrity key client to server: HASH(K || H || "E" || session_id)
        // - Integrity key server to client: HASH(K || H || "F" || session_id)
        func material(_ discriminator: UnicodeScalar, _ size: Int) -> [UInt8] {
            Self.keyMaterial(
                baseHasher: baseHasher,
                discriminatorByte: UInt8(ascii: discriminator),
                sessionID: sessionID,
                expectedKeySize: size
            )
        }

        let ivSize = expectedKeySizes.ivSize
        let encryptionSize = expectedKeySizes.encryptionKeySize
        let macSize = expectedKeySizes.macKeySize

        let clientToServerIV = material("A", ivSize)
        let serverToClientIV = material("B", ivSize)
        let clientToServerEncryptionKey = SymmetricKey(data: material("C", encryptionSize))
        let serverToClientEncryptionKey = SymmetricKey(data: material("D", encryptionSize))
        let clientToServerMACKey = SymmetricKey(data: material("E", macSize))
        let serverToClientMACKey = SymmetricKey(data: material("F", macSize))

        switch ourRole {
        case .client:
            return NIOSSHSessionKeys(
                initialInboundIV: serverToClientIV,
                initialOutboundIV: clientToServerIV,
                inboundEncryptionKey: serverToClientEncryptionKey,
                outboundEncryptionKey: clientToServerEncryptionKey,
                inboundMACKey: serverToClientMACKey,
                outboundMACKey: clientToServerMACKey
            )
        case .server:
            return NIOSSHSessionKeys(
                initialInboundIV: clientToServerIV,
                initialOutboundIV: serverToClientIV,
                inboundEncryptionKey: clientToServerEncryptionKey,
                outboundEncryptionKey: serverToClientEncryptionKey,
                inboundMACKey: clientToServerMACKey,
                outboundMACKey: serverToClientMACKey
            )
        }
    }

    /// Derives `expectedKeySize` bytes for one key, applying RFC 4253 § 7.2's extension step
    /// when more bytes are wanted than one hash produces:
    ///
    ///     K1 = HASH(K || H || X || session_id)
    ///     K2 = HASH(K || H || K1)
    ///     K3 = HASH(K || H || K1 || K2)
    ///     key = K1 || K2 || K3 ...
    ///
    /// Upstream only ever took `.prefix(expectedKeySize)` of a single hash, which is correct
    /// for the schemes it bundled — AES-GCM wants at most a 32-byte key and a 12-byte IV —
    /// but silently caps key material at the key exchange's hash length. `hmac-sha2-512`
    /// wants a 64-byte integrity key, and negotiating it alongside `curve25519-sha256`
    /// leaves only 32 bytes to give it.
    private static func keyMaterial<Hasher: HashFunction>(
        baseHasher: Hasher,
        discriminatorByte: UInt8,
        sessionID: ByteBuffer,
        expectedKeySize: Int
    ) -> [UInt8] {
        var firstRound = baseHasher
        firstRound.update(byte: discriminatorByte)
        firstRound.update(data: sessionID.readableBytesView)
        var material = Array(firstRound.finalize())

        while material.count < expectedKeySize {
            var round = baseHasher
            round.update(data: material)
            material.append(contentsOf: Array(round.finalize()))
        }

        material.removeLast(material.count - expectedKeySize)
        return material
    }
}
