//
//  LogicPropertyTests.swift
//  sshconfigmanagerTests
//
//  Property/invariant tests for the pure logic helpers: instead of pinning one
//  example, they assert properties that must hold across many randomized inputs
//  (RandomArt shape/determinism, RSA bit-length decoding, fuzzy-match invariants).
//

import Foundation
import SSHConfigCore
import Testing

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x1234_5678_9ABC_DEF1 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}

struct RandomArtPropertyTests {

    @Test func shapeAndMarkersHoldForAnyDigest() {
        for seed in UInt64(1)...300 {
            var rng = SeededRNG(seed: seed)
            let digest = (0..<32).map { _ in UInt8(rng.next() % 256) }
            let art = RandomArt.drunkenBishop(digest: digest, title: "T", hashName: "SHA256")
            let lines = art.components(separatedBy: "\n")

            #expect(lines.count == 11) // 9 field rows + 2 borders
            #expect(lines.allSatisfy { $0.count == 19 }) // 17 inner + 2 border chars
            #expect(lines.first?.hasPrefix("+") == true && lines.first?.hasSuffix("+") == true)
            #expect(lines.last?.hasPrefix("+") == true && lines.last?.hasSuffix("+") == true)
            for row in lines.dropFirst().dropLast() {
                #expect(row.hasPrefix("|") && row.hasSuffix("|"))
            }
            // The start marker is always drawn; the end marker is too.
            #expect(art.contains("S"))
            #expect(art.contains("E"))
        }
    }

    @Test func isDeterministic() {
        for seed in UInt64(1)...100 {
            var rng = SeededRNG(seed: seed &* 11)
            let digest = (0..<32).map { _ in UInt8(rng.next() % 256) }
            let a = RandomArt.drunkenBishop(digest: digest, title: "X", hashName: "SHA256")
            let b = RandomArt.drunkenBishop(digest: digest, title: "X", hashName: "SHA256")
            #expect(a == b)
        }
    }

    @Test func digestRoundTripsThroughFingerprintString() {
        for seed in UInt64(1)...200 {
            var rng = SeededRNG(seed: seed ^ 0xFEED)
            let digest = (0..<32).map { _ in UInt8(rng.next() % 256) }
            let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let recovered = RandomArt.digest(fromSHA256Fingerprint: "SHA256:" + b64)
            #expect(recovered == digest)
        }
    }
}

struct RSABitLengthPropertyTests {

    /// A modulus with its top bit set and `byteLen` bytes is exactly `byteLen*8` bits.
    @Test func topBitSetGivesExactByteMultiple() {
        for byteLen in [128, 256, 384, 512, 768, 1024] { // 1024…8192-bit keys
            #expect(
                KeyAuditor.rsaBitLength(blob: rsaBlob(byteLen: byteLen, topBitSet: true))
                    == byteLen * 8)
        }
    }

    /// With the top byte = 0x01, the bit length is (byteLen-1)*8 + 1.
    @Test func leadingOneBitGivesExpectedLength() {
        for byteLen in [128, 256, 300] {
            #expect(
                KeyAuditor.rsaBitLength(blob: rsaBlob(byteLen: byteLen, topBitSet: false))
                    == (byteLen - 1) * 8 + 1)
        }
    }

    private func rsaBlob(byteLen: Int, topBitSet: Bool) -> [UInt8] {
        var modulus = [UInt8](repeating: 0, count: byteLen)
        modulus[0] = topBitSet ? 0x80 : 0x01
        func ssh(_ b: [UInt8]) -> [UInt8] {
            let n = UInt32(b.count)
            return [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + b
        }
        return ssh(Array("ssh-rsa".utf8)) + ssh([0x01, 0x00, 0x01]) + ssh([0x00] + modulus)
    }
}

struct FuzzyMatchPropertyTests {

    @Test func emptyQueryAlwaysMatchesWithZero() {
        for candidate in ["", "anything", "a.b-c_d", "界🔑x"] {
            #expect(FuzzyMatch.score(query: "", candidate: candidate) == 0)
            #expect(FuzzyMatch.matches(query: "", candidate: candidate))
        }
    }

    @Test func candidateAlwaysMatchesItself() {
        let words = ["web", "bastion", "git.example.com", "id_ed25519", "MixedCase"]
        for w in words {
            #expect(FuzzyMatch.matches(query: w, candidate: w))
            #expect(FuzzyMatch.matches(query: w.lowercased(), candidate: w.uppercased())) // case-insensitive
        }
    }

    @Test func nonSubsequenceNeverMatches() {
        #expect(FuzzyMatch.score(query: "xyz", candidate: "web") == nil)
        #expect(FuzzyMatch.score(query: "longerthan", candidate: "abc") == nil) // q > c
        #expect(!FuzzyMatch.matches(query: "ba", candidate: "ab")) // wrong order
    }

    @Test func matchesIffScorePresent() {
        for seed in UInt64(1)...200 {
            var rng = SeededRNG(seed: seed)
            let chars = Array("abcdefg.-_")
            func word(_ n: Int) -> String {
                String((0..<n).map { _ in chars[Int(rng.next() % UInt64(chars.count))] })
            }
            let q = word(Int(rng.next() % 5))
            let c = word(Int(rng.next() % 10))
            #expect(FuzzyMatch.matches(query: q, candidate: c) == (FuzzyMatch.score(query: q, candidate: c) != nil))
        }
    }
}
