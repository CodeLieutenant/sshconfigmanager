//
//  KexInitCaptureTests.swift
//  SSHConfigMacUITests
//
//  The parser reads bytes from an unauthenticated peer before any key exchange has run, so
//  a malformed packet must be refused rather than trusted. These cover the happy path, the
//  field ordering (which list is ciphers and which is MACs is easy to get wrong and would
//  quietly mislabel every algorithm), and truncation at each boundary.
//

import Foundation
import NIOCore
import SSHConfigCore
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

struct KexInitCaptureTests {
    /// Builds a well-formed KEXINIT with the ten name-lists in RFC 4253 order.
    private static func packet(
        kex: String = "curve25519-sha256", hostKey: String = "ssh-ed25519",
        cipherCTS: String = "aes128-ctr", cipherSTC: String = "aes256-gcm@openssh.com",
        macCTS: String = "hmac-sha1", macSTC: String = "hmac-sha2-256-etm@openssh.com"
    ) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 512)
        body.writeInteger(KexInitParser.messageID)
        body.writeBytes([UInt8](repeating: 0, count: 16)) // cookie
        for list in [kex, hostKey, cipherCTS, cipherSTC, macCTS, macSTC, "none", "none", "", ""] {
            body.writeInteger(UInt32(list.utf8.count))
            body.writeString(list)
        }
        // Two fields, five bytes: a one-byte boolean then a four-byte reserved word. This
        // used to be a single `UInt32`, one byte short of the layout in RFC 4253 § 7.1 —
        // invisible while the parser bounded reads by the buffer rather than by the packet.
        body.writeInteger(UInt8(0)) // first_kex_packet_follows
        body.writeInteger(UInt32(0)) // reserved
        var padding = 8 - ((body.readableBytes + 5) % 8)
        if padding < 4 { padding += 8 } // RFC 4253 § 6 sets four bytes as the minimum

        var packet = ByteBufferAllocator().buffer(capacity: body.readableBytes + 16)
        packet.writeInteger(UInt32(body.readableBytes + 1 + padding))
        packet.writeInteger(UInt8(padding))
        packet.writeBuffer(&body)
        packet.writeBytes([UInt8](repeating: 0, count: padding))
        return packet
    }

    @Test func parsesTheServerToClientDirection() throws {
        let offer = try #require(KexInitParser.parse(Self.packet()))
        #expect(offer.keyExchange == ["curve25519-sha256"])
        #expect(offer.hostKey == ["ssh-ed25519"])
        // Server-to-client, not client-to-server: getting these swapped would report the
        // wrong algorithms with total confidence.
        #expect(offer.ciphers == ["aes256-gcm@openssh.com"])
        #expect(offer.macs == ["hmac-sha2-256-etm@openssh.com"])
    }

    @Test func parsesMultipleNamesPerList() throws {
        let offer = try #require(
            KexInitParser.parse(Self.packet(cipherSTC: "aes256-gcm@openssh.com,3des-cbc")))
        #expect(offer.ciphers == ["aes256-gcm@openssh.com", "3des-cbc"])
    }

    @Test func flagsWeakOfferedAlgorithms() throws {
        let offer = try #require(
            KexInitParser.parse(Self.packet(cipherSTC: "aes256-gcm@openssh.com,3des-cbc", macSTC: "hmac-sha1")))
        let weak = offer.weaknesses
        #expect(weak.count == 2)
        #expect(weak.first?.severity == .error) // 3des before hmac-sha1
        #expect(weak.contains { $0.name == "3des-cbc" })
        #expect(weak.contains { $0.name == "hmac-sha1" })
    }

    @Test func staysSilentOnAHardenedServer() throws {
        let offer = try #require(
            KexInitParser.parse(
                Self.packet(
                    kex: "mlkem768x25519-sha256,curve25519-sha256",
                    cipherSTC: "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com",
                    macSTC: "hmac-sha2-512-etm@openssh.com")))
        #expect(offer.weaknesses.isEmpty)
    }

    @Test func rejectsANonKexInitMessage() {
        var packet = Self.packet()
        // Overwrite the message id (after the 4-byte length and 1-byte padding length).
        packet.setInteger(UInt8(21), at: packet.readerIndex + 5)
        #expect(KexInitParser.parse(packet) == nil)
    }

    /// A short read must yield nil, not a partly-filled offer — the handler keeps
    /// accumulating until the whole packet has arrived.
    @Test func rejectsTruncatedPacketsAtEveryLength() {
        let full = Self.packet()
        for length in stride(from: 1, to: full.readableBytes, by: 7) {
            var truncated = full
            truncated.moveWriterIndex(to: truncated.readerIndex + length)
            #expect(KexInitParser.parse(truncated) == nil, "accepted a \(length)-byte prefix")
        }
    }

    @Test func rejectsANameListLongerThanThePacket() {
        var packet = ByteBufferAllocator().buffer(capacity: 64)
        packet.writeInteger(UInt32(32))
        packet.writeInteger(UInt8(0))
        packet.writeInteger(KexInitParser.messageID)
        packet.writeBytes([UInt8](repeating: 0, count: 16))
        packet.writeInteger(UInt32.max) // a name-list claiming 4 GB
        packet.writeString("x")
        #expect(KexInitParser.parse(packet) == nil)
    }
}
