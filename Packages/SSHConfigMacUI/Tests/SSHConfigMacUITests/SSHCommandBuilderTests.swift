//
//  SSHCommandBuilderTests.swift
//  sshconfigmanagerTests
//
//  The Connect & Launch builder is pure, so its correctness contract lives here:
//  alias vs explicit command shapes, the keyword→flag mapping, the `sftp://` URL,
//  and — most importantly — shell quoting as a security surface. Tests drive the
//  real `EffectiveConfigResolver` so the builder is exercised end-to-end from a
//  parsed config, not hand-built setting lists.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

private let cfgURL = URL(fileURLWithPath: "/tmp/config")

private func resolve(_ text: String, target: String) -> [ResolvedSetting] {
    let document = SSHConfigParser.parse(text, sourceURL: cfgURL)
    return EffectiveConfigResolver.resolve(target: target, in: [document])
}

private func firstHostBlock(_ text: String) -> HostBlock {
    SSHConfigParser.parse(text, sourceURL: cfgURL).blocks.first { $0.kind == .host }!
}

// MARK: - Alias mode

@MainActor
struct SSHCommandBuilderAliasTests {
    /// Alias mode names the config alias and nothing else, so real ssh re-reads it.
    @Test func aliasUsesFirstConcretePattern() {
        let block = firstHostBlock("Host bastion\n    HostName 10.0.0.5\n    Port 2222\n")
        let command = SSHCommandBuilder.aliasCommand(for: block)
        #expect(command.argv == ["ssh", "bastion"])
        #expect(command.shellString == "ssh bastion")
    }

    /// Caller-forced extras land between the verb and the destination.
    @Test func aliasAppendsExtraOptions() {
        let block = firstHostBlock("Host web\n")
        let command = SSHCommandBuilder.aliasCommand(for: block, extraOptions: ["-v"])
        #expect(command.argv == ["ssh", "-v", "web"])
    }

    /// A wildcard pattern is skipped; the block's own HostName is the fallback.
    @Test func aliasFallsBackToHostNameForWildcardBlock() {
        let block = firstHostBlock("Host *.internal\n    HostName jump.example.com\n")
        let command = SSHCommandBuilder.aliasCommand(for: block)
        #expect(command.argv == ["ssh", "jump.example.com"])
    }

    /// No concrete alias and no HostName → just `ssh` (callers disable the action).
    @Test func aliasWithNoDestinationIsBareSsh() {
        let block = firstHostBlock("Host *\n    User deploy\n")
        let command = SSHCommandBuilder.aliasCommand(for: block)
        #expect(command.argv == ["ssh"])
    }
}

// MARK: - Explicit mode

@MainActor
struct SSHCommandBuilderExplicitTests {
    /// The headline example: identity, port, jump, and user@host all flattened.
    @Test func explicitFlattensTheCoreFlags() {
        let resolved = resolve(
            """
            Host server
                HostName 10.0.0.5
                User deploy
                Port 2222
                IdentityFile ~/.ssh/id_ed25519
                ProxyJump jump.example.com
            """, target: "server")
        let command = SSHCommandBuilder.explicitCommand(target: "server", resolved: resolved)
        #expect(
            command.argv == [
                "ssh", "-p", "2222", "-i", "~/.ssh/id_ed25519",
                "-J", "jump.example.com", "deploy@10.0.0.5",
            ])
    }

    /// HostName falls back to the alias, and the default port 22 is omitted.
    @Test func explicitOmitsDefaultPortAndFallsBackToAlias() {
        let resolved = resolve("Host box\n    User root\n    Port 22\n", target: "box")
        let command = SSHCommandBuilder.explicitCommand(target: "box", resolved: resolved)
        #expect(command.argv == ["ssh", "root@box"])
    }

    /// Repeatable IdentityFile emits one `-i` per file, in order.
    @Test func explicitRepeatsIdentityFiles() {
        let resolved = resolve(
            "Host box\n    HostName h\n    IdentityFile ~/.ssh/a\n    IdentityFile ~/.ssh/b\n",
            target: "box")
        let command = SSHCommandBuilder.explicitCommand(target: "box", resolved: resolved)
        #expect(command.argv == ["ssh", "-i", "~/.ssh/a", "-i", "~/.ssh/b", "h"])
    }

    /// Unmapped keywords fall through to the generic `-o Keyword=value` form,
    /// preserving the canonical spelling and the resolver's order.
    @Test func explicitUsesGenericDashOForOtherKeywords() {
        let resolved = resolve(
            "Host box\n    HostName h\n    Compression yes\n    ServerAliveInterval 30\n",
            target: "box")
        let command = SSHCommandBuilder.explicitCommand(target: "box", resolved: resolved)
        #expect(
            command.argv == [
                "ssh", "-o", "Compression=yes", "-o", "ServerAliveInterval=30", "h",
            ])
    }

    /// No User → destination is the bare host with no `@` prefix.
    @Test func explicitWithoutUserHasNoAtPrefix() {
        let resolved = resolve("Host box\n    HostName 192.168.1.10\n", target: "box")
        let command = SSHCommandBuilder.explicitCommand(target: "box", resolved: resolved)
        #expect(command.argv == ["ssh", "192.168.1.10"])
    }
}

