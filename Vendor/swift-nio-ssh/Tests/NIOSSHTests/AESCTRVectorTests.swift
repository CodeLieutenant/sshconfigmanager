//===----------------------------------------------------------------------===//
//
// This file is part of the vendored, patched swift-nio-ssh. See Vendor/PATCH.md.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import XCTest
import _CryptoExtras

@testable import NIOSSH

/// Known-answer coverage for the AES-CTR keystream, against NIST SP 800-38A rather than
/// against this implementation.
///
/// `AESCTRTests` round-trips every scheme through itself. That cannot catch the thing most
/// likely to be wrong here: SSH runs AES-CTR with a full 128-bit counter block seeded from
/// the key exchange IV and incremented once per cipher block (RFC 4344 § 4), and
/// `_CryptoExtras` accepts both 12- and 16-byte nonces with different meanings. A counter
/// that advances by the wrong amount, or a nonce interpreted as 12+4 rather than 16, still
/// round-trips perfectly and produces a stream no OpenSSH server can read.
final class AESCTRVectorTests: XCTestCase {
    /// SP 800-38A F.5.1 (CTR-AES128.Encrypt): key, initial counter block, and the four
    /// plaintext/ciphertext block pairs. The counter block is incremented as a single
    /// 128-bit big-endian integer between blocks, which is exactly what `SSHCTRCounter`
    /// claims to do.
    private static let key = "2b7e151628aed2a6abf7158809cf4f3c"
    private static let initialCounter = "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
    private static let plaintextBlocks = [
        "6bc1bee22e409f96e93d7e117393172a",
        "ae2d8a571e03ac9c9eb76fac45af8e51",
        "30c81c46a35ce411e5fbc1191a0a52ef",
        "f69f2445df4f9b17ad2b417be66c3710",
    ]
    private static let ciphertextBlocks = [
        "874d6191b620e3261bef6864990db6ce",
        "9806f66b7970fdff8617187bb9fffdff",
        "5ae4df3edbd5d35e5b4f09020db03eab",
        "1e031dda2fbe03d1792170a0f3009cee",
    ]

    /// One block at a time, advancing the counter between each — the shape the packet
    /// parser produces when `decryptFirstBlock` takes the leading block and
    /// `decryptAndVerifyRemainingPacket` takes the rest.
    func testBlockAtATimeMatchesNISTSP80038A() throws {
        let key = SymmetricKey(data: [UInt8](hex: Self.key))
        var counter = try SSHCTRCounter(initialIV: [UInt8](hex: Self.initialCounter))

        for (plaintext, expected) in zip(Self.plaintextBlocks, Self.ciphertextBlocks) {
            let output = try AES._CTR.encrypt([UInt8](hex: plaintext), using: key, nonce: counter.nonce())
            XCTAssertEqual(Array(output).hexString, expected)
            counter.advance(blocks: 1)
        }
    }

    /// All four blocks in one call must give the same answer as four separate calls. This
    /// is what makes `advance(blocks:)` correct: the counter has to land where the cipher
    /// left it, or the next packet decrypts to noise.
    func testOneCallMatchesFourCalls() throws {
        let key = SymmetricKey(data: [UInt8](hex: Self.key))
        let counter = try SSHCTRCounter(initialIV: [UInt8](hex: Self.initialCounter))
        let plaintext = Self.plaintextBlocks.flatMap { [UInt8](hex: $0) }

        let output = try AES._CTR.encrypt(plaintext, using: key, nonce: counter.nonce())
        XCTAssertEqual(Array(output).hexString, Self.ciphertextBlocks.joined())
    }

    /// The counter is a 128-bit big-endian integer, so a carry has to ripple across byte
    /// boundaries — including the all-ones wrap back to zero.
    func testCounterCarriesAcrossByteBoundaries() throws {
        var counter = try SSHCTRCounter(initialIV: [UInt8](hex: "000000000000000000000000000000ff"))
        counter.advance(blocks: 1)
        XCTAssertEqual(counter.bytes.hexString, "00000000000000000000000000000100")

        var wrapping = try SSHCTRCounter(initialIV: [UInt8](hex: "ffffffffffffffffffffffffffffffff"))
        wrapping.advance(blocks: 1)
        XCTAssertEqual(wrapping.bytes.hexString, "00000000000000000000000000000000")

        var multi = try SSHCTRCounter(initialIV: [UInt8](hex: "0000000000000000000000000000fffe"))
        multi.advance(blocks: 3)
        XCTAssertEqual(multi.bytes.hexString, "00000000000000000000000000010001")
    }

    /// A nonce that is not one whole cipher block is rejected rather than silently
    /// reinterpreted — `_CryptoExtras` would otherwise treat 12 bytes as nonce-plus-counter.
    func testRejectsANonBlockSizedIV() {
        XCTAssertThrowsError(try SSHCTRCounter(initialIV: [UInt8](repeating: 0, count: 12)))
        XCTAssertThrowsError(try SSHCTRCounter(initialIV: [UInt8](repeating: 0, count: 17)))
    }
}

extension Array where Element == UInt8 {
    fileprivate init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = bytes
    }

    fileprivate var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}
