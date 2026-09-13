//
//  ChaCha20Poly1305Protection.swift
//  SSHConfigMacUI
//
//  `chacha20-poly1305@openssh.com` — OpenSSH's default first-preference cipher, and the
//  only one some hardened servers offer alongside AES-GCM. Lives here rather than in the
//  vendored NIOSSH fork because it needs Poly1305, which swift-crypto does not export, and
//  the fork is kept free of third-party dependencies so it stays rebasable against upstream.
//  `NIOSSHTransportProtection` is public, so plugging a scheme in from outside is supported.
//
//  Construction, per OpenSSH's PROTOCOL.chacha20poly1305 and cipher-chachapoly.c:
//
//    - The key exchange yields 64 bytes. The first 32 are the "main" key, the last 32 the
//      "header" key. Two independent keys, not one 64-byte key.
//    - The nonce for both is the packet sequence number as a big-endian UInt64.
//    - The Poly1305 one-time key is the first 32 bytes of the main keystream at counter 0.
//    - The 4-byte packet length is encrypted under the *header* key at counter 0. That is
//      why this scheme needs the sequence number in `decryptFirstBlock`.
//    - The rest of the packet is encrypted under the main key from counter 1.
//    - The tag is Poly1305 over the *ciphertext*: encrypted length ‖ encrypted payload.
//
//  Note this is NOT the RFC 8439 AEAD: that construction pads and length-prefixes the
//  Poly1305 input, so `Crypto.ChaChaPoly` cannot produce or verify these tags.
//

import CryptoSwift
import Foundation
import NIOCore
import NIOSSH
import _CryptoExtras

/// The 64-byte key material split into OpenSSH's two independent ChaCha20 keys.
private struct ChaChaKeyPair {
    public let main: SymmetricKey
    public let header: SymmetricKey

    public init(_ key: SymmetricKey) throws {
        let bytes = key.withUnsafeBytes { Array($0) }
        guard bytes.count == 64 else { throw ChaCha20Poly1305Error.invalidKeySize }
        self.main = SymmetricKey(data: bytes[0..<32])
        self.header = SymmetricKey(data: bytes[32..<64])
    }
}

public enum ChaCha20Poly1305Error: Error {
    case invalidKeySize
    case invalidPacketLength
    case tagMismatch
}

/// `chacha20-poly1305@openssh.com`.
///
/// The cipher authenticates the packet itself, so it negotiates no MAC — `macName` is nil
/// and the MAC lists are ignored, exactly like the AES-GCM schemes.
public final class ChaCha20Poly1305TransportProtection: NIOSSHTransportProtection {
    public static let cipherName = "chacha20-poly1305@openssh.com"
    public static let macName: String? = nil

    /// OpenSSH reports a block size of 8 for this cipher, which is what drives padding.
    public static let cipherBlockSize = 8

    /// 64 bytes of "encryption key" is really the two 32-byte ChaCha20 keys concatenated.
    /// The IV and MAC key are unused: the nonce is the sequence number and the Poly1305
    /// key is derived per packet. Both are still requested at a nonzero size so the key
    /// exchange does not have to special-case this scheme.
    public static let keySizes = ExpectedKeySizes(ivSize: 8, encryptionKeySize: 64, macKeySize: 64)

    public let macBytes = 16

    /// The length field *is* encrypted, but under a separate key that the padding
    /// calculation must not account for: OpenSSH excludes the length from the padded
    /// region for any cipher with associated data. `false` gives exactly that framing;
    /// `decryptFirstBlock` below still decrypts the length.
    public let lengthEncrypted = false

    private var outbound: ChaChaKeyPair
    private var inbound: ChaChaKeyPair