// MARK: - Deploy (ssh-copy-id)

@MainActor
struct SSHCommandBuilderDeployTests {
    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 me@laptop"

    /// Alias mode: `ssh <alias> '<remote one-liner>'`. The key rides as a single
    /// remote-side token; the destination is the concrete alias.
    @Test func deployUsesAliasAndIdempotentRemoteLine() {
        let block = firstHostBlock("Host web-prod\n    HostName 10.0.0.5\n    User deploy\n")
        let command = SSHCommandBuilder.deployCommand(for: block, publicKeyLine: key)
        let remote =
            "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && "
            + "grep -qxF '\(key)' ~/.ssh/authorized_keys "
            + "|| echo '\(key)' >> ~/.ssh/authorized_keys"
        #expect(command?.argv == ["ssh", "web-prod", remote])
    }

    /// The whole remote command is single-quoted for the local shell, so the inner
    /// remote-side quotes around the key splice out as `'\''` — valid on both hops.
    @Test func deployDoubleQuotesForBothShells() {
        let block = firstHostBlock("Host box\n")
        let command = SSHCommandBuilder.deployCommand(for: block, publicKeyLine: key)
        #expect(
            command?.shellString
                == #"ssh box 'umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '\''"# + key
                + #"'\'' ~/.ssh/authorized_keys || echo '\''"# + key + #"'\'' >> ~/.ssh/authorized_keys'"#)
    }

    /// A wildcard-only block has no concrete alias, so its HostName is the target.
    @Test func deployFallsBackToHostNameForWildcardBlock() {
        let block = firstHostBlock("Host *.internal\n    HostName jump.example.com\n")
        let command = SSHCommandBuilder.deployCommand(for: block, publicKeyLine: key)
        #expect(command?.argv.first == "ssh")
        #expect(command?.argv[1] == "jump.example.com")
    }

    /// No concrete alias and no HostName → nil (the UI disables deploy for it).
    @Test func deployReturnsNilWithoutDestination() {
        let block = firstHostBlock("Host *\n    User deploy\n")
        #expect(SSHCommandBuilder.deployCommand(for: block, publicKeyLine: key) == nil)
    }

    /// A blank key line is rejected — nothing to deploy.
    @Test func deployReturnsNilForBlankKey() {
        let block = firstHostBlock("Host box\n    HostName h\n")
        #expect(SSHCommandBuilder.deployCommand(for: block, publicKeyLine: "   \n") == nil)
    }

    /// A single quote inside the key comment must survive the remote single-quote
    /// context (spliced as `'\''`) so the remote shell parses one intact token.
    @Test func deployEscapesQuoteInKeyComment() {
        let block = firstHostBlock("Host box\n    HostName h\n")
        let quirky = "ssh-ed25519 AAAAC3 it's-me@host"
        let command = SSHCommandBuilder.deployCommand(for: block, publicKeyLine: quirky)
        // Remote-side quoting wraps the key and splices the apostrophe.
        #expect(command?.argv[2].contains(#"it'\''s-me@host"#) == true)
    }
}

// MARK: - Shell quoting (the security surface)

@MainActor
struct SSHCommandBuilderQuotingTests {
    /// Inert characters pass through bare so common commands stay readable.
    @Test func bareWhenSafe() {
        #expect(SSHCommandBuilder.shellQuote("deploy@10.0.0.5") == "deploy@10.0.0.5")
        #expect(SSHCommandBuilder.shellQuote("~/.ssh/id_ed25519") == "~/.ssh/id_ed25519")
        #expect(SSHCommandBuilder.shellQuote("-p") == "-p")
    }

    @Test func emptyArgumentBecomesQuotes() {
        #expect(SSHCommandBuilder.shellQuote("") == "''")
    }

    @Test func spacesAndQuotesAreWrapped() {
        #expect(SSHCommandBuilder.shellQuote("a b") == "'a b'")
        #expect(SSHCommandBuilder.shellQuote("it's") == #"'it'\''s'"#)
    }

    /// A malicious ProxyCommand must come out inert — the whole `; rm -rf ~`
    /// payload wrapped in one single-quoted token, so a shell sees it as a single
    /// `-o` argument and never as separate commands. This is why quoting lives here.
    @Test func maliciousProxyCommandIsInert() {
        let resolved = resolve(
            "Host evil\n    HostName h\n    ProxyCommand sh -c \"; rm -rf ~\"\n", target: "evil")
        let command = SSHCommandBuilder.explicitCommand(target: "evil", resolved: resolved)
        // The payload rides in a single argv element (one `-o ProxyCommand=…`).
        #expect(
            command.argv == [
                "ssh", "-o", #"ProxyCommand=sh -c "; rm -rf ~""#, "h",
            ])
        // And renders as one single-quoted token — the `;` is inside the quotes.
        #expect(command.shellString == #"ssh -o 'ProxyCommand=sh -c "; rm -rf ~"' h"#)
    }
}
