//
//  KnownHostMarkerCaseTests.swift
//  sshconfigmanagerTests
//
//  Reproducer: known_hosts trust markers are matched case-sensitively.
//
//  OpenSSH compares `@cert-authority` / `@revoked` with `strncasecmp`
//  (hostfile.c), so `@Revoked` and `@REVOKED` are valid, honoured markers. Here
//  `KnownHostEntry.resolvedMarker` does an exact `KnownHostMarker(rawValue:)`
//  lookup, so any spelling other than all-lowercase degrades to `.none` — a plain
//  host-key trust record.
//
//  The consequence is a security downgrade, not a cosmetic one: a key the user
//  explicitly revoked is filtered into `directCandidates` by
//  `KnownHostsVerifier.decide`, matches on fingerprint, and comes back `.match`
//  → trusted. Real ssh refuses that connection.
//

import Foundation
import SSHConfigCore
import SSHConfigServices
import Testing

struct KnownHostMarkerCaseTests {
    private func entry(marker: String?, fingerprint: String) -> KnownHostEntry {
        KnownHostEntry(
            lineIndex: 0, raw: "\(marker.map { $0 + " " } ?? "")example.com ssh-ed25519 AAAA",
            marker: marker, hostsDisplay: "example.com", isHashed: false,
            keyType: "ssh-ed25519", fingerprint: fingerprint)
    }

    // MARK: - The typed accessor

    @Test func lowercaseMarkersResolve() {
        #expect(entry(marker: "@revoked", fingerprint: "SHA256:abc").resolvedMarker == .revoked)
        #expect(entry(marker: "@cert-authority", fingerprint: "SHA256:abc").resolvedMarker == .certAuthority)
    }

    @Test(arguments: ["@Revoked", "@REVOKED", "@ReVoKeD"])
    func mixedCaseRevokedResolvesToRevoked(_ marker: String) {
        #expect(
            entry(marker: marker, fingerprint: "SHA256:abc").resolvedMarker == .revoked,
            "OpenSSH matches known_hosts markers case-insensitively")
    }

    @Test(arguments: ["@Cert-Authority", "@CERT-AUTHORITY"])
    func mixedCaseCertAuthorityResolves(_ marker: String) {
        #expect(entry(marker: marker, fingerprint: "SHA256:abc").resolvedMarker == .certAuthority)
    }

    // MARK: - The trust decision that depends on it

    /// The bug with teeth: a revoked key must be refused however the marker is
    /// spelled. Today `@Revoked` reads as an ordinary trusted entry, so the exact
    /// key the user revoked is trusted.
    @Test func mixedCaseRevokedKeyIsRefused() {
        let entries = [entry(marker: "@Revoked", fingerprint: "SHA256:abc")]
        let decision = KnownHostsVerifier.decide(
            host: "example.com", port: 22, fingerprint: "SHA256:abc", entries: entries)
        #expect(decision == .mismatch, "a @Revoked key must never resolve to .match")
    }

    /// Control: the all-lowercase spelling is already refused.
    @Test func lowercaseRevokedKeyIsRefused() {
        let entries = [entry(marker: "@revoked", fingerprint: "SHA256:abc")]
        #expect(
            KnownHostsVerifier.decide(
                host: "example.com", port: 22, fingerprint: "SHA256:abc", entries: entries) == .mismatch)
    }

    /// A mis-cased `@cert-authority` line must not be mistaken for a direct
    /// host-key record either — a CA key is not the host's own key.
    @Test func mixedCaseCertAuthorityIsNotADirectHostKey() {
        let entries = [entry(marker: "@Cert-Authority", fingerprint: "SHA256:abc")]
        let decision = KnownHostsVerifier.decide(
            host: "example.com", port: 22, fingerprint: "SHA256:abc", entries: entries)
        #expect(decision == .unknown, "a CA record must not be treated as the host's own key")
    }

    // MARK: - The static audit

    /// `KnownHostsAudit` excludes revoked entries from the orphan check by
    /// comparing `entry.marker != "@revoked"` — a raw string compare with the same
    /// case sensitivity. A `@Revoked` entry is therefore reported as an orphan the
    /// user is invited to clean up.
    @Test func mixedCaseRevokedEntryIsNotReportedOrphan() {
        let findings = KnownHostsAudit.staticFindings(
            [entry(marker: "@Revoked", fingerprint: "SHA256:abc")],
            knownNames: [])
        #expect(findings.values.contains(.orphan) == false, "a revoked entry needs no config block")
    }
}
