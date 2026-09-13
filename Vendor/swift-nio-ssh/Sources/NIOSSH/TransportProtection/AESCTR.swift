//===----------------------------------------------------------------------===//
//
// This file is part of the vendored, patched swift-nio-ssh. See Vendor/PATCH.md.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _CryptoExtras
import Foundation
import NIOCore
import NIOFoundationCompat


/// The two ways SSH combines a stream cipher with a separately negotiated MAC.
enum SSHMACMode {
    /// RFC 4253: MAC over the *plaintext* packet, then encrypt everything including the
    /// length field. The receiver has to decrypt before it can authenticate.
    case encryptAndMAC
    /// `*-etm@openssh.com`: the length field stays in the clear and the MAC covers the
    /// *ciphertext*, so the receiver authenticates before it decrypts anything.
    case encryptThenMAC
}

/// The HMAC variants we pair with AES-CTR. `Crypto.HMAC` is generic over the hash, but the
/// protection scheme has to pick one at runtime from static data, so this enum stands in
/// for the type parameter.
enum SSHHMACAlgorithm {
    case sha256
    case sha512

    var digestSize: Int {
        switch self {
        case .sha256: return SHA256.byteCount
        case .sha512: return SHA512.byteCount
        }
    }

    func authenticate(_ regions: [ArraySlice<UInt8>], using key: SymmetricKey) -> [UInt8] {
        switch self {
        case .sha256:
            var hmac = HMAC<SHA256>(key: key)
            for region in regions { hmac.update(data: region) }
            return Array(hmac.finalize())
        case .sha512:
            var hmac = HMAC<SHA512>(key: key)
            for region in regions { hmac.update(data: region) }
            return Array(hmac.finalize())
        }
    }
}

/// A base class for the AES-CTR transport protection implementations.
///
/// Unlike AES-GCM, CTR mode carries no integrity of its own, so every variant pairs the
/// cipher with a separately negotiated HMAC. SSH negotiates cipher and MAC independently,
/// but `NIOSSHTransportProtection` models the pair as one object — so each supported
/// (cipher, MAC, framing) combination gets its own subclass below.
///
/// CTR keystream position is connection state, not per-packet state: the counter runs
/// continuously across every packet in one direction and only resets on rekey. Each
/// direction therefore owns a 128-bit counter block that advances by the number of blocks
/// consumed, which is also why `decryptFirstBlock` may run at most once per packet — the
/// parser's state machine guarantees that.
internal class AESCTRTransportProtection {
    private var outboundEncryptionKey: SymmetricKey
    private var inboundEncryptionKey: SymmetricKey
    private var outboundMACKey: SymmetricKey
    private var inboundMACKey: SymmetricKey
    private var outboundCounter: SSHCTRCounter
    private var inboundCounter: SSHCTRCounter

    class var cipherName: String {
        fatalError("Must override cipher name")
    }

    class var macName: String? {
        fatalError("Must override MAC name")
    }

    class var keySizes: ExpectedKeySizes {
        fatalError("Must override key sizes")
    }

    class var macAlgorithm: SSHHMACAlgorithm {
        fatalError("Must override MAC algorithm")
    }

    class var macMode: SSHMACMode {
        fatalError("Must override MAC mode")
    }

    required init(initialKeys: NIOSSHSessionKeys) throws {
        guard initialKeys.outboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
            initialKeys.inboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
            initialKeys.outboundMACKey.bitCount == Self.keySizes.macKeySize * 8,
            initialKeys.inboundMACKey.bitCount == Self.keySizes.macKeySize * 8
        else {
            throw NIOSSHError.invalidKeySize
        }

        self.outboundEncryptionKey = initialKeys.outboundEncryptionKey
        self.inboundEncryptionKey = initialKeys.inboundEncryptionKey
        self.outboundMACKey = initialKeys.outboundMACKey
        self.inboundMACKey = initialKeys.inboundMACKey
        self.outboundCounter = try SSHCTRCounter(initialIV: initialKeys.initialOutboundIV)
        self.inboundCounter = try SSHCTRCounter(initialIV: initialKeys.initialInboundIV)
    }
}

extension AESCTRTransportProtection: NIOSSHTransportProtection {
    static var cipherBlockSize: Int {
        16
    }

