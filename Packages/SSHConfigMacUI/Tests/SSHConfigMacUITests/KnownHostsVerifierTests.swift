//
//  KnownHostsVerifierTests.swift
//  sshconfigmanagerTests
//
//  Trust decisions for server host keys against known_hosts entries.
//

import CryptoKit
import Foundation
import SSHConfigCore
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

struct KnownHostsVerifierTests {
    private func entry(hosts: String, fingerprint: String?, hashed: Bool = false) -> KnownHostEntry {
        KnownHostEntry(
            id: UUID(), lineIndex: 0, raw: "", marker: nil,
            hostsDisplay: hashed ? "(hashed)" : hosts,
            isHashed: hashed, keyType: "ssh-ed25519", fingerprint: fingerprint)
    }

    /// The production HMAC-SHA1 used both to mint and to match hashed entries.
    private let hmac = KnownHostsValidatingDelegate.hmacSHA1

    /// Builds a hashed (`|1|salt|hash`) entry for `canonicalName` (e.g. "example.com"
    /// or "[example.com]:2222"), the way OpenSSH's known_hosts stores it.
    private func hashedEntry(canonicalName: String, fingerprint: String?) -> KnownHostEntry {
        let salt = Data((0..<20).map { UInt8($0) })
        let digest = hmac(salt, Data(canonicalName.utf8))
        return KnownHostEntry(
            id: UUID(), lineIndex: 0, raw: "", marker: nil,
            hostsDisplay: "(hashed)", isHashed: true,
            hashSalt: salt, hashedHost: digest,
            keyType: "ssh-ed25519", fingerprint: fingerprint)
    }

    @Test func matchingFingerprintIsTrusted() {
        let entries = [entry(hosts: "example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .match)
    }

    @Test func changedKeyIsRefused() {
        let entries = [entry(hosts: "example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:DIFFERENT", entries: entries) == .mismatch)
    }

    @Test func unknownHostIsTrustOnFirstUse() {
        let entries = [entry(hosts: "other.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .unknown)
    }

    @Test func commaSeparatedHostsMatch() {
        let entries = [entry(hosts: "alias, 10.0.0.1, example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "10.0.0.1", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .match)
    }

    @Test func nonDefaultPortUsesBracketForm() {
        let entries = [entry(hosts: "[example.com]:2222", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 2222,
                fingerprint: "SHA256:abc", entries: entries) == .match)
        // The same host on the default port shouldn't match a :2222-only entry.
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .unknown)
    }

    @Test func hashedEntriesAreSkippedWithoutHasher() {
        // No hmacSHA1 supplied → hashed entries can't be matched, so .unknown.
        let entries = [entry(hosts: "", fingerprint: "SHA256:abc", hashed: true)]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries) == .unknown)
    }

    @Test func hashedMatchingFingerprintIsTrusted() {
        let entries = [hashedEntry(canonicalName: "example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries,
                hmacSHA1: hmac) == .match)
    }

    @Test func hashedChangedKeyIsRefused() {
        // The headline gap: a hashed host whose key changed must be .mismatch, not
        // silently re-trusted as .unknown.
        let entries = [hashedEntry(canonicalName: "example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:DIFFERENT", entries: entries,
                hmacSHA1: hmac) == .mismatch)
    }

    @Test func hashedUnrelatedHostIsTrustOnFirstUse() {
        let entries = [hashedEntry(canonicalName: "example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "other.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries,
                hmacSHA1: hmac) == .unknown)
    }

    @Test func hashedNonDefaultPortUsesBracketForm() {
        let entries = [hashedEntry(canonicalName: "[example.com]:2222", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 2222,
                fingerprint: "SHA256:abc", entries: entries,
                hmacSHA1: hmac) == .match)
        // Same host on the default port shouldn't match a :2222-only hashed entry.
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: entries,
                hmacSHA1: hmac) == .unknown)
    }

    @Test func nilFingerprintWithKnownHostIsMismatch() {
        let entries = [entry(hosts: "example.com", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: nil, entries: entries) == .mismatch)
    }

    // MARK: - Marker handling (regression: @revoked / @cert-authority were ignored)

    private func markedEntry(hosts: String, fingerprint: String, marker: String) -> KnownHostEntry {
        KnownHostEntry(
            id: UUID(), lineIndex: 0, raw: "", marker: marker,
            hostsDisplay: hosts, isHashed: false, keyType: "ssh-ed25519", fingerprint: fingerprint)
    }

    @Test func revokedKeyIsRefusedEvenWhenFingerprintMatches() {
        // Regression: decide() previously ignored @revoked markers, so a revoked key
        // with a matching fingerprint was accepted (.match) instead of refused (.mismatch).
        let revoked = markedEntry(hosts: "example.com", fingerprint: "SHA256:abc", marker: "@revoked")
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: [revoked]) == .mismatch
        )
    }

    @Test func certAuthorityEntryDoesNotGrantDirectHostKeyTrust() {
        // @cert-authority grants CA trust for signed certificates, not direct host-key
        // trust. With no unmarked entry the host should be .unknown (TOFU), not .match.
        let ca = markedEntry(hosts: "example.com", fingerprint: "SHA256:abc", marker: "@cert-authority")
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc", entries: [ca]) == .unknown
        )
    }

    @Test func revokedMatchSupersedesCoexistingTrustedEntry() {
        // A @revoked match on the presented fingerprint must refuse the connection even
        // when a non-revoked entry for the same host (different key) also exists.
        let revoked = markedEntry(hosts: "example.com", fingerprint: "SHA256:abc", marker: "@revoked")
        let trusted = entry(hosts: "example.com", fingerprint: "SHA256:OTHER")
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22,
                fingerprint: "SHA256:abc",
                entries: [revoked, trusted]) == .mismatch
        )
    }
}

