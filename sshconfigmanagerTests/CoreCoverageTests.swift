//
//  CoreCoverageTests.swift
//  sshconfigmanagerTests
//
//  Fills coverage gaps in the pure SSHConfigCore model/logic that the
//  behavior-focused suites don't exercise: enum/label getters, error
//  descriptions, small model helpers, Equatable, and a few parser/resolver
//  branches. All pure — no I/O, no UI.
//

import Foundation
import SSHConfigCore
import Testing

private let url = URL(fileURLWithPath: "/tmp/config")
private func parse(_ text: String) -> SSHConfigDocument { SSHConfigParser.parse(text, sourceURL: url) }

struct CoreModelCoverageTests {

    @Test func hostTemplatesAreWellFormed() {
        let templates = HostTemplate.all
        #expect(!templates.isEmpty)
        // Touch every stored property + the UUID id (distinct per template).
        #expect(Set(templates.map(\.id)).count == templates.count)
        for t in templates {
            #expect(!t.name.isEmpty)
            #expect(!t.detail.isEmpty)
            #expect(!t.systemImage.isEmpty)
            #expect(!t.alias.isEmpty)
            #expect(!t.directives.isEmpty)
        }
    }

    @Test func configLineIdAndFactories() {
        let blank = ConfigLine.blank("   ")
        let comment = ConfigLine.comment("# hi")
        let directive = ConfigLine.directive(Directive(keyword: "Port", value: "22"))
        // id getter across all three cases.
        #expect(blank.id != comment.id)
        #expect(directive.id == directive.directive?.id)
        #expect(blank.rendered == "   ")
        #expect(comment.rendered == "# hi")
        #expect(comment.directive == nil)
    }

    @Test func directiveSettingValueMarksDirty() {
        let original = Directive(keyword: "User", value: "root")
        let updated = original.settingValue("deploy")
        #expect(updated.value == "deploy")
        #expect(updated.isDirty)
        #expect(updated.rendered.contains("deploy"))
        #expect(original.value == "root") // original untouched
    }

    @Test func hostBlockKindTitlesAndRemoveLine() {
        #expect(HostBlock.Kind.host.emptyTitle == "(unnamed host)")
        #expect(HostBlock.Kind.match.emptyTitle == "Match")
        #expect(HostBlock.Kind.host.noun == "Host")
        #expect(HostBlock.Kind.match.noun == "Match")

        // A header with no patterns falls back to the empty title.
        var block = HostBlock(
            kind: .host, header: Directive(keyword: "Host", value: ""),
            sourceURL: url)
        #expect(block.title == "(unnamed host)")

        let line = ConfigLine.directive(Directive(keyword: "Port", value: "22"))
        block.body = [line]
        block.removeLine(id: line.id)
        #expect(block.body.isEmpty)
    }

    @Test func includeDirectivesFromPreambleAndBlockBody() {
        let document = parse(
            """
            Include conf.d/*.conf

            Host web
                Include extra/web.conf
                HostName w
            """)
        let includes = document.includeDirectives
        #expect(includes.count == 2)
        #expect(includes.contains { $0.value == "conf.d/*.conf" })
        #expect(includes.contains { $0.value == "extra/web.conf" })
    }
}

struct CoreTunnelCoverageTests {

    @Test func tunnelModeIdAndLabel() {
        #expect(TunnelMode.local.id == "local")
        #expect(TunnelMode.local.label.contains("-L"))
        #expect(TunnelMode.remote.label.contains("-R"))
        #expect(TunnelMode.dynamic.label.contains("-D"))
    }

    @Test func tunnelPresetDisplayNameFallbacks() {
        let named = TunnelPreset(name: "  Postgres  ", hostAlias: "bastion")
        #expect(named.displayName == "Postgres") // trimmed name wins

        let unnamed = TunnelPreset(
            name: "", hostAlias: "bastion", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
        #expect(unnamed.displayName.contains("-L")) // falls back to mapping summary

        let bare = TunnelPreset(name: "", hostAlias: "bastion", mappings: [])
        #expect(bare.displayName == "bastion") // falls back to host alias
    }
}

struct CoreErrorAndResolverCoverageTests {

    @Test func tunnelChainErrorDescriptions() {
        #expect(TunnelChainError.proxyCommandUnsupported.errorDescription?.isEmpty == false)
        #expect(TunnelChainError.tooManyHops(10).errorDescription?.contains("10") == true)
    }

    @Test func sshAgentErrorDescriptions() {
        let errors: [SSHAgentError] = [
            .socketUnavailable, .connectionFailed("nope"), .truncated,
            .unexpectedResponse(42), .agentFailure,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(SSHAgentError.connectionFailed("boom").errorDescription?.contains("boom") == true)
        #expect(SSHAgentError.unexpectedResponse(42).errorDescription?.contains("42") == true)
    }

    @Test func parseIdentitiesRejectsFailureAndUnexpected() {
        // type byte 5 == SSH_AGENT_FAILURE.
        #expect(throws: SSHAgentError.self) {
            _ = try SSHAgentProtocol.parseIdentities([5])
        }
        // an unknown type byte.
        #expect(throws: SSHAgentError.self) {
            _ = try SSHAgentProtocol.parseIdentities([99])
        }
    }

