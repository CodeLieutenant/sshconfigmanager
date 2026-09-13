//===----------------------------------------------------------------------===//
//
// This file is part of the vendored, patched swift-nio-ssh. See Vendor/PATCH.md.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOCore
import NIOFoundationCompat

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `mlkem768x25519-sha256` — the post-quantum hybrid key exchange OpenSSH 9.9 offers first,
/// and the only method some hardened servers accept.
///
/// It reuses the ECDH message pair (`SSH_MSG_KEX_ECDH_INIT` / `_REPLY`), because both
/// messages carry their payload as one opaque SSH string. What differs from RFC 5656 ECDH:
///
///   - `C_INIT` is the client's ML-KEM-768 encapsulation key (1184 bytes) followed by its
///     X25519 public key (32 bytes).
///   - `S_REPLY` is the ML-KEM-768 ciphertext (1088 bytes) followed by the server's X25519
///     public key (32 bytes).
///   - `K` is `SHA256(K_ML-KEM ‖ K_X25519)`, and — unlike every ECDH method — it is fed into
///     the exchange hash and the key derivation **as an SSH string**, not as an mpint.
///
/// The hybrid is secure if *either* primitive holds, which is the point: X25519 covers a
/// break in ML-KEM, and ML-KEM covers a future quantum attack on X25519.
///
/// The ML-KEM half comes from ``NIOSSHMLKEM/backend``: CryptoKit's where the system has it,
/// otherwise whatever the application registered. If neither exists the method is not
/// offered at all — `supportedKeyExchangeImplementations` leaves it out — and negotiation
/// falls back to `curve25519-sha256`, which every OpenSSH server that offers this one also
/// offers.
struct MLKEM768X25519KeyExchange: EllipticCurveKeyExchangeProtocol {
    static let keyExchangeAlgorithmNames: [Substring] = ["mlkem768x25519-sha256"]

    /// FIPS 203 sizes for ML-KEM-768, plus X25519's fixed 32-byte public key.
    private static let encapsulationKeySize = 1184
    private static let ciphertextSize = 1088
    private static let x25519PublicKeySize = 32

    private var previousSessionIdentifier: ByteBuffer?
    private var ourRole: SSHConnectionRole

    /// Only the client holds an ML-KEM private key: it publishes the encapsulation key and
    /// decapsulates the server's ciphertext. The server never generates an ML-KEM keypair.
    private var ourMLKEMKey: (any NIOSSHMLKEM768PrivateKey)?
    private var ourEncapsulationKey: [UInt8]?
    private var ourX25519Key: Curve25519.KeyAgreement.PrivateKey

    /// The two blobs verbatim as they went on the wire, because the exchange hash covers
    /// exactly those bytes and re-serializing risks disagreeing with what the peer hashed.
    private var clientInit: ByteBuffer?
    private var serverReply: ByteBuffer?

    init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
        self.ourX25519Key = Curve25519.KeyAgreement.PrivateKey()
        if ourRole.isClient, let keyPair = try? NIOSSHMLKEM.backend?.generateKeyPair() {
            self.ourEncapsulationKey = keyPair.encapsulationKey
            self.ourMLKEMKey = keyPair.privateKey
        }
    }

    func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) throws
        -> SSHMessage.KeyExchangeECDHInitMessage
    {
        precondition(self.ourRole.isClient, "Only clients may initiate client side key exchange!")
        // The offer is gated on a backend existing, not on this keypair having worked, so a
        // backend that fails at generation time lands here. Throwing aborts this handshake;
        // crashing would take the app down over a peer's choice of key exchange method.
        guard let encapsulationKey = self.ourEncapsulationKey else {
            throw NIOSSHError.keyExchangeNegotiationFailure
        }

        var buffer = allocator.buffer(capacity: Self.encapsulationKeySize + Self.x25519PublicKeySize)
        buffer.writeBytes(encapsulationKey)
        buffer.writeContiguousBytes(self.ourX25519Key.publicKey.rawRepresentation)
        return .init(publicKey: buffer)
    }

    mutating func completeKeyExchangeServerSide(
        clientKeyExchangeMessage message: SSHMessage.KeyExchangeECDHInitMessage,
        serverHostKey: NIOSSHPrivateKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, SSHMessage.KeyExchangeECDHReplyMessage) {
        precondition(self.ourRole.isServer, "Only servers may complete server side key exchange!")

        let (encapsulationKeyBytes, clientX25519Bytes) = try Self.split(
            message.publicKey, first: Self.encapsulationKeySize, second: Self.x25519PublicKeySize)

        guard let backend = NIOSSHMLKEM.backend else {
            throw NIOSSHError.keyExchangeNegotiationFailure
        }
        let encapsulation = try backend.encapsulate(encapsulationKey: encapsulationKeyBytes)
        let x25519Secret = try self.ourX25519Key.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientX25519Bytes))

        var reply = allocator.buffer(capacity: Self.ciphertextSize + Self.x25519PublicKeySize)
        reply.writeBytes(encapsulation.ciphertext)
        reply.writeContiguousBytes(self.ourX25519Key.publicKey.rawRepresentation)

        self.clientInit = message.publicKey
        self.serverReply = reply

        let sharedSecret = Self.combine(mlkem: encapsulation.sharedSecret, x25519: x25519Secret)
        let result = self.finalize(
            sharedSecret: sharedSecret,
            serverHostKey: serverHostKey.publicKey,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )

        let signature = try serverHostKey.sign(digest: result.exchangeHash)
        return (
            KeyExchangeResult(sessionID: result.sessionID, keys: result.keys),
            .init(hostKey: serverHostKey.publicKey, publicKey: reply, signature: signature)
        )
    }

    mutating func receiveServerKeyExchangePayload(
        serverKeyExchangeMessage message: SSHMessage.KeyExchangeECDHReplyMessage,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        precondition(self.ourRole.isClient, "Only clients may receive server key exchange packets!")
        guard let mlkemKey = self.ourMLKEMKey else {
            throw NIOSSHError.keyExchangeNegotiationFailure
        }

        let (ciphertext, serverX25519Bytes) = try Self.split(
            message.publicKey, first: Self.ciphertextSize, second: Self.x25519PublicKeySize)

        let mlkemSecret = try mlkemKey.decapsulate(ciphertext)
        let x25519Secret = try self.ourX25519Key.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverX25519Bytes))

        self.clientInit = try self.initiateKeyExchangeClientSide(allocator: allocator).publicKey
        self.serverReply = message.publicKey

        let sharedSecret = Self.combine(mlkem: mlkemSecret, x25519: x25519Secret)
        let result = self.finalize(
            sharedSecret: sharedSecret,
            serverHostKey: message.hostKey,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )

        guard message.hostKey.isValidSignature(message.signature, for: result.exchangeHash) else {
            throw NIOSSHError.invalidExchangeHashSignature
        }

        return KeyExchangeResult(sessionID: result.sessionID, keys: result.keys)
    }
}

