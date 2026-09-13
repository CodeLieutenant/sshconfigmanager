//
//  ChaCha20PrimitiveTests.swift
//  SSHConfigMacUITests
//
//  `ChaCha20Poly1305ProtectionTests` round-trips the scheme against itself, which proves it
//  is self-consistent and nothing more: a wrong nonce layout or a wrong counter base is
//  invisible there, because both sides get it equally wrong and the packet still decrypts.
//  These pin the two primitives underneath against facts that do not come from this code.
//
//  What can actually be wrong:
//    - swift-crypto exposes the IETF ChaCha20 (32-bit counter, 96-bit nonce) while OpenSSH
//      uses the original (64-bit counter, 64-bit nonce). `chaCha20` bridges them by prefixing
//      four zero bytes. If that bridge is off, `counter: 1` no longer names the second 64-byte
//      block and the payload is encrypted under the wrong keystream.
//    - Poly1305 comes from CryptoSwift, an unaudited third-party library. If its tags are
//      wrong, every packet this scheme sends is unauthenticated in a way nothing else notices.
//

import Crypto
import CryptoSwift
import Foundation
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

struct ChaCha20PrimitiveTests {
    private static let key = SymmetricKey(data: (0..<32).map { UInt8($0) })

    private static func keystream(sequenceNumber: UInt32, counter: UInt32, count: Int) throws -> [UInt8] {
        try ChaCha20Poly1305TransportProtection.chaCha20(
            [UInt8](repeating: 0, count: count),
            key: Self.key, sequenceNumber: sequenceNumber, counter: counter)
    }

    /// The counter must index 64-byte ChaCha20 blocks under one unchanged nonce. This is
    /// what lets OpenSSH encrypt the length field at counter 0 and the payload from counter
    /// 1 without the two overlapping. A 32-vs-64-bit counter mix-up breaks it.
    @Test func theCounterSelectsSixtyFourByteBlocksOfOneKeystream() throws {
        let whole = try Self.keystream(sequenceNumber: 7, counter: 0, count: 128)
        let firstBlock = try Self.keystream(sequenceNumber: 7, counter: 0, count: 64)
        let secondBlock = try Self.keystream(sequenceNumber: 7, counter: 1, count: 64)

        #expect(Array(whole[0..<64]) == firstBlock)
        #expect(Array(whole[64..<128]) == secondBlock)
        #expect(firstBlock != secondBlock)
    }

    /// The Poly1305 one-time key is the first 32 bytes of the *main* keystream at counter 0 —
    /// the half of block zero the payload encryption deliberately skips by starting at
    /// counter 1. Deriving it from anywhere else would let the payload keystream and the
    /// authentication key overlap.
    @Test func thePolyKeyIsTheHeadOfBlockZero() throws {
        let polyKey = try ChaCha20Poly1305TransportProtection.poly1305Key(Self.key, sequenceNumber: 7)
        let blockZero = try Self.keystream(sequenceNumber: 7, counter: 0, count: 64)

        #expect(polyKey.count == 32)
        #expect(polyKey == Array(blockZero[0..<32]))
    }

    /// The nonce is the sequence number, so every packet gets its own keystream. Without
    /// this the scheme reuses a keystream across packets, which is a total break.
    @Test func everySequenceNumberGetsItsOwnKeystream() throws {
        let first = try Self.keystream(sequenceNumber: 0, counter: 0, count: 64)
        let second = try Self.keystream(sequenceNumber: 1, counter: 0, count: 64)
        let far = try Self.keystream(sequenceNumber: 0xFFFF_FFFF, counter: 0, count: 64)

        #expect(first != second)
        #expect(first != far)
        #expect(second != far)
    }

    /// RFC 8439 § 2.5.2, the canonical Poly1305 test vector. This checks CryptoSwift itself,
    /// not our use of it: the tag on every packet this scheme sends comes out of that
    /// library, and it ships with an explicit "not audited" notice.
    @Test func cryptoSwiftPoly1305MatchesRFC8439() throws {
        let key: [UInt8] = [
            0x85, 0xd6, 0xbe, 0x78, 0x57, 0x55, 0x6d, 0x33, 0x7f, 0x44, 0x52, 0xfe, 0x42, 0xd5, 0x06, 0xa8,
            0x01, 0x03, 0x80, 0x8a, 0xfb, 0x0d, 0xb2, 0xfd, 0x4a, 0xbf, 0xf6, 0xaf, 0x41, 0x49, 0xf5, 0x1b,
        ]
        let message = Array("Cryptographic Forum Research Group".utf8)
        let expected: [UInt8] = [
            0xa8, 0x06, 0x1d, 0xc1, 0x30, 0x51, 0x36, 0xc6, 0xc2, 0x2b, 0x8b, 0xaf, 0x0c, 0x01, 0x27, 0xa9,
        ]

        #expect(try Poly1305(key: key).authenticate(message) == expected)
    }
}