    @Test func resolvedSettingEquatable() {
        let config = "Host web\n    HostName w\n    User deploy\n"
        // Two *distinct* arrays with equal contents — comparing an array to itself
        // would hit Array's same-storage fast path and skip ResolvedSetting.==.
        let a = EffectiveConfigResolver.resolve(target: "web", in: [parse(config)])
        let b = EffectiveConfigResolver.resolve(target: "web", in: [parse(config)])
        #expect(a == b) // exercises ResolvedSetting.== (and .id init)
        #expect(a.contains { $0.keyword.lowercased() == "hostname" && $0.value == "w" })
    }

    @Test func jumpChainResolvesProxyJumpWithIdentity() throws {
        let document = parse(
            """
            Host bastion
                HostName bastion.example.com
                IdentityFile ~/.ssh/jump_key

            Host private
                HostName 10.0.0.5
                ProxyJump bastion
                IdentityFile ~/.ssh/priv_key
            """)
        let hops = try TunnelJumpChain.resolve(alias: "private", in: [document])
        #expect(hops.count == 2) // bastion hop, then target
        #expect(hops.first?.host == "bastion.example.com")
        #expect(hops.first?.identityFileName == "jump_key") // covers the identity closure
        #expect(hops.last?.identityFileName == "priv_key")
    }

    @Test func matchesCriteriaCanonicalAndMissingHostToken() {
        // "canonical"/"final" are ignored conditionals → still matches.
        #expect(EffectiveConfigResolver.matchesCriteria(["canonical"], target: "anything"))
        #expect(EffectiveConfigResolver.matchesCriteria(["final", "host", "web"], target: "web"))
        // "host" with no following pattern token → no match.
        #expect(!EffectiveConfigResolver.matchesCriteria(["host"], target: "web"))
        // an unevaluable criterion (user/exec/...) → no match.
        #expect(!EffectiveConfigResolver.matchesCriteria(["user", "admin"], target: "web"))
        #expect(EffectiveConfigResolver.matchesCriteria(["all"], target: "web"))
    }
}

struct CoreParserCoverageTests {

    @Test func parseLineHandlesSeparatorVariants() {
        // `=` separator with no spaces.
        if case .directive(let d) = SSHConfigParser.parseLine("Port=22") {
            #expect(d.keyword == "Port")
            #expect(d.value == "22")
            #expect(d.usesEquals)
        } else {
            Issue.record("expected directive")
        }

        // `=` separator with surrounding spaces.
        if case .directive(let d) = SSHConfigParser.parseLine("Port = 22") {
            #expect(d.value == "22")
            #expect(d.usesEquals)
        } else {
            Issue.record("expected directive")
        }

        // Keyword with no value at all.
        if case .directive(let d) = SSHConfigParser.parseLine("Compression") {
            #expect(d.keyword == "Compression")
            #expect(d.value == "")
        } else {
            Issue.record("expected directive")
        }

        // Trailing whitespace is preserved on the directive.
        if case .directive(let d) = SSHConfigParser.parseLine("User deploy   ") {
            #expect(d.value == "deploy")
            #expect(d.trailingText == "   ")
        } else {
            Issue.record("expected directive")
        }

        // Tab-indented comment + whitespace-only blank line round-trip.
        #expect(SSHConfigParser.parseLine("\t# note").rendered == "\t# note")
        #expect(SSHConfigParser.parseLine("   ").rendered == "   ")

        // Keyword + separator but no value (only trailing whitespace) → empty value.
        if case .directive(let d) = SSHConfigParser.parseLine("Port   ") {
            #expect(d.keyword == "Port")
            #expect(d.value == "")
        } else {
            Issue.record("expected directive")
        }
    }
}

struct CoreLinterAndKeyCoverageTests {

    @Test func severityLabels() {
        #expect(LintFinding.Severity.info.label == "Info")
        #expect(LintFinding.Severity.warning.label == "Warning")
        #expect(LintFinding.Severity.error.label == "Error")
        // symbols too, for good measure
        #expect(!LintFinding.Severity.error.symbol.isEmpty)
    }

    @Test func lintFlagsMissingIdentityFileAndEmptyHostName() {
        let document = parse(
            """
            Host web
                HostName
                IdentityFile ~/.ssh/does_not_exist
            """)
        // existingFiles is non-empty but lacks the key → the "may be missing" info.
        let findings = ConfigLinter.lint([document], existingFiles: ["config", "known_hosts"])
        #expect(findings.contains { $0.title.contains("IdentityFile may be missing") })
        #expect(findings.contains { $0.title.contains("Empty HostName") })
    }

    @Test func publicKeyNameFallsBackToEmptyWhenNoURLs() {
        // Violates the usual invariant on purpose, to cover the `?? ""` fallback.
        let key = SSHPublicKey(
            publicKeyURL: nil, privateKeyURL: nil,
            algorithm: "", fingerprint: "", comment: "")
        #expect(key.name == "")
    }
}