    var macBytes: Int {
        Self.macAlgorithm.digestSize
    }

    var lengthEncrypted: Bool {
        Self.macMode == .encryptAndMAC
    }

    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        guard newKeys.outboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
            newKeys.inboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
            newKeys.outboundMACKey.bitCount == Self.keySizes.macKeySize * 8,
            newKeys.inboundMACKey.bitCount == Self.keySizes.macKeySize * 8
        else {
            throw NIOSSHError.invalidKeySize
        }

        self.outboundEncryptionKey = newKeys.outboundEncryptionKey
        self.inboundEncryptionKey = newKeys.inboundEncryptionKey
        self.outboundMACKey = newKeys.outboundMACKey
        self.inboundMACKey = newKeys.inboundMACKey
        self.outboundCounter = try SSHCTRCounter(initialIV: newKeys.initialOutboundIV)
        self.inboundCounter = try SSHCTRCounter(initialIV: newKeys.initialInboundIV)
    }

    func decryptFirstBlock(_ source: inout ByteBuffer, sequenceNumber _: UInt32) throws {
        guard Self.macMode == .encryptAndMAC else {
            // Encrypt-then-MAC leaves the length field in the clear, exactly like AES-GCM.
            return
        }

        let blockSize = Self.cipherBlockSize
        guard let ciphertext = source.viewBytes(at: source.readerIndex, length: blockSize) else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }

        let plaintext = try self.decryptInbound(Array(ciphertext))
        source.setContiguousBytes(plaintext, at: source.readerIndex)
    }

    func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        let macBytes = self.macBytes
        guard source.readableBytes > macBytes else {
            throw NIOSSHError.invalidEncryptedPacketLength
        }
        let packetBytes = source.readableBytes - macBytes

        var plaintext: Data

        // Nested scope so the byte buffer views can't trigger an accidental CoW.
        do {
            switch Self.macMode {
            case .encryptThenMAC:
                // The MAC covers the plaintext length field plus every encrypted byte, and
                // must be checked *before* we feed anything to the cipher.
                guard let lengthView = source.readSlice(length: 4)?.readableBytesView,
                    let ciphertextView = source.readSlice(length: packetBytes - 4)?.readableBytesView,
                    let macView = source.readSlice(length: macBytes)?.readableBytesView,
                    ciphertextView.count > 0, ciphertextView.count % Self.cipherBlockSize == 0
                else {
                    throw NIOSSHError.invalidEncryptedPacketLength
                }

                try self.verifyInboundMAC(
                    macView,
                    over: [Self.sequenceBytes(sequenceNumber)[...], Array(lengthView)[...], Array(ciphertextView)[...]]
                )
                plaintext = Data(try self.decryptInbound(Array(ciphertextView)))

            case .encryptAndMAC:
                // `decryptFirstBlock` already turned the leading block into plaintext, so
                // only what follows it is still ciphertext. The MAC covers the whole
                // reassembled plaintext packet, which we can only build after decrypting.
                let blockSize = Self.cipherBlockSize
                guard packetBytes >= blockSize, packetBytes % blockSize == 0,
                    let headView = source.readSlice(length: blockSize)?.readableBytesView,
                    let tailView = source.readSlice(length: packetBytes - blockSize)?.readableBytesView,
                    let macView = source.readSlice(length: macBytes)?.readableBytesView
                else {
                    throw NIOSSHError.invalidEncryptedPacketLength
                }

                var packet = Array(headView)
                packet.append(contentsOf: try self.decryptInbound(Array(tailView)))
                try self.verifyInboundMAC(macView, over: [Self.sequenceBytes(sequenceNumber)[...], packet[...]])

                // Drop the length field; what remains is padding length, payload, padding —
                // the same shape the encrypt-then-MAC branch produces.
                plaintext = Data(packet.dropFirst(4))
            }

            // Both branches already constrained the ciphertext to whole blocks, so the only
            // thing left to reject is an empty packet — there is always a padding-length
            // byte, and `removePaddingBytes` below reads it.
            guard plaintext.count > 0 else {
                throw NIOSSHError.invalidDecryptedPlaintextLength
            }
        }

        // Strip the padding and hand back a slice of the source buffer, which is very
        // likely uniquely held — see the identical trick in the AES-GCM implementation.
        try plaintext.removePaddingBytes()
        source.prependData(plaintext)
        return source.readSlice(length: plaintext.count)!
    }

    func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let packetLengthIndex = destination.readerIndex
        let packetLengthLength = MemoryLayout<UInt32>.size
        let packetPaddingIndex = packetLengthIndex + packetLengthLength
        let packetBytes = destination.readableBytes

        switch Self.macMode {
        case .encryptAndMAC:
            // MAC the plaintext packet first, because encryption is about to overwrite it.
            let plaintext = Array(destination.viewBytes(at: packetLengthIndex, length: packetBytes)!)
            let mac = Self.macAlgorithm.authenticate(
                [Self.sequenceBytes(sequenceNumber)[...], plaintext[...]],
                using: self.outboundMACKey
            )
            let ciphertext = try self.encryptOutbound(plaintext)
            destination.setContiguousBytes(ciphertext, at: packetLengthIndex)
            destination.writeContiguousBytes(mac)

        case .encryptThenMAC:
            let encryptedLength = packetBytes - packetLengthLength
            let ciphertext = try self.encryptOutbound(
                Array(destination.viewBytes(at: packetPaddingIndex, length: encryptedLength)!)
            )
            destination.setContiguousBytes(ciphertext, at: packetPaddingIndex)

            let lengthField = Array(destination.viewBytes(at: packetLengthIndex, length: packetLengthLength)!)
            let mac = Self.macAlgorithm.authenticate(
                [Self.sequenceBytes(sequenceNumber)[...], lengthField[...], ciphertext[...]],
                using: self.outboundMACKey
            )
            destination.writeContiguousBytes(mac)
        }
    }
}