extension MLKEM768X25519KeyExchange {
    private struct Outcome {
        var sessionID: ByteBuffer
        var exchangeHash: SHA256.Digest
        var keys: NIOSSHSessionKeys
    }

    /// Appends the method-specific tail of the exchange hash — host key, `C_INIT`, `S_REPLY`,
    /// then `K` — and derives the session keys from it.
    private func finalize(
        sharedSecret: [UInt8],
        serverHostKey: NIOSSHPublicKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) -> Outcome {
        initialExchangeBytes.writeCompositeSSHString {
            $0.writeSSHHostKey(serverHostKey)
        }
        initialExchangeBytes.writeSSHString(self.clientInit!.readableBytesView)
        initialExchangeBytes.writeSSHString(self.serverReply!.readableBytesView)

        var hasher = SHA256()
        hasher.update(data: initialExchangeBytes.readableBytesView)
        // K as an SSH string, which is what makes this method's hash differ from ECDH's.
        Self.updateAsSSHString(&hasher, sharedSecret)
        let exchangeHash = hasher.finalize()

        let sessionID: ByteBuffer
        if let previousSessionIdentifier = self.previousSessionIdentifier {
            sessionID = previousSessionIdentifier
        } else {
            var hashBytes = allocator.buffer(capacity: SHA256.Digest.byteCount)
            hashBytes.writeContiguousBytes(exchangeHash)
            sessionID = hashBytes
        }

        var baseHasher = SHA256()
        Self.updateAsSSHString(&baseHasher, sharedSecret)
        exchangeHash.withUnsafeBytes { baseHasher.update(bufferPointer: $0) }

        let keys = SSHKeyDerivation.sessionKeys(
            baseHasher: baseHasher,
            sessionID: sessionID,
            ourRole: self.ourRole,
            expectedKeySizes: expectedKeySizes
        )
        return Outcome(sessionID: sessionID, exchangeHash: exchangeHash, keys: keys)
    }

    /// `K = SHA256(K_ML-KEM ‖ K_X25519)`, both 32 bytes.
    private static func combine(mlkem: [UInt8], x25519: SharedSecret) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(data: mlkem)
        x25519.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return Array(hasher.finalize())
    }

    private static func updateAsSSHString<Hasher: HashFunction>(_ hasher: inout Hasher, _ bytes: [UInt8]) {
        hasher.update(data: withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Array($0) })
        hasher.update(data: bytes)
    }

    /// Splits a fixed-layout blob, rejecting anything that is not exactly the right size —
    /// a peer that sends a short or long blob is not speaking this method.
    private static func split(_ buffer: ByteBuffer, first: Int, second: Int) throws -> ([UInt8], [UInt8]) {
        var buffer = buffer
        guard buffer.readableBytes == first + second,
            let head = buffer.readBytes(length: first),
            let tail = buffer.readBytes(length: second)
        else {
            throw NIOSSHError.invalidPacketFormat
        }
        return (head, tail)
    }
}
