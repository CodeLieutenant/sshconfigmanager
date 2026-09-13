//
//  KnownHostsFieldSeparatorTests.swift
//  sshconfigmanagerTests
//
//  Reproducer: `KnownHostsService.parse` splits fields on `" "` only.
//
//  known_hosts fields are whitespace-delimited — OpenSSH's `load_host_keys` skips
//  over spaces *and* tabs between them — so a tab-separated line is a perfectly
//  valid entry. Splitting on space alone collapses such a line to a single field,
//  `fields.count >= 3` fails, and the entry is dropped silently.
//
//  Dropping it is not benign: the host then looks absent from known_hosts, so
//  `KnownHostsVerifier.decide` returns `.unknown` and the engine trusts-on-first-use
//  a key it should have compared — a changed key stops being detected as a possible
//  MITM. The same parse also backs `isValidLine`, so the Known Hosts audit labels
//  those lines "malformed" and offers to remove them.
//

import Foundation
import SSHConfigCore
import SSHConfigServices
import Testing

struct KnownHostsFieldSeparatorTests {
    /// A real ed25519 host-key blob, so the entry also produces a fingerprint.
    private let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIGNmMDFhMTk0YTJhZWM5ZTYzYzJmYzk4M2M4YWQ4"

    @Test func tabSeparatedEntryIsParsed() {
        let entries = KnownHostsService.parse("example.com\tssh-ed25519\t\(blob)\n")
        #expect(entries.count == 1, "tabs are valid known_hosts field separators")
        #expect(entries.first?.hostsDisplay == "example.com")
        #expect(entries.first?.keyType == "ssh-ed25519")
    }

    /// Control: the space-separated twin parses today.
    @Test func spaceSeparatedEntryIsParsed() {
        let entries = KnownHostsService.parse("example.com ssh-ed25519 \(blob)\n")
        #expect(entries.count == 1)
    }

    @Test func tabSeparatedEntryWithMarkerIsParsed() {
        let entries = KnownHostsService.parse("@revoked\texample.com\tssh-ed25519\t\(blob)\n")
        #expect(entries.count == 1)
        #expect(entries.first?.resolvedMarker == .revoked)
    }

    @Test func mixedSpaceAndTabEntryIsParsed() {
        let entries = KnownHostsService.parse("example.com \tssh-ed25519  \(blob)\ttrailing comment\n")
        #expect(entries.count == 1)
        #expect(entries.first?.keyType == "ssh-ed25519")
    }

    /// A tab-separated line is a valid entry, so the audit must not call it
    /// malformed and offer to delete it.
    @Test func tabSeparatedLineIsValid() {
        #expect(KnownHostsService.isValidLine("example.com\tssh-ed25519\t\(blob)"))
    }

    /// The consequence for trust: a tab-separated record for a host must still be
    /// found, so a *changed* key is reported as a mismatch rather than silently
    /// trusted on first use.
    @Test func tabSeparatedEntryStillDetectsAChangedKey() {
        let entries = KnownHostsService.parse("example.com\tssh-ed25519\t\(blob)\n")
        let decision = KnownHostsVerifier.decide(
            host: "example.com", port: 22,
            fingerprint: "SHA256:someOtherKeyEntirely", entries: entries)
        #expect(decision == .mismatch, "a known host with a different key must not degrade to TOFU")
    }
}