    public init(initialKeys: NIOSSHSessionKeys) throws {
        self.outbound = try ChaChaKeyPair(initialKeys.outboundEncryptionKey)
        self.inbound = try ChaChaKeyPair(initialKeys.inboundEncryptionKey)
    }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        self.outbound = try ChaChaKeyPair(newKeys.outboundEncryptionKey)
        self.inbound = try ChaChaKeyPair(newKeys.inboundEncryptionKey)
    }

    public func decryptFirstBlock(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws {
        guard let ciphertext = source.viewBytes(at: source.readerIndex, length: 4) else {
            throw ChaCha20Poly1305Error.invalidPacketLength
        }
        let plaintext = try Self.chaCha20(
            Array(ciphertext), key: self.inbound.header, sequenceNumber: sequenceNumber, counter: 0)
        source.setContiguousBytes(plaintext, at: source.readerIndex)
    }

    public func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer
    {
        guard source.readableBytes > 4 + self.macBytes else {
            throw ChaCha20Poly1305Error.invalidPacketLength
        }
        let payloadBytes = source.readableBytes - 4 - self.macBytes

        var plaintext: Data

        // Nested scope so the byte buffer views can't trigger an accidental CoW.
        do {
            guard let lengthView = source.readSlice(length: 4)?.readableBytesView,
                let ciphertextView = source.readSlice(length: payloadBytes)?.readableBytesView,
                let tagView = source.readSlice(length: self.macBytes)?.readableBytesView
            else {
                throw ChaCha20Poly1305Error.invalidPacketLength
            }

            // The tag covers the *encrypted* length field, but `decryptFirstBlock` already
            // replaced it with the plaintext. Re-encrypting recovers the original bytes —
            // ChaCha20 is its own inverse at the same key, nonce and counter — which keeps
            // this scheme free of any per-packet state carried between the two calls.
            let encryptedLength = try Self.chaCha20(
                Array(lengthView), key: self.inbound.header, sequenceNumber: sequenceNumber, counter: 0)

            let polyKey = try Self.poly1305Key(self.inbound.main, sequenceNumber: sequenceNumber)
            let expected = try Poly1305(key: polyKey).authenticate(encryptedLength + Array(ciphertextView))
            guard Self.constantTimeEquals(Array(tagView), expected) else {
                throw ChaCha20Poly1305Error.tagMismatch
            }

            plaintext = Data(
                try Self.chaCha20(
                    Array(ciphertextView), key: self.inbound.main, sequenceNumber: sequenceNumber, counter: 1))
        }

        try plaintext.removePaddingBytes()
        source.prependData(plaintext)
        return source.readSlice(length: plaintext.count)!
    }

    public func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let lengthIndex = destination.readerIndex
        let payloadIndex = lengthIndex + 4
        let payloadBytes = destination.readableBytes - 4

        let encryptedLength = try Self.chaCha20(
            Array(destination.viewBytes(at: lengthIndex, length: 4)!),
            key: self.outbound.header, sequenceNumber: sequenceNumber, counter: 0)
        let ciphertext = try Self.chaCha20(
            Array(destination.viewBytes(at: payloadIndex, length: payloadBytes)!),
            key: self.outbound.main, sequenceNumber: sequenceNumber, counter: 1)

        destination.setContiguousBytes(encryptedLength, at: lengthIndex)
        destination.setContiguousBytes(ciphertext, at: payloadIndex)

        let polyKey = try Self.poly1305Key(self.outbound.main, sequenceNumber: sequenceNumber)
        let tag = try Poly1305(key: polyKey).authenticate(encryptedLength + ciphertext)
        destination.writeContiguousBytes(tag)
    }
}

extension ChaCha20Poly1305TransportProtection {
    /// OpenSSH uses the original ChaCha20 (64-bit counter, 64-bit nonce); swift-crypto
    /// exposes the IETF variant (32-bit counter, 96-bit nonce). They are the same cipher
    /// whenever the counter's high word is zero, which it always is here — the counter only
    /// ever takes the values 0 and 1 — so the 96-bit nonce is four zero bytes (the counter's
    /// high word, little-endian) followed by the 64-bit nonce.
    public static func chaCha20(
        _ bytes: [UInt8], key: SymmetricKey, sequenceNumber: UInt32, counter: UInt32
    ) throws -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        var nonce = [UInt8](repeating: 0, count: 4)
        nonce.append(contentsOf: withUnsafeBytes(of: UInt64(sequenceNumber).bigEndian) { Array($0) })
        return Array(
            try Insecure.ChaCha20CTR.encrypt(
                bytes,
                using: key,
                counter: try Insecure.ChaCha20CTR.Counter(offset: counter),
                nonce: try Insecure.ChaCha20CTR.Nonce(data: nonce)
            )
        )
    }

    /// The Poly1305 one-time key: the first 32 bytes of the main keystream at counter 0.
    public static func poly1305Key(_ key: SymmetricKey, sequenceNumber: UInt32) throws -> [UInt8] {
        try self.chaCha20(
            [UInt8](repeating: 0, count: 32), key: key, sequenceNumber: sequenceNumber, counter: 0)
    }

    private static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}

// MARK: - Buffer helpers

// The vendored fork keeps its equivalents internal to NIOSSH, so this scheme needs its own.
extension ByteBuffer {
    fileprivate mutating func prependData(_ data: Data) {
        self.moveReaderIndex(to: self.readerIndex - data.count)
        self.setContiguousBytes(data, at: self.readerIndex)
    }
}

extension Data {
    /// Strips the padding-length byte and the trailing padding, leaving the payload.
    fileprivate mutating func removePaddingBytes() throws {
        guard let paddingLength = self.first, paddingLength >= 4 else {
            throw ChaCha20Poly1305Error.invalidPacketLength
        }
        let contentStart = self.index(after: self.startIndex)
        guard let contentEnd = self.index(self.endIndex, offsetBy: -Int(paddingLength), limitedBy: contentStart) else {
            throw ChaCha20Poly1305Error.invalidPacketLength
        }
        self = self[contentStart..<contentEnd]
    }
}
