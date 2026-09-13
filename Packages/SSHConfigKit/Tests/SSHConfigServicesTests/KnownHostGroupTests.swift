//
//  KnownHostGroupTests.swift
//  sshconfigmanagerTests
//
//  The Known Hosts grouping model: how flat known_hosts entries fold into per-host
//  groups, and how hosts vs IPs vs hashed entries are classified. Probe-outcome
//  classification is covered by VerifyOutcomeTests, which needs the tunnel engine.
//

import Foundation
import SSHConfigCore
import SSHConfigServices
import Testing

struct KnownHostGroupTests {
    private func entry(
        _ lineIndex: Int, hosts: String, keyType: String = "ssh-ed25519",
        fingerprint: String?, hashed: Bool = false, marker: String? = nil
    ) -> KnownHostEntry {
        KnownHostEntry(
            id: UUID(), lineIndex: lineIndex, raw: "", marker: marker,
            hostsDisplay: hashed ? "(hashed)" : hosts,
            isHashed: hashed, keyType: keyType, fingerprint: fingerprint)
    }

    @Test func mergesKeysOfTheSameHostField() {
        let entries = [
            entry(0, hosts: "github.com", keyType: "ssh-ed25519", fingerprint: "SHA256:aaa"),
            entry(1, hosts: "github.com", keyType: "ssh-rsa", fingerprint: "SHA256:bbb"),
        ]
        let groups = KnownHostGroup.build(from: entries)
        #expect(groups.count == 1)
        #expect(groups[0].title == "github.com")
        #expect(groups[0].entries.count == 2)
        #expect(groups[0].kind == .hostname)
        #expect(groups[0].connectHost == "github.com")
        #expect(groups[0].connectPort == 22)
    }

    @Test func classifiesIPv4AndIPv6Literals() {
        let groups = KnownHostGroup.build(from: [
            entry(0, hosts: "192.168.1.10", fingerprint: "SHA256:a"),
            entry(1, hosts: "example.com", fingerprint: "SHA256:b"),
            entry(2, hosts: "[2001:db8::1]:2222", fingerprint: "SHA256:c"),
        ])
        let byTitle = Dictionary(uniqueKeysWithValues: groups.map { ($0.title, $0) })
        #expect(byTitle["192.168.1.10"]?.kind == .ipAddress)
        #expect(byTitle["example.com"]?.kind == .hostname)
        // Bracketed host:port → IP-literal kind, host + port parsed for probing.
        #expect(byTitle["[2001:db8::1]:2222"]?.kind == .ipAddress)
        #expect(byTitle["[2001:db8::1]:2222"]?.connectHost == "2001:db8::1")
        #expect(byTitle["[2001:db8::1]:2222"]?.connectPort == 2222)
    }

    @Test func collapsesHashedEntriesIntoOneUnverifiableGroup() {
        let groups = KnownHostGroup.build(from: [
            entry(0, hosts: "", fingerprint: "SHA256:a", hashed: true),
            entry(1, hosts: "", fingerprint: "SHA256:b", hashed: true),
            entry(2, hosts: "example.com", fingerprint: "SHA256:c"),
        ])
        let hashed = groups.first { $0.kind == .hashed }
        #expect(hashed != nil)
        #expect(hashed?.entries.count == 2)
        #expect(hashed?.connectHost == nil) // can't probe a hashed host
    }

    @Test func splitsAliasesAndBuildsHostToken() {
        let groups = KnownHostGroup.build(from: [
            entry(0, hosts: "github.com,140.82.112.3", fingerprint: "SHA256:a")
        ])
        #expect(groups[0].title == "github.com")
        #expect(groups[0].aliases == ["140.82.112.3"])
        #expect(groups[0].hostToken == "github.com,140.82.112.3")
    }

    @Test func searchMatchesNameAliasAndFingerprint() {
        let groups = KnownHostGroup.build(from: [
            entry(0, hosts: "prod-web,10.0.0.4", keyType: "ssh-ed25519", fingerprint: "SHA256:Zxywv")
        ])
        let g = groups[0]
        #expect(g.matches("prod")) // name
        #expect(g.matches("10.0.0")) // alias
        #expect(g.matches("ed25519")) // key type
        #expect(g.matches("zxywv")) // fingerprint (case-insensitive)
        #expect(!g.matches("nope"))
    }

    // MARK: - Config cross-reference

    @Test func crossReferencesIPWithConfigAlias() {
        let groups = KnownHostGroup.build(
            from: [entry(0, hosts: "203.0.113.25", fingerprint: "SHA256:a")],
            configAliasesByHost: ["203.0.113.25": ["monitoring"]])
        let g = groups[0]
        #expect(g.title == "203.0.113.25")
        #expect(g.configAliases == ["monitoring"])
        #expect(g.displayName == "monitoring")
        #expect(g.rowDetail.contains("203.0.113.25"))
        #expect(g.matches("monitor"))
    }

    @Test func dropsConfigAliasThatRepeatsTheHostName() {
        // A Host whose alias *is* the known_hosts name shouldn't show a redundant chip.
        let groups = KnownHostGroup.build(
            from: [entry(0, hosts: "github.com", fingerprint: "SHA256:a")],
            configAliasesByHost: ["github.com": ["github.com"]])
        #expect(groups[0].configAliases.isEmpty)
        #expect(groups[0].displayName == "github.com")
    }

    @Test func crossReferenceMatchesViaConnectHostForBracketedPort() {
        let groups = KnownHostGroup.build(
            from: [entry(0, hosts: "[10.0.0.9]:2222", fingerprint: "SHA256:a")],
            configAliasesByHost: ["10.0.0.9": ["db-tunnel"]])
        #expect(groups[0].configAliases == ["db-tunnel"])
        #expect(groups[0].connectHost == "10.0.0.9")
    }

}
