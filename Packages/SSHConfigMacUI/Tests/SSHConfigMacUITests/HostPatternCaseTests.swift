//
//  HostPatternCaseTests.swift
//  sshconfigmanagerTests
//
//  Reproducer: `Host` pattern matching was case-sensitive.
//
//  ssh_config is not. OpenSSH's `match_hostname` lowercases the host and passes
//  `dolower = 1` to `match_pattern_list`, which folds the pattern too — so
//  `Host Prod-DB` applies to `ssh prod-db`, and `Host prod-db` applies to
//  `ssh PROD-DB`. `EffectiveConfigResolver` called `fnmatch(..., 0)` with no
//  case-folding, so a differently-cased alias resolved to *no settings at all*.
//
//  That is not just a cosmetic miss in the effective-config table: the tunnel
//  engine plans its hops through the same resolver, so a `ProxyJump` naming a
//  differently-cased alias produced a hop with `NSUserName()`, port 22 and no
//  identity file instead of the block's real values — a silent wrong-target
//  connection rather than a loud failure. `KnownHostsVerifier` already case-folds
//  at this layer (audit #35); this brings the config resolver in line.
//

import Foundation
import SSHConfigCore
import Testing

private let cfgURL = URL(fileURLWithPath: "/tmp/config")

private func parse(_ text: String) -> SSHConfigDocument {
    SSHConfigParser.parse(text, sourceURL: cfgURL)
}

struct HostPatternCaseTests {
    // MARK: - Pattern matching

    @Test func upperCasePatternMatchesLowerCaseTarget() {
        #expect(EffectiveConfigResolver.matchesHostPatterns(["Prod-DB"], target: "prod-db"))
    }

    @Test func lowerCasePatternMatchesUpperCaseTarget() {
        #expect(EffectiveConfigResolver.matchesHostPatterns(["prod-db"], target: "PROD-DB"))
    }

    @Test func caseInsensitiveWildcardStillMatches() {
        #expect(EffectiveConfigResolver.matchesHostPatterns(["*.CORP.example.com"], target: "db1.corp.example.com"))
    }

    /// A negated pattern must fold too, or `!Bastion` would fail to exclude
    /// `bastion` and the block would apply where ssh says it must not.
    @Test func negatedPatternIsCaseInsensitive() {
        #expect(!EffectiveConfigResolver.matchesHostPatterns(["*", "!Bastion"], target: "bastion"))
    }

    /// Control: a genuine non-match stays a non-match.
    @Test func unrelatedHostStillDoesNotMatch() {
        #expect(!EffectiveConfigResolver.matchesHostPatterns(["prod-db"], target: "staging-db"))
    }

    // MARK: - Effective config

    @Test func settingsResolveForADifferentlyCasedAlias() {
        let document = parse("Host Prod-DB\n    HostName db.internal\n    User deploy\n    Port 2222\n")
        let settings = EffectiveConfigResolver.resolve(target: "prod-db", in: [document])
        #expect(settings.firstValue(of: "hostname") == "db.internal")
        #expect(settings.firstValue(of: "user") == "deploy")
        #expect(settings.firstValue(of: "port") == "2222")
    }

    @Test func matchBlockHostCriterionIsCaseInsensitive() {
        #expect(EffectiveConfigResolver.matchesCriteria(["host", "Prod-DB"], target: "prod-db"))
    }

    // MARK: - The consequence for tunnels

    /// The hop must carry the jump host's real user/port/identity. Resolving
    /// case-sensitively silently produced the defaults instead — a tunnel dialling
    /// the wrong port as the wrong user.
    @Test func jumpChainResolvesADifferentlyCasedAlias() throws {
        let document = parse(
            """
            Host Bastion
                HostName bastion.example.com
                User jump
                Port 2222

            Host target
                HostName 10.0.0.5
                ProxyJump bastion
            """)
        let hops = try TunnelJumpChain.resolve(alias: "target", in: [document])
        #expect(hops.count == 2)
        let bastion = try #require(hops.first)
        #expect(bastion.host == "bastion.example.com")
        #expect(bastion.user == "jump")
        #expect(bastion.port == 2222)
    }
}
