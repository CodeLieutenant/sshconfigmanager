//
//  KnownHostsPatternTests.swift
//  sshconfigmanagerTests
//
//  Regression + fuzz coverage for bugs #10 and #12 in
//  docs/macos-prerelease-bug-audit.md:
//   #10 — known_hosts wildcard (`*`/`?`) and negation (`!`) patterns were not
//         implemented, so a pattern-covered host silently downgraded to TOFU-accept.
//   #12 — a non-default port also matched a bare-host (port-22) entry, causing
//         false MITM refusals for a legitimately different key on a second port.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct KnownHostsPatternTests {
    private func entry(hosts: String, fingerprint: String?) -> KnownHostEntry {
        KnownHostEntry(
            id: UUID(), lineIndex: 0, raw: "", marker: nil,
            hostsDisplay: hosts, isHashed: false,
            keyType: "ssh-ed25519", fingerprint: fingerprint)
    }

    // MARK: - #10 wildcard / negation

    @Test func wildcardEntryMatchesSubdomain() {
        let entries = [entry(hosts: "*.corp.example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "db1.corp.example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .match)
        // A substituted key under the wildcard is now a MISMATCH (was silently TOFU).
        #expect(
            KnownHostsVerifier.decide(
                host: "db1.corp.example.com", port: 22,
                fingerprint: "SHA256:evil", entries: entries) == .mismatch)
    }

    @Test func questionMarkMatchesSingleCharacter() {
        let entries = [entry(hosts: "web?.example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "web1.example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .match)
        // '?' is exactly one char — "web12" must not match.
        #expect(
            KnownHostsVerifier.decide(
                host: "web12.example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .unknown)
    }

    @Test func negatedPatternExcludesHost() {
        let entries = [
            entry(
                hosts: "*.corp.example.com,!secret.corp.example.com",
                fingerprint: "SHA256:abc")
        ]
        #expect(
            KnownHostsVerifier.decide(
                host: "db1.corp.example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .match)
        #expect(
            KnownHostsVerifier.decide(
                host: "secret.corp.example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .unknown)
    }

    @Test func literalEntryStillExactMatches() {
        let entries = [entry(hosts: "example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .match)
        #expect(
            KnownHostsVerifier.decide(
                host: "notexample.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .unknown)
    }

    // MARK: - #35 case-insensitive hostname matching (OpenSSH folds case)

    @Test func hostnameMatchingIsCaseInsensitive() {
        let entries = [entry(hosts: "Example.COM", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .match)
        // And a changed key on the same host (any case) is still a mismatch, not TOFU.
        #expect(
            KnownHostsVerifier.decide(
                host: "EXAMPLE.com", port: 22,
                fingerprint: "SHA256:evil", entries: entries) == .mismatch)
    }

    @Test func caseInsensitiveWildcardMatch() {
        let entries = [entry(hosts: "*.CORP.example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "DB1.corp.EXAMPLE.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .match)
    }

    // MARK: - #12 non-default port no longer falls back to a bare-host entry

    @Test func nonDefaultPortDoesNotMatchBareHostEntry() {
        let entries = [entry(hosts: "example.com", fingerprint: "SHA256:abc")]
        // Real sshd on 22 (key stored) + a different sshd on 2222 with a different key.
        // Must be UNKNOWN (TOFU the 2222 key), not a false MITM refusal.
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 2222,
                fingerprint: "SHA256:different", entries: entries) == .unknown)
    }

    @Test func nonDefaultPortMatchesBracketEntry() {
        let entries = [entry(hosts: "[example.com]:2222", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 2222,
                fingerprint: "SHA256:abc", entries: entries) == .match)
    }

    // MARK: - Fuzz (security-sensitive: pattern matching is user-controlled input)

    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
    }

    private func randomString<G: RandomNumberGenerator>(_ maxLen: Int, using rng: inout G) -> String {
        let alphabet = Array("ab.*?![]:019")
        let n = Int.random(in: 0...maxLen, using: &rng)
        return String((0..<n).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }

    @Test func fuzzPatternMatcherInvariants() {
        var rng = SeededRNG(seed: 0xC0FFEE)
        for _ in 0..<50_000 {
            let pattern = randomString(9, using: &rng)
            let name = randomString(9, using: &rng)
            // Must terminate and never trap on any input.
            let m = KnownHostsVerifier.hostPatternMatch(pattern, name)
            // "*" matches everything.
            #expect(KnownHostsVerifier.hostPatternMatch("*", name))
            // A wildcard-free pattern matches iff exactly equal.
            if !pattern.contains("*") && !pattern.contains("?") {
                #expect(m == (pattern == name))
            }
        }
    }

    /// The core security invariant: `decide` never returns `.match` (trust) for a
    /// presented fingerprint that isn't actually stored — however the patterns match.
    @Test func fuzzDecideNeverTrustsAWrongFingerprint() {
        var rng = SeededRNG(seed: 0xBEEF)
        let labels = ["db1", "web2", "secret", "corp", "example", "com", "x"]
        func host() -> String {
            (0..<3).map { _ in labels[Int.random(in: 0..<labels.count, using: &rng)] }.joined(separator: ".")
        }
        for _ in 0..<10_000 {
            let entryHosts = randomString(12, using: &rng) + ",*." + host()
            let stored = "SHA256:" + randomString(6, using: &rng)
            let presented = "SHA256:" + randomString(6, using: &rng)
            let d = KnownHostsVerifier.decide(
                host: host(), port: 22,
                fingerprint: presented, entries: [entry(hosts: entryHosts, fingerprint: stored)])
            if d == .match { #expect(presented == stored) }
        }
    }
}
