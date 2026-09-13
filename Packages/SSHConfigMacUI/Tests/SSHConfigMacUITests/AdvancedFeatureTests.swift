//
//  AdvancedFeatureTests.swift
//  sshconfigmanagerTests
//
//  Coverage for the advanced features: effective-config resolver, linter,
//  text diff, fuzzy match, templates, import, connection-target derivation,
//  and the favorites/tags store.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

private let url = URL(fileURLWithPath: "/tmp/config")
private func parse(_ text: String) -> SSHConfigDocument { SSHConfigParser.parse(text, sourceURL: url) }

// MARK: - Effective config resolver

struct EffectiveConfigTests {
    @Test func hostPatternMatching() {
        #expect(EffectiveConfigResolver.matchesHostPatterns(["web"], target: "web"))
        #expect(EffectiveConfigResolver.matchesHostPatterns(["*.example.com"], target: "a.example.com"))
        #expect(!EffectiveConfigResolver.matchesHostPatterns(["*.example.com"], target: "a.example.org"))
        #expect(EffectiveConfigResolver.matchesHostPatterns(["*"], target: "anything"))
        // Negation: matches the wildcard but is excluded by !secret.
        #expect(!EffectiveConfigResolver.matchesHostPatterns(["*", "!secret"], target: "secret"))
        #expect(EffectiveConfigResolver.matchesHostPatterns(["*", "!secret"], target: "public"))
    }

    @Test func negationOnlyHostPatternIsANoOp() {
        // Regression: the old implementation returned true (matched every host) for a
        // pattern list composed entirely of negations. OpenSSH 9.x treats such a Host
        // block as a no-op — no positive pattern means the block never matches any host.
        #expect(!EffectiveConfigResolver.matchesHostPatterns(["!secret"], target: "other"))
        #expect(!EffectiveConfigResolver.matchesHostPatterns(["!secret"], target: "secret"))
        #expect(!EffectiveConfigResolver.matchesHostPatterns(["!a", "!b", "!c"], target: "x"))
    }

    @Test func matchCriteria() {
        #expect(EffectiveConfigResolver.matchesCriteria(["all"], target: "x"))
        #expect(EffectiveConfigResolver.matchesCriteria(["host", "web,db"], target: "db"))
        #expect(!EffectiveConfigResolver.matchesCriteria(["host", "web"], target: "db"))
        #expect(!EffectiveConfigResolver.matchesCriteria(["user", "root"], target: "x")) // unsupported -> skip
    }

    @Test func firstValueWinsAndGlobalHasPriority() {
        let text = """
            ServerAliveInterval 30

            Host web
                HostName web.example.com
                User deploy

            Host *
                User fallback
                Compression yes
            """
        let resolved = EffectiveConfigResolver.resolve(target: "web", in: [parse(text)])
        // User from "Host web" wins over "Host *".
        #expect(resolved.first { $0.keyword == "User" }?.value == "deploy")
        // Global preamble value applies.
        #expect(resolved.contains { $0.keyword == "ServerAliveInterval" && $0.value == "30" })
        // Wildcard-only setting still applies.
        #expect(resolved.contains { $0.keyword == "Compression" && $0.value == "yes" })
        #expect(resolved.contains { $0.keyword == "HostName" && $0.value == "web.example.com" })
    }

    @Test func repeatableKeywordsAccumulate() {
        let text = """
            Host web
                IdentityFile ~/.ssh/a

            Host *
                IdentityFile ~/.ssh/b
            """
        let resolved = EffectiveConfigResolver.resolve(target: "web", in: [parse(text)])
        let identities = resolved.filter { $0.keyword == "IdentityFile" }.map(\.value)
        #expect(identities == ["~/.ssh/a", "~/.ssh/b"])
    }
}

// MARK: - Linter

struct LinterTests {
    @Test func flagsDuplicateAlias() {
        let doc = parse("Host web\n    HostName a\n\nHost web\n    HostName b\n")
        let findings = ConfigLinter.lint([doc])
        #expect(findings.contains { $0.title.contains("Duplicate host alias") })
    }

    @Test func flagsDisabledHostKeyChecking() {
        let doc = parse("Host x\n    StrictHostKeyChecking no\n")
        let findings = ConfigLinter.lint([doc])
        #expect(findings.contains { $0.severity == .warning && $0.title.contains("Host key checking disabled") })
    }

