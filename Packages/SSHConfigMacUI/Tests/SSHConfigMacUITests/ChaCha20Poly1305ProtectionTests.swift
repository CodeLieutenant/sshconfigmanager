//
//  ChaCha20Poly1305ProtectionTests.swift
//  SSHConfigMacUITests
//
//  `chacha20-poly1305@openssh.com` is assembled from two primitives rather than taken whole
//  from a library, so these pin the assembly: that the length field really is encrypted
//  under the second key, that every packet is keyed off its own sequence number, and that a
//  tampered or replayed tag is refused.
//
//  The packet framing is built by hand because NIOSSH keeps `writeSSHPacket` internal — the
//  frame is four bytes of length, one of padding length, the payload, then the padding.
//

import Crypto
import Foundation
import NIOCore
import NIOSSH
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

struct ChaCha20Poly1305ProtectionTests {
    private static func keys() -> NIOSSHSessionKeys {
        NIOSSHSessionKeys(
            initialInboundIV: [UInt8](repeating: 0, count: 8),
            initialOutboundIV: [UInt8](repeating: 0, count: 8),
            inboundEncryptionKey: SymmetricKey(data: (0..<64).map { UInt8($0) }),
            outboundEncryptionKey: SymmetricKey(data: (0..<64).map { UInt8(128 - $0) }),
            inboundMACKey: SymmetricKey(data: [UInt8](repeating: 0, count: 64)),
            outboundMACKey: SymmetricKey(data: [UInt8](repeating: 0, count: 64))
        )
    }

    /// The peer's view of the same session: what we send inbound, they receive outbound.
    private static func inverted(_ keys: NIOSSHSessionKeys) -> NIOSSHSessionKeys {
        NIOSSHSessionKeys(
            initialInboundIV: keys.initialOutboundIV,
            initialOutboundIV: keys.initialInboundIV,
            inboundEncryptionKey: keys.outboundEncryptionKey,
            outboundEncryptionKey: keys.inboundEncryptionKey,
            inboundMACKey: keys.outboundMACKey,
            outboundMACKey: keys.inboundMACKey
        )
    }

    /// Builds one plaintext SSH packet. `lengthEncrypted` is false for this scheme, so the
    /// padded region excludes the 4-byte length, exactly as OpenSSH pads a cipher with AAD.
    private static func packet(payload: [UInt8], blockSize: Int) -> ByteBuffer {
        var padding = blockSize - ((payload.count + 1) % blockSize)
        if padding < 4 { padding += blockSize }

        var buffer = ByteBufferAllocator().buffer(capacity: payload.count + padding + 8)
        buffer.writeInteger(UInt32(1 + payload.count + padding))
        buffer.writeInteger(UInt8(padding))
        buffer.writeBytes(payload)
        buffer.writeBytes([UInt8](repeating: 0xAB, count: padding))
        return buffer
    }

    private static let payload: [UInt8] = Array("hello ssh".utf8)

    @Test func roundTripsASinglePacket() throws {
        let sessionKeys = Self.keys()
        let encryptor = try ChaCha20Poly1305TransportProtection(initialKeys: sessionKeys)
        let decryptor = try ChaCha20Poly1305TransportProtection(initialKeys: Self.inverted(sessionKeys))

        var buffer = Self.packet(payload: Self.payload, blockSize: ChaCha20Poly1305TransportProtection.cipherBlockSize)
        let plaintextLength = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self)!
        try encryptor.encryptPacket(&buffer, sequenceNumber: 7)

        // The length field must actually be encrypted — that is the whole reason this scheme
        // needs the sequence number in `decryptFirstBlock`.
        #expect(buffer.getInteger(at: buffer.readerIndex, as: UInt32.self)! != plaintextLength)

        try decryptor.decryptFirstBlock(&buffer, sequenceNumber: 7)
        #expect(buffer.getInteger(at: buffer.readerIndex, as: UInt32.self)! == plaintextLength)

