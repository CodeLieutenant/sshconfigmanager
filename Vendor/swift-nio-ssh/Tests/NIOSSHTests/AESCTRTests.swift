//===----------------------------------------------------------------------===//
//
// This file is part of the vendored, patched swift-nio-ssh. See Vendor/PATCH.md.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOFoundationCompat
import XCTest
import _CryptoExtras

@testable import NIOSSH

final class AESCTRTests: XCTestCase {
    /// Every bundled AES-CTR scheme, so a new one cannot be added without coverage.
    private static let schemes: [(NIOSSHTransportProtection & _NIOSSHSendableMetatype).Type] = [
        AES256CTRSHA256ETMTransportProtection.self, AES256CTRSHA512ETMTransportProtection.self,
        AES256CTRSHA256TransportProtection.self, AES256CTRSHA512TransportProtection.self,
        AES192CTRSHA256ETMTransportProtection.self, AES192CTRSHA512ETMTransportProtection.self,
        AES192CTRSHA256TransportProtection.self, AES192CTRSHA512TransportProtection.self,
        AES128CTRSHA256ETMTransportProtection.self, AES128CTRSHA512ETMTransportProtection.self,
        AES128CTRSHA256TransportProtection.self, AES128CTRSHA512TransportProtection.self,
    ]

    private func keys(for scheme: NIOSSHTransportProtection.Type) -> NIOSSHSessionKeys {
        NIOSSHSessionKeys(
            initialInboundIV: .init(randomBytes: scheme.keySizes.ivSize),
            initialOutboundIV: .init(randomBytes: scheme.keySizes.ivSize),
            inboundEncryptionKey: SymmetricKey(data: [UInt8](randomBytes: scheme.keySizes.encryptionKeySize)),
            outboundEncryptionKey: SymmetricKey(data: [UInt8](randomBytes: scheme.keySizes.encryptionKeySize)),
            inboundMACKey: SymmetricKey(data: [UInt8](randomBytes: scheme.keySizes.macKeySize)),
            outboundMACKey: SymmetricKey(data: [UInt8](randomBytes: scheme.keySizes.macKeySize))
        )
    }

