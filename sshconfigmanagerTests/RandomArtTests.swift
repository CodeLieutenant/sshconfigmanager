//
//  RandomArtTests.swift
//  sshconfigmanagerTests
//
//  The drunken-bishop randomart, checked byte-for-byte against real `ssh-keygen -lv`
//  output so we never silently drift from OpenSSH's picture.
//

import Foundation
import SSHConfigCore
import Testing

struct RandomArtTests {

    /// Golden case captured from `ssh-keygen -lvf` on a real Ed25519 key.
    @Test func matchesSSHKeygenForKnownKey() {
        let fingerprint = "SHA256:MppKQ+N2KpGSKfTBMJGcVRoGd47ClxBlfkLcQFedum4"
        let digest = RandomArt.digest(fromSHA256Fingerprint: fingerprint)
        #expect(digest?.count == 32)

        // The 17-char inner rows ssh-keygen drew (trailing spaces filled below so the
        // literal can't be mangled by editors).
        let inner = [
            ".=@@++... .",
            ".*B.O.   o",
            " o+B o  .",
            " .ooo  .",
            ".++ . o S",
            "Bo o o +",
            "o.= + .",
            ".o =   E",
            " .o   .",
        ]
        let body = inner.map { "|" + $0.padding(toLength: 17, withPad: " ", startingAt: 0) + "|" }
        let expected = (["+--[ED25519 256]--+"] + body + ["+----[SHA256]-----+"])
            .joined(separator: "\n")

        let art = RandomArt.drunkenBishop(digest: digest ?? [], title: "ED25519 256", hashName: "SHA256")
        #expect(art == expected)
    }

    @Test func fingerprintWithoutPrefixIsRejected() {
        #expect(RandomArt.digest(fromSHA256Fingerprint: "MD5:aa:bb:cc") == nil)
        #expect(RandomArt.digest(fromSHA256Fingerprint: "") == nil)
    }

    /// Colon-hex must be the same SHA-256 digest as the base64 form, re-rendered.
    @Test func sha256HexFingerprintMatchesDigest() {
        let key = SSHPublicKey(
            publicKeyURL: nil, privateKeyURL: nil, algorithm: "ssh-ed25519",
            fingerprint: "SHA256:MppKQ+N2KpGSKfTBMJGcVRoGd47ClxBlfkLcQFedum4", comment: "")
        #expect(
            key.sha256HexFingerprint
                == "32:9a:4a:43:e3:76:2a:91:92:29:f4:c1:30:91:9c:55:1a:06:77:8e:c2:97:10:65:7e:42:dc:40:57:9d:ba:6e")
    }

    @Test func sha256HexFingerprintNilWithoutSHA256() {
        let key = SSHPublicKey(
            publicKeyURL: nil, privateKeyURL: nil,
            algorithm: "ssh-rsa", fingerprint: "", comment: "")
        #expect(key.sha256HexFingerprint == nil)
    }

    @Test func artHasCorrectShape() {
        let digest = [UInt8](repeating: 0xA5, count: 32)
        let lines = RandomArt.drunkenBishop(digest: digest, title: "X", hashName: "SHA256")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 11) // 9 field rows + 2 borders
        #expect(lines.allSatisfy { $0.count == 19 }) // 17 inner + 2 border chars
        #expect(lines.dropFirst().dropLast().allSatisfy { $0.hasPrefix("|") && $0.hasSuffix("|") })
    }
}