        var content = try decryptor.decryptAndVerifyRemainingPacket(&buffer, sequenceNumber: 7)
        #expect(content.readBytes(length: content.readableBytes)! == Self.payload)
        #expect(buffer.readableBytes == 0)
    }

    /// Every packet keys Poly1305 and both ChaCha20 streams off its own sequence number, so
    /// a scheme that hard-codes or reuses one still round-trips the first packet.
    @Test func roundTripsAcrossSequenceNumbers() throws {
        let sessionKeys = Self.keys()
        let encryptor = try ChaCha20Poly1305TransportProtection(initialKeys: sessionKeys)
        let decryptor = try ChaCha20Poly1305TransportProtection(initialKeys: Self.inverted(sessionKeys))

        for index in 0..<8 {
            let sequenceNumber = UInt32(index) * 1000 + 5
            let payload = [UInt8](repeating: UInt8(index), count: index * 37 + 1)
            var buffer = Self.packet(payload: payload, blockSize: ChaCha20Poly1305TransportProtection.cipherBlockSize)
            try encryptor.encryptPacket(&buffer, sequenceNumber: sequenceNumber)
            try decryptor.decryptFirstBlock(&buffer, sequenceNumber: sequenceNumber)
            var content = try decryptor.decryptAndVerifyRemainingPacket(&buffer, sequenceNumber: sequenceNumber)
            #expect(content.readBytes(length: content.readableBytes)! == payload)
        }
    }

    /// Decrypting under the wrong sequence number must fail the tag, not return garbage.
    @Test func rejectsTheWrongSequenceNumber() throws {
        let sessionKeys = Self.keys()
        let encryptor = try ChaCha20Poly1305TransportProtection(initialKeys: sessionKeys)
        let decryptor = try ChaCha20Poly1305TransportProtection(initialKeys: Self.inverted(sessionKeys))

        var buffer = Self.packet(payload: Self.payload, blockSize: ChaCha20Poly1305TransportProtection.cipherBlockSize)
        try encryptor.encryptPacket(&buffer, sequenceNumber: 3)
        try decryptor.decryptFirstBlock(&buffer, sequenceNumber: 4)
        #expect(throws: (any Error).self) {
            _ = try decryptor.decryptAndVerifyRemainingPacket(&buffer, sequenceNumber: 4)
        }
    }

    @Test func rejectsATamperedPacket() throws {
        let sessionKeys = Self.keys()
        let encryptor = try ChaCha20Poly1305TransportProtection(initialKeys: sessionKeys)

        var buffer = Self.packet(payload: Self.payload, blockSize: ChaCha20Poly1305TransportProtection.cipherBlockSize)
        try encryptor.encryptPacket(&buffer, sequenceNumber: 0)

        let target = buffer.writerIndex - 17
        buffer.setInteger(buffer.getInteger(at: target, as: UInt8.self)! ^ 0x01, at: target)

        let decryptor = try ChaCha20Poly1305TransportProtection(initialKeys: Self.inverted(sessionKeys))
        try decryptor.decryptFirstBlock(&buffer, sequenceNumber: 0)
        #expect(throws: (any Error).self) {
            _ = try decryptor.decryptAndVerifyRemainingPacket(&buffer, sequenceNumber: 0)
        }
    }

    /// Splicing in another packet's tag must fail even though it is itself a valid tag.
    @Test func rejectsAReplayedTag() throws {
        let sessionKeys = Self.keys()
        let encryptor = try ChaCha20Poly1305TransportProtection(initialKeys: sessionKeys)

        func encrypted(sequenceNumber: UInt32) throws -> ByteBuffer {
            var buffer = Self.packet(
                payload: Self.payload, blockSize: ChaCha20Poly1305TransportProtection.cipherBlockSize)
            try encryptor.encryptPacket(&buffer, sequenceNumber: sequenceNumber)
            return buffer
        }

        var first = try encrypted(sequenceNumber: 0)
        let second = try encrypted(sequenceNumber: 1)
        let otherTag = second.getBytes(at: second.writerIndex - 16, length: 16)!
        first.setContiguousBytes(otherTag, at: first.writerIndex - 16)

        let decryptor = try ChaCha20Poly1305TransportProtection(initialKeys: Self.inverted(sessionKeys))
        try decryptor.decryptFirstBlock(&first, sequenceNumber: 0)
        #expect(throws: (any Error).self) {
            _ = try decryptor.decryptAndVerifyRemainingPacket(&first, sequenceNumber: 0)
        }
    }

    /// The engine must keep offering AES-GCM ahead of this scheme: its ChaCha20 comes from
    /// BoringSSL but its Poly1305 is pure Swift, so it is the slower of the two on bulk
    /// traffic and exists for servers that offer nothing else.
    @Test func isOfferedBehindTheAESGCMSchemes() {
        let names = SSHHopChainConnector.allTransportProtectionSchemes.map { $0.cipherName }
        let chacha = try? #require(names.firstIndex(of: "chacha20-poly1305@openssh.com"))
        let gcm256 = try? #require(names.firstIndex(of: "aes256-gcm@openssh.com"))
        let ctr = try? #require(names.firstIndex(of: "aes256-ctr"))
        #expect(gcm256! < chacha!)
        #expect(chacha! < ctr!)
    }
}
