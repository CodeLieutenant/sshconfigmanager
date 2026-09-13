//
//  PathValueQuotingTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for the reported bug: a `.path` directive whose value
//  contains spaces is written double-quoted in ssh_config (so it stays one
//  token) — e.g. a 1Password agent socket:
//
//      IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
//
//  In the app the value must appear *unquoted*, resolve/expand correctly (for the
//  sandbox-grant prompt), and be *re-quoted* on write so the file stays valid.
//  The stored directive value stays byte-exact for lossless round-tripping.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

private let cfgURL = URL(fileURLWithPath: "/tmp/config")

private func parse(_ text: String) -> SSHConfigDocument {
    SSHConfigParser.parse(text, sourceURL: cfgURL)
}

struct PathValueQuotingTests {
    private let quotedSocket =
        "\"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\""
    private let bareSocket =
        "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    // MARK: - SSHValueQuoting primitive

    @Test func unquotedStripsOneSurroundingPair() {
        #expect(SSHValueQuoting.unquoted(quotedSocket) == bareSocket)
        #expect(SSHValueQuoting.unquoted("/tmp/plain.sock") == "/tmp/plain.sock")
    }

    @Test func unquotedLeavesInteriorOrPartialQuotesAlone() {
        // Not fully wrapped → untouched (would otherwise mangle the value).
        #expect(SSHValueQuoting.unquoted("nc -x \"proxy host\":8080") == "nc -x \"proxy host\":8080")
        #expect(SSHValueQuoting.unquoted("\"a\" \"b\"") == "\"a\" \"b\"")
        #expect(SSHValueQuoting.unquoted("\"") == "\"")
    }

    @Test func quotedIfNeededWrapsOnlyWhenSpacePresent() {
        #expect(SSHValueQuoting.quotedIfNeeded(bareSocket) == quotedSocket)
        #expect(SSHValueQuoting.quotedIfNeeded("~/.ssh/id_ed25519") == "~/.ssh/id_ed25519")
        // Already quoted → left as-is (no double wrapping).
        #expect(SSHValueQuoting.quotedIfNeeded(quotedSocket) == quotedSocket)
    }

    // MARK: - HostBlock: read unquoted, write re-quoted

    @Test func firstValueUnquotesPathDirective() {
        let block = parse("Host w\n    IdentityAgent \(quotedSocket)\n").blocks.first!
        #expect(block.firstValue(for: "IdentityAgent") == bareSocket)
    }

    @Test func nonPathDirectiveKeepsItsSpacesAndQuotesVerbatim() {
        // ProxyCommand is a command line (.string), not a path: its spaces are real
        // and it must never be unquoted.
        let block = parse("Host w\n    ProxyCommand ssh -W %h:%p bastion\n").blocks.first!
        #expect(block.firstValue(for: "ProxyCommand") == "ssh -W %h:%p bastion")
    }

    @Test func setValueRequotesSpaceBearingPath() {
        var block = parse("Host w\n").blocks.first!
        block.setValue(bareSocket, for: "IdentityAgent")
        // Round-trips back to the bare value for display…
        #expect(block.firstValue(for: "IdentityAgent") == bareSocket)
        // …but serializes quoted so the file stays valid ssh_config.
        let line = SSHConfigSerializer.serialize(
            SSHConfigDocument(sourceURL: cfgURL, blocks: [block]))
        #expect(line.contains("IdentityAgent \(quotedSocket)"))
    }

    @Test func setValueLeavesWhitespaceFreePathUnquoted() {
        var block = parse("Host w\n").blocks.first!
        block.setValue("~/.ssh/id_ed25519", for: "IdentityAgent")
        let out = SSHConfigSerializer.serialize(
            SSHConfigDocument(sourceURL: cfgURL, blocks: [block]))
        #expect(out.contains("IdentityAgent ~/.ssh/id_ed25519"))
        #expect(!out.contains("\""))
    }

    // MARK: - Lossless round-trip of an untouched quoted value

    @Test func untouchedQuotedValueSerializesByteExact() {
        let text = "Host w\n    IdentityAgent \(quotedSocket)\n"
        let doc = parse(text)
        #expect(SSHConfigSerializer.serialize(doc) == text)
    }

    // MARK: - Resolver hands the tunnel engine a bare path

    @Test func resolvedPathValueIsUnquoted() {
        let doc = parse("Host w\n    HostName h.example.com\n    IdentityAgent \(quotedSocket)\n")
        let resolved = EffectiveConfigResolver.resolve(target: "w", in: [doc])
        #expect(resolved.firstValue(of: "identityagent") == bareSocket)
    }
}
