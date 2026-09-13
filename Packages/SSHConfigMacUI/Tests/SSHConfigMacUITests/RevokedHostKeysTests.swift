//
//  RevokedHostKeysTests.swift
//  sshconfigmanagerTests
//
//  Regression + fuzz coverage for bug #8 in docs/macos-prerelease-bug-audit.md:
//  RevokedHostKeys was parsed with the known_hosts parser (host keytype blob) even
//  though the file is bare-pubkey-per-line, and revocation was host-scoped — so a
//  standard revocation file never refused anything. Now it's parsed correctly into
//  fingerprints and refused for every host.
//

import Foundation
import SSHConfigCore
import SSHConfigCrypto
import Testing

@testable import SSHConfigMacUI

struct RevokedHostKeysTests {
    // MARK: - Parser (bare-pubkey format)

    @Test func parsesBarePublicKeyLinesSkippingTypeAndComment() {
        let text = """
            # a comment line
            ssh-ed25519 AAAABLOB1 alice@laptop
            ecdsa-sha2-nistp256 AAAABLOB2

            ssh-rsa AAAABLOB3
            """
        // Stub fingerprint: only the "AAAA…" blob tokens are decodable; the key type
        // ("ssh-ed25519", …) contains '-' and the comment isn't a blob.
        let fps = RevokedHostKeysParser.parse(text) { $0.hasPrefix("AAAA") ? "SHA256:\($0)" : nil }
        #expect(fps == ["SHA256:AAAABLOB1", "SHA256:AAAABLOB2", "SHA256:AAAABLOB3"])
    }

    @Test func realBlobsFingerprintViaKeyFingerprint() {
        // A valid base64 key blob run through the production fingerprint fn, so the
        // ConfigStore wiring (RevokedHostKeysParser + KeyFingerprint) is exercised.
        let blob = Data((0..<51).map { UInt8($0) }).base64EncodedString()
        let text = "ssh-ed25519 \(blob) server\n"
        let fps = RevokedHostKeysParser.parse(text) { KeyFingerprint.sha256(base64Blob: $0) }
        #expect(fps.count == 1)
        #expect(fps.first == KeyFingerprint.sha256(base64Blob: blob))
        #expect(fps.first?.hasPrefix("SHA256:") == true)
    }

    // MARK: - Global revocation via decide

    private func revokedEntry(_ fingerprint: String) -> KnownHostEntry {
        KnownHostEntry(
            id: UUID(), lineIndex: 0, raw: "",
            marker: KnownHostMarker.revoked.rawValue,
            hostsDisplay: "*", isHashed: false, keyType: "", fingerprint: fingerprint)
    }

    @Test func revokedKeyIsRefusedOnAnyHost() {
        let entries = [revokedEntry("SHA256:revoked")]
        // Same revoked key, three unrelated hosts — all refused.
        for host in ["a.example.com", "b.corp.net", "10.0.0.9"] {
            #expect(
                KnownHostsVerifier.decide(
                    host: host, port: 22,
                    fingerprint: "SHA256:revoked", entries: entries) == .mismatch)
        }
    }

    @Test func hostScopedRevokedEntryFailsToRefuse_whyBug8Existed() {
        // The old code parsed the bare-pubkey file with the known_hosts parser, binding
        // the revoked key to a (mis-parsed) host field, so decide never refused a
        // connection to a different target — revocation silently did nothing.
        let hostScoped = KnownHostEntry(
            id: UUID(), lineIndex: 0, raw: "",
            marker: KnownHostMarker.revoked.rawValue,
            hostsDisplay: "ssh-ed25519", isHashed: false,
            keyType: "", fingerprint: "SHA256:revoked")
        #expect(
            KnownHostsVerifier.decide(
                host: "victim.example.com", port: 22,
                fingerprint: "SHA256:revoked", entries: [hostScoped]) == .unknown)
        // The fix records the revoked key on a wildcard host, so it IS refused.
        #expect(
            KnownHostsVerifier.decide(
                host: "victim.example.com", port: 22,
                fingerprint: "SHA256:revoked", entries: [revokedEntry("SHA256:revoked")]) == .mismatch)
    }

    @Test func nonRevokedKeyOnUnknownHostStaysTOFU() {
        // A revocation list must not turn every unknown host into a refusal — only the
        // listed key is refused; anything else is still trust-on-first-use.
        let entries = [revokedEntry("SHA256:revoked")]
        #expect(
            KnownHostsVerifier.decide(
                host: "a.example.com", port: 22,
                fingerprint: "SHA256:legit", entries: entries) == .unknown)
    }

    // MARK: - Fuzz (revocation file is untrusted user input)

    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 1 : seed }
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
    }

    @Test func fuzzParserNeverCrashesAndOnlyEmitsFingerprintedBlobs() {
        var rng = SeededRNG(seed: 0x5EED)
        let alphabet = Array("AB -\n\t#@:[]0/+=")
        for _ in 0..<20_000 {
            let n = Int.random(in: 0...40, using: &rng)
            let text = String((0..<n).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
            // Fingerprint only tokens beginning with "AAAA"; the parser must terminate
            // and every emitted fingerprint must correspond to such a token.
            let fps = RevokedHostKeysParser.parse(text) { $0.hasPrefix("AAAA") ? "fp:\($0)" : nil }
            for fp in fps { #expect(fp.hasPrefix("fp:AAAA")) }
        }
    }
}