/// `StrictHostKeyChecking` policy resolution — `KnownHostsVerifier.action(for:policy:host:)`
/// composes a raw `HostKeyDecision` with the configured policy into what the delegate
/// should actually do (trust vs refuse).
struct HostKeyCheckingPolicyTests {
    @Test func rawValueMapsYesAndStrictToStrict() {
        #expect(HostKeyCheckingPolicy(rawValue: "yes") == .strict)
        #expect(HostKeyCheckingPolicy(rawValue: "Strict") == .strict)
    }

    @Test func rawValueMapsNoAndOffToOff() {
        #expect(HostKeyCheckingPolicy(rawValue: "no") == .off)
        #expect(HostKeyCheckingPolicy(rawValue: "OFF") == .off)
    }

    @Test func rawValueDefaultsUnsetAndAskToAcceptNew() {
        #expect(HostKeyCheckingPolicy(rawValue: nil) == .acceptNew)
        #expect(HostKeyCheckingPolicy(rawValue: "ask") == .acceptNew)
        #expect(HostKeyCheckingPolicy(rawValue: "accept-new") == .acceptNew)
    }

    @Test func matchAlwaysTrustsRegardlessOfPolicy() {
        for policy in [HostKeyCheckingPolicy.strict, .acceptNew, .off] {
            #expect(KnownHostsVerifier.action(for: .match, policy: policy, host: "h") == .trust)
        }
    }

    @Test func unknownIsRefusedUnderStrict() {
        guard case .refuse = KnownHostsVerifier.action(for: .unknown, policy: .strict, host: "h") else {
            Issue.record("expected .refuse")
            return
        }
    }

    @Test func unknownIsTrustedUnderAcceptNewAndOff() {
        #expect(KnownHostsVerifier.action(for: .unknown, policy: .acceptNew, host: "h") == .trust)
        #expect(KnownHostsVerifier.action(for: .unknown, policy: .off, host: "h") == .trust)
    }

    @Test func mismatchIsRefusedUnderStrictAndAcceptNew() {
        guard case .refuse = KnownHostsVerifier.action(for: .mismatch, policy: .strict, host: "h") else {
            Issue.record("expected .refuse")
            return
        }
        guard case .refuse = KnownHostsVerifier.action(for: .mismatch, policy: .acceptNew, host: "h") else {
            Issue.record("expected .refuse")
            return
        }
    }

    @Test func mismatchIsTrustedUnderOff() {
        #expect(KnownHostsVerifier.action(for: .mismatch, policy: .off, host: "h") == .trust)
    }
}