    /// One packet through encrypt then decrypt, for every scheme.
    func testRoundTripsASinglePacket() throws {
        for scheme in Self.schemes {
            let sessionKeys = self.keys(for: scheme)
            let encryptor = try scheme.init(initialKeys: sessionKeys)
            let decryptor = try scheme.init(initialKeys: sessionKeys.inverted)

            var buffer = ByteBufferAllocator().buffer(capacity: 1024)
            buffer.writeSSHPacket(
                message: .newKeys,
                lengthEncrypted: encryptor.lengthEncrypted,
                blockSize: encryptor.cipherBlockSize
            )
            try encryptor.encryptPacket(&buffer, sequenceNumber: 0)

            try decryptor.decryptFirstBlock(&buffer, sequenceNumber: 0)
            let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self)!
            XCTAssertEqual(
                Int(length) + 4 + decryptor.macBytes,
                buffer.readableBytes,
                "wrong framing for \(scheme.cipherName)/\(scheme.macName ?? "-")"
            )

            var content = try decryptor.decryptAndVerifyRemainingPacket(&buffer, sequenceNumber: 0)
            XCTAssertEqual(
                try content.readSSHMessage(),
                .newKeys,
                "round trip failed for \(scheme.cipherName)/\(scheme.macName ?? "-")"
            )
            XCTAssertEqual(content.readableBytes, 0)
            XCTAssertEqual(buffer.readableBytes, 0)
        }
    }

    /// The CTR keystream runs continuously across packets, so a scheme that resets its
    /// counter per packet still round-trips packet 0 and then produces garbage. Push
    /// several packets of differing sizes through one pair of objects to catch that.
    func testKeystreamAdvancesAcrossPackets() throws {
        for scheme in Self.schemes {
            let sessionKeys = self.keys(for: scheme)
            let encryptor = try scheme.init(initialKeys: sessionKeys)
            let decryptor = try scheme.init(initialKeys: sessionKeys.inverted)

            let messages: [SSHMessage] = [
                .newKeys,
                .serviceRequest(.init(service: "ssh-userauth")),
                .debug(.init(alwaysDisplay: false, message: String(repeating: "a", count: 300), language: "en")),
                .newKeys,
                .serviceAccept(.init(service: "ssh-connection")),
            ]

            for (sequenceNumber, message) in messages.enumerated() {
                var buffer = ByteBufferAllocator().buffer(capacity: 1024)
                buffer.writeSSHPacket(
                    message: message,
                    lengthEncrypted: encryptor.lengthEncrypted,
                    blockSize: encryptor.cipherBlockSize
                )
                try encryptor.encryptPacket(&buffer, sequenceNumber: UInt32(sequenceNumber))

                try decryptor.decryptFirstBlock(&buffer, sequenceNumber: UInt32(sequenceNumber))
                var content = try decryptor.decryptAndVerifyRemainingPacket(
                    &buffer,
                    sequenceNumber: UInt32(sequenceNumber)
                )
                XCTAssertEqual(
                    try content.readSSHMessage(),
                    message,
                    "packet \(sequenceNumber) failed for \(scheme.cipherName)/\(scheme.macName ?? "-")"
                )
            }
        }
    }

    /// A flipped bit anywhere in the packet must fail the MAC, not decrypt to garbage.
    func testRejectsATamperedPacket() throws {
        for scheme in Self.schemes {
            let sessionKeys = self.keys(for: scheme)
            let encryptor = try scheme.init(initialKeys: sessionKeys)

            var buffer = ByteBufferAllocator().buffer(capacity: 1024)
            buffer.writeSSHPacket(
                message: .newKeys,
                lengthEncrypted: encryptor.lengthEncrypted,
                blockSize: encryptor.cipherBlockSize
            )
            try encryptor.encryptPacket(&buffer, sequenceNumber: 0)

            // Flip a bit in the last ciphertext byte, just ahead of the MAC.
            let target = buffer.writerIndex - encryptor.macBytes - 1
            let original = buffer.getInteger(at: target, as: UInt8.self)!
            buffer.setInteger(original ^ 0x01, at: target)

            let decryptor = try scheme.init(initialKeys: sessionKeys.inverted)
            XCTAssertThrowsError(
                try {
                    try decryptor.decryptFirstBlock(&buffer, sequenceNumber: 0)
                    _ = try decryptor.decryptAndVerifyRemainingPacket(&buffer, sequenceNumber: 0)
                }(),
                "tampering went undetected for \(scheme.cipherName)/\(scheme.macName ?? "-")"
            )
        }
    }

    /// `hmac-sha2-512` wants a 64-byte integrity key, which is longer than the digest of
    /// `curve25519-sha256`. Without RFC 4253 § 7.2's extension step the key exchange can
    /// only produce 32 bytes and the scheme rejects the keys outright.
    func testSHA512SchemesGetAFullLengthMACKey() throws {
        let scheme = AES256CTRSHA512ETMTransportProtection.self
        XCTAssertEqual(scheme.keySizes.macKeySize, 64)
        XCTAssertNoThrow(try scheme.init(initialKeys: self.keys(for: scheme)))

        var shortKeys = self.keys(for: scheme)
        shortKeys.inboundMACKey = SymmetricKey(data: [UInt8](randomBytes: 32))
        XCTAssertThrowsError(try scheme.init(initialKeys: shortKeys))
    }

    /// The KEXINIT lists must not repeat a name just because several schemes share it.
    func testAdvertisedAlgorithmListsAreDeduplicated() {
        let ciphers = Constants.bundledTransportProtectionSchemes.map { $0.cipherName }
        let macs = Constants.bundledTransportProtectionSchemes.compactMap { $0.macName }
        XCTAssertGreaterThan(ciphers.count, Set(ciphers).count, "expected schemes to share cipher names")
        XCTAssertGreaterThan(macs.count, Set(macs).count, "expected schemes to share MAC names")

        XCTAssertEqual(
            ciphers.deduplicatedPreservingOrder(),
            ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com", "aes256-ctr", "aes192-ctr", "aes128-ctr"]
        )
        XCTAssertEqual(
            macs.deduplicatedPreservingOrder(),
            [
                "hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com",
                "hmac-sha2-256", "hmac-sha2-512",
            ]
        )
    }
}