extension AESCTRTransportProtection {
    /// CTR is symmetric, so both directions are the same call — only the key and the
    /// counter differ. Each call consumes exactly `bytes.count / blockSize` counter blocks.
    private func encryptOutbound(_ bytes: [UInt8]) throws -> [UInt8] {
        let result = try AES._CTR.encrypt(bytes, using: self.outboundEncryptionKey, nonce: self.outboundCounter.nonce())
        self.outboundCounter.advance(blocks: bytes.count / Self.cipherBlockSize)
        return Array(result)
    }

    private func decryptInbound(_ bytes: [UInt8]) throws -> [UInt8] {
        let result = try AES._CTR.decrypt(bytes, using: self.inboundEncryptionKey, nonce: self.inboundCounter.nonce())
        self.inboundCounter.advance(blocks: bytes.count / Self.cipherBlockSize)
        return Array(result)
    }

    /// Constant-time comparison against the recomputed MAC. `HMAC` has no "verify a raw
    /// tag" entry point for a manually chunked message, so we recompute and compare.
    private func verifyInboundMAC(_ received: ByteBufferView, over regions: [ArraySlice<UInt8>]) throws {
        let expected = Self.macAlgorithm.authenticate(regions, using: self.inboundMACKey)
        guard received.count == expected.count else {
            throw NIOSSHError.invalidDecryptedPlaintextLength
        }

        var difference: UInt8 = 0
        for (lhs, rhs) in zip(received, expected) { difference |= lhs ^ rhs }
        guard difference == 0 else {
            throw NIOSSHError.invalidDecryptedPlaintextLength
        }
    }

    /// The packet sequence number, big-endian, which prefixes every SSH MAC input.
    private static func sequenceBytes(_ sequenceNumber: UInt32) -> [UInt8] {
        withUnsafeBytes(of: sequenceNumber.bigEndian) { Array($0) }
    }
}

// MARK: - Counter

/// A 128-bit big-endian CTR counter block, seeded from the key exchange's IV and
/// incremented once per cipher block, per RFC 4344 § 4.
struct SSHCTRCounter {
    /// Readable so `AESCTRVectorTests` can check the carry behaviour directly, which is
    /// otherwise only observable as "the next packet decrypts to noise".
    private(set) var bytes: [UInt8]