    @Test func flagsWeakCiphers() {
        let doc = parse("Host x\n    Ciphers 3des-cbc,aes256-gcm@openssh.com\n")
        let findings = ConfigLinter.lint([doc])
        #expect(findings.contains { $0.title.contains("Weak algorithm") })
    }

    @Test func flagsDeprecatedKeywordAndBadPort() {
        let doc = parse("Host x\n    Protocol 2\n    Port abc\n")
        let findings = ConfigLinter.lint([doc])
        #expect(findings.contains { $0.title.contains("Deprecated option") })
        #expect(findings.contains { $0.severity == .error && $0.title.contains("Invalid Port") })
    }

    @Test func flagsMissingIdentityFile() {
        let doc = parse("Host x\n    IdentityFile ~/.ssh/nope_missing\n")
        let findings = ConfigLinter.lint([doc], existingFiles: ["id_ed25519", "id_ed25519.pub"])
        #expect(findings.contains { $0.title.contains("IdentityFile may be missing") })
    }

    @Test func cleanConfigHasNoFindings() {
        let doc = parse("Host x\n    HostName x.example.com\n    User me\n    Port 22\n")
        #expect(ConfigLinter.lint([doc], existingFiles: []).isEmpty)
    }

    @Test func flagsWildcardBeforeOtherHosts() {
        // "Host *" here silently wins over "Host web"'s attempt to override User,
        // since ssh keeps the first value it finds for each keyword.
        let doc = parse("Host *\n    User fallback\n\nHost web\n    User deploy\n")
        let findings = ConfigLinter.lint([doc])
        #expect(findings.contains { $0.title == "Host * is not the last block" && $0.fix != nil })
    }

    @Test func wildcardLastRaisesNoFinding() {
        let doc = parse("Host web\n    User deploy\n\nHost *\n    User fallback\n")
        let findings = ConfigLinter.lint([doc])
        #expect(!findings.contains { $0.title == "Host * is not the last block" })
    }

    @Test func wildcardPositionCheckUsesGraphSplicedOrderWhenAvailable() {
        // Without the graph, the flat (documents-array) order would see the include
        // file's "Host web" appended after the main file's trailing "Host *" and
        // wrongly flag it. With the graph, the include splices in at its directive's
        // position — before "Host *" — so the ordering is actually correct.
        let mainURL = URL(fileURLWithPath: "/tmp/config")
        let includedURL = URL(fileURLWithPath: "/tmp/conf.d/web.conf")
        let main = SSHConfigParser.parse("Include conf.d/*\n\nHost *\n    User fallback\n", sourceURL: mainURL)
        let included = SSHConfigParser.parse("Host web\n    User deploy\n", sourceURL: includedURL)
        guard let includeDirective = main.includeDirectives.first else {
            Issue.record("expected an Include directive")
            return
        }
        let graph = ConfigGraph(documents: [main, included], inclusions: [includeDirective.id: [included]])

        let flatFindings = ConfigLinter.lint([main, included])
        #expect(flatFindings.contains { $0.title == "Host * is not the last block" })

        let graphFindings = ConfigLinter.lint([main, included], graph: graph)
        #expect(!graphFindings.contains { $0.title == "Host * is not the last block" })
    }
}

// MARK: - Text diff

struct TextDiffTests {
    @Test func detectsAddedAndRemovedLines() {
        let lines = TextDiff.diff(old: "a\nb\nc", new: "a\nc\nd")
        #expect(lines.contains(TextDiff.Line(kind: .removed, text: "b")))
        #expect(lines.contains(TextDiff.Line(kind: .added, text: "d")))
        #expect(lines.contains(TextDiff.Line(kind: .context, text: "a")))
    }

    @Test func statCountsChanges() {
        let (added, removed) = TextDiff.stat(old: "a\nb", new: "a\nb\nc")
        #expect(added == 1)
        #expect(removed == 0)
    }

    @Test func identicalTextHasNoChanges() {
        let (added, removed) = TextDiff.stat(old: "a\nb\n", new: "a\nb\n")
        #expect(added == 0 && removed == 0)
    }
}

// MARK: - Fuzzy match

struct FuzzyMatchTests {
    @Test func matchesSubsequence() {
        #expect(FuzzyMatch.matches(query: "prd", candidate: "prod-web"))
        #expect(FuzzyMatch.matches(query: "web", candidate: "prod-web"))
        #expect(!FuzzyMatch.matches(query: "xyz", candidate: "prod-web"))
    }

