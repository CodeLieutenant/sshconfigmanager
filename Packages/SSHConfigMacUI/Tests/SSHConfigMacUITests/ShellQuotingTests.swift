//
//  ShellQuotingTests.swift
//  sshconfigmanagerTests
//
//  Covers the centralized shell quoter both call-site families delegate to.
//

import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct ShellQuotingTests {
    // MARK: - argument(_:)

    @Test func argumentLeavesInertTokensBare() {
        #expect(ShellQuoting.argument("deploy@10.0.0.5") == "deploy@10.0.0.5")
        #expect(ShellQuoting.argument("~/.ssh/id_ed25519") == "~/.ssh/id_ed25519")
        #expect(ShellQuoting.argument("-p") == "-p")
        #expect(ShellQuoting.argument("Port=22") == "Port=22")
    }

    @Test func argumentQuotesEmptyAndWhitespace() {
        #expect(ShellQuoting.argument("") == "''")
        #expect(ShellQuoting.argument("a b") == "'a b'")
    }

    @Test func argumentNeutralizesMetacharacters() {
        // The security surface: shell metacharacters must come out inert.
        #expect(ShellQuoting.argument("a;rm -rf b") == "'a;rm -rf b'")
        #expect(ShellQuoting.argument("$(whoami)") == "'$(whoami)'")
        #expect(ShellQuoting.argument("a`b`") == "'a`b`'")
    }

    @Test func argumentSplicesEmbeddedSingleQuote() {
        #expect(ShellQuoting.argument("it's") == #"'it'\''s'"#)
    }

    // MARK: - homePath(_:)

    @Test func homePathKeepsLeadingTildeOutsideQuotes() {
        #expect(ShellQuoting.homePath("~") == "~")
        #expect(ShellQuoting.homePath("~/.ssh/id key") == "~/'.ssh/id key'")
        #expect(ShellQuoting.homePath("/abs/path with space") == "'/abs/path with space'")
    }

    @Test func homePathSplicesEmbeddedSingleQuote() {
        #expect(ShellQuoting.homePath("a'b") == "'a'\\''b'")
    }

    // MARK: - the thin wrappers stay behavior-compatible

    @Test func wrappersDelegateToTheCanonicalQuoter() {
        #expect(SSHCommandBuilder.shellQuote("a b") == ShellQuoting.argument("a b"))
        #expect(TunnelCommandBuilder.shellQuoted("a;b") == ShellQuoting.argument("a;b"))
        #expect(SSHAgentService.shellQuote("~/.ssh/id key") == ShellQuoting.homePath("~/.ssh/id key"))
    }
}