    init(initialIV: [UInt8]) throws {
        guard initialIV.count == AESCTRTransportProtection.cipherBlockSize else {
            throw NIOSSHError.invalidNonceLength
        }
        self.bytes = initialIV
    }

    func nonce() throws -> AES._CTR.Nonce {
        try AES._CTR.Nonce(nonceBytes: self.bytes)
    }

    mutating func advance(blocks: Int) {
        for _ in 0..<blocks {
            var index = self.bytes.count - 1
            while index >= 0 {
                self.bytes[index] &+= 1
                if self.bytes[index] != 0 { break }
                index -= 1
            }
        }
    }
}

// MARK: - Concrete schemes

/// Every supported (AES-CTR key size × HMAC × framing) combination. SSH negotiates the
/// cipher and the MAC separately, so each pairing has to be offered as its own scheme.
/// Encrypt-then-MAC variants are listed first everywhere, because they authenticate
/// before decrypting and OpenSSH prefers them too.

final class AES256CTRSHA256ETMTransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes256-ctr" }
    override static var macName: String? { "hmac-sha2-256-etm@openssh.com" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 32, macKeySize: 32) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha256 }
    override static var macMode: SSHMACMode { .encryptThenMAC }
}

final class AES256CTRSHA512ETMTransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes256-ctr" }
    override static var macName: String? { "hmac-sha2-512-etm@openssh.com" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 32, macKeySize: 64) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha512 }
    override static var macMode: SSHMACMode { .encryptThenMAC }
}

final class AES256CTRSHA256TransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes256-ctr" }
    override static var macName: String? { "hmac-sha2-256" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 32, macKeySize: 32) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha256 }
    override static var macMode: SSHMACMode { .encryptAndMAC }
}

final class AES256CTRSHA512TransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes256-ctr" }
    override static var macName: String? { "hmac-sha2-512" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 32, macKeySize: 64) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha512 }
    override static var macMode: SSHMACMode { .encryptAndMAC }
}

final class AES192CTRSHA256ETMTransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes192-ctr" }
    override static var macName: String? { "hmac-sha2-256-etm@openssh.com" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 24, macKeySize: 32) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha256 }
    override static var macMode: SSHMACMode { .encryptThenMAC }
}

final class AES192CTRSHA512ETMTransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes192-ctr" }
    override static var macName: String? { "hmac-sha2-512-etm@openssh.com" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 24, macKeySize: 64) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha512 }
    override static var macMode: SSHMACMode { .encryptThenMAC }
}

final class AES192CTRSHA256TransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes192-ctr" }
    override static var macName: String? { "hmac-sha2-256" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 24, macKeySize: 32) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha256 }
    override static var macMode: SSHMACMode { .encryptAndMAC }
}

final class AES192CTRSHA512TransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes192-ctr" }
    override static var macName: String? { "hmac-sha2-512" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 24, macKeySize: 64) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha512 }
    override static var macMode: SSHMACMode { .encryptAndMAC }
}

final class AES128CTRSHA256ETMTransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes128-ctr" }
    override static var macName: String? { "hmac-sha2-256-etm@openssh.com" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 16, macKeySize: 32) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha256 }
    override static var macMode: SSHMACMode { .encryptThenMAC }
}

final class AES128CTRSHA512ETMTransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes128-ctr" }
    override static var macName: String? { "hmac-sha2-512-etm@openssh.com" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 16, macKeySize: 64) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha512 }
    override static var macMode: SSHMACMode { .encryptThenMAC }
}

final class AES128CTRSHA256TransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes128-ctr" }
    override static var macName: String? { "hmac-sha2-256" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 16, macKeySize: 32) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha256 }
    override static var macMode: SSHMACMode { .encryptAndMAC }
}

final class AES128CTRSHA512TransportProtection: AESCTRTransportProtection, _NIOSSHSendableMetatype {
    override static var cipherName: String { "aes128-ctr" }
    override static var macName: String? { "hmac-sha2-512" }
    override static var keySizes: ExpectedKeySizes { .init(ivSize: 16, encryptionKeySize: 16, macKeySize: 64) }
    override static var macAlgorithm: SSHHMACAlgorithm { .sha512 }
    override static var macMode: SSHMACMode { .encryptAndMAC }
}