    @Test func emptyQueryMatches() {
        #expect(FuzzyMatch.matches(query: "", candidate: "anything"))
    }

    @Test func contiguousScoresHigher() {
        let contiguous = FuzzyMatch.score(query: "prod", candidate: "prod-web")
        let scattered = FuzzyMatch.score(query: "prod", candidate: "p.r.o.d.x")
        #expect(contiguous != nil && scattered != nil)
        #expect(contiguous! > scattered!)
    }
}

// MARK: - Templates & connection target

struct TemplateAndTargetTests {
    @Test func templatesAreWellFormed() {
        #expect(HostTemplate.all.count >= 4)
        for template in HostTemplate.all {
            #expect(!template.name.isEmpty)
            #expect(!template.alias.isEmpty)
            #expect(!template.directives.isEmpty)
        }
    }

    @Test func connectionTargetPrefersHostNameAndPort() {
        let block = parse("Host web\n    HostName w.example.com\n    Port 2222\n").blocks[0]
        let target = block.connectionTarget
        #expect(target?.host == "w.example.com")
        #expect(target?.port == 2222)
    }

    @Test func connectionTargetFallsBackToAliasAndPort22() {
        let block = parse("Host myhost\n    User me\n").blocks[0]
        let target = block.connectionTarget
        #expect(target?.host == "myhost")
        #expect(target?.port == 22)
    }

    @Test func wildcardOnlyBlockHasNoTarget() {
        let block = parse("Host *\n    User me\n").blocks[0]
        #expect(block.connectionTarget == nil)
    }
}

// MARK: - Store: templates, import, favorites, tags

@MainActor
struct MetadataAndImportTests {
    private func freshStore() -> ConfigStore {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings)
        store.loadForTesting([parse("Host alpha\n    HostName a\n")])
        return store
    }

    @Test func addHostFromTemplatePrefillsDirectives() {
        let store = freshStore()
        let template = HostTemplate.all.first { $0.name == "Git Host" }!
        let id = store.addHost(template: template)
        let block = store.block(id: id!)
        #expect(block?.firstValue(for: "User") == "git")
        #expect(block?.firstValue(for: "IdentitiesOnly") == "yes")
    }

    @Test func importHostsAppendsParsedBlocks() {
        let store = freshStore()
        let count = store.importHosts(fromText: "Host beta\n    HostName b\n\nHost gamma\n    HostName c\n")
        #expect(count == 2)
        let titles = store.documents[0].blocks.map { $0.patterns.joined() }
        #expect(titles == ["alpha", "beta", "gamma"])
    }

    @Test func importIgnoresTextWithoutBlocks() {
        let store = freshStore()
        #expect(store.importHosts(fromText: "just a comment\n# nothing\n") == 0)
    }

    @Test func favoritesPersistAcrossStores() async throws {
        let database = AppDatabase.testDatabase(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("favorites-\(UUID().uuidString).store"))
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings, passphraseStore: KeychainPassphraseStore(), database: database)
        await store.waitForGroupsLoadedForTesting()
        store.loadForTesting([parse("Host alpha\n    HostName a\n")])
        let alpha = store.documents[0].blocks[0]
        #expect(!store.isFavorite(alpha))
        store.toggleFavorite(alpha)
        #expect(store.isFavorite(alpha))

        var stored = AppDatabase.HostMetadata()
        for _ in 0..<50 where stored.favoriteAliases.isEmpty {
            stored = try await database.loadHostMetadata()
            if stored.favoriteAliases.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }

        let reopened = ConfigStore(settings: settings, passphraseStore: KeychainPassphraseStore(), database: database)
        await reopened.waitForGroupsLoadedForTesting()
        reopened.loadForTesting([parse("Host alpha\n")])
        #expect(reopened.isFavorite(reopened.documents[0].blocks[0]))
    }

    @Test func tagsSetGetAndFilter() {
        let store = freshStore()
        let alpha = store.documents[0].blocks[0]
        store.setTags(["work", "prod"], for: alpha)
        #expect(store.tags(for: alpha) == ["work", "prod"])
        #expect(store.allTags == ["prod", "work"])

        store.importHosts(fromText: "Host beta\n    HostName b\n")
        store.tagFilter = "work"
        let visible = store.filteredGroups.flatMap { $0.blocks }.map { $0.title }
        #expect(visible == ["alpha"]) // only the work-tagged host shows
    }
}
