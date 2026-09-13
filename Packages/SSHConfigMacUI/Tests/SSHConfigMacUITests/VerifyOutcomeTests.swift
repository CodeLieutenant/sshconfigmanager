//
//  VerifyOutcomeTests.swift
//  SSHConfigMacUITests
//
//  How a live host-key probe is classified against the keys already in known_hosts.
//  Split out of KnownHostGroupTests when the grouping model moved to
//  SSHConfigServices: this half still needs the tunnel engine's probe type.
//

import Foundation
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

struct VerifyOutcomeTests {
    private func entry(
        _ lineIndex: Int, hosts: String, keyType: String = "ssh-ed25519",
        fingerprint: String?, hashed: Bool = false, marker: String? = nil
    ) -> KnownHostEntry {
        KnownHostEntry(
            id: UUID(), lineIndex: lineIndex, raw: "", marker: marker,
            hostsDisplay: hashed ? "(hashed)" : hosts,
            isHashed: hashed, keyType: keyType, fingerprint: fingerprint)
    }

    private func probe(_ fingerprint: String, _ keyType: String = "ssh-ed25519") -> HostKeyScanner.Probe {
        HostKeyScanner.Probe(keyType: keyType, fingerprint: fingerprint, openSSH: "")
    }

    @Test func verifiedWhenLiveKeyMatchesStored() {
        let group = KnownHostGroup.build(from: [entry(0, hosts: "h", fingerprint: "SHA256:match")])[0]
        #expect(VerifyOutcome(probe: probe("SHA256:match"), group: group) == .verified(probe("SHA256:match")))
    }

    @Test func changedWhenSameTypeDiffersFromStored() {
        let group = KnownHostGroup.build(from: [entry(0, hosts: "h", fingerprint: "SHA256:old")])[0]
        let p = probe("SHA256:new")
        #expect(VerifyOutcome(probe: p, group: group) == .changed(p))
    }

    @Test func notStoredWhenKeyTypeIsNew() {
        let group = KnownHostGroup.build(from: [entry(0, hosts: "h", fingerprint: "SHA256:ed")])[0]
        let p = probe("SHA256:rsa", "ssh-rsa")
        #expect(VerifyOutcome(probe: p, group: group) == .notStored(p))
    }
}
