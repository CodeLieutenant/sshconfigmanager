//
//  FeatureTests.swift
//  sshconfigmanagerTests
//
//  Coverage for the newer features: host ordering, drag-reorder, duplicate,
//  the expanded keyword registry + categorization, identity-key helpers, and
//  the menu-bar / autosave-toggle store logic.
//

import AppKit
import Foundation
import SSHConfigCore
import SwiftUI
import Testing

@testable import SSHConfigMacUI

private let cfgURL = URL(fileURLWithPath: "/tmp/config")

private func parse(_ text: String) -> SSHConfigDocument {
    SSHConfigParser.parse(text, sourceURL: cfgURL)
}

private func orderOf(_ document: SSHConfigDocument) -> [String] {
    document.blocks.map { $0.patterns.joined(separator: " ") }
}

private let threeHosts =
    [
        "Host alpha",
        "    HostName a.example.com",
        "",
        "Host beta",
        "    HostName b.example.com",
        "",
        "Host gamma",
        "    HostName c.example.com",
    ].joined(separator: "\n") + "\n"

// MARK: - Ordering is preserved (the core requirement)

struct OrderingTests {
    @Test func parsePreservesFileOrder() {
        #expect(orderOf(parse(threeHosts)) == ["alpha", "beta", "gamma"])
    }

    @Test func roundTripPreservesOrderAndBytes() {
        let document = parse(threeHosts)
        let output = SSHConfigSerializer.serialize(document)
        #expect(output == threeHosts) // byte-identical
        #expect(orderOf(parse(output)) == ["alpha", "beta", "gamma"])
    }

    @Test func reorderingThenReparsingKeepsNewOrder() {
        var document = parse(threeHosts)
        // Move gamma (index 2) to the front.
        document.blocks.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let output = SSHConfigSerializer.serialize(document)
        let reparsed = parse(output)
        #expect(orderOf(reparsed) == ["gamma", "alpha", "beta"])
        // Each moved block keeps its own directives.
        #expect(reparsed.blocks[0].firstValue(for: "HostName") == "c.example.com")
    }

    @Test func wildcardBlockCanBeReorderedAndKept() {
        let text = "Host *\n    Compression yes\n\nHost web\n    HostName w.example.com\n"
        var document = parse(text)
        document.blocks.move(fromOffsets: IndexSet(integer: 1), toOffset: 0) // web before *
        let reparsed = parse(SSHConfigSerializer.serialize(document))
        #expect(orderOf(reparsed) == ["web", "*"])
    }
}

// MARK: - Store: reorder / duplicate / add / delete (ordering kept end-to-end)

@MainActor
struct ConfigStoreEditingTests {
    /// A private settings instance (no database) so flipping autosave drives the
    /// real source of truth without touching `AppSettings.shared` — that global is
    /// loaded asynchronously and mutated by other suites, so sharing it races.
    private let settings = AppSettings(database: nil)

    private func makeStore(_ text: String = threeHosts) -> ConfigStore {
        settings.autosaveEnabled = false // no background writes
        let store = ConfigStore(settings: settings)
        store.loadForTesting([parse(text)])
        return store
    }

    @Test func moveBlocksReordersAndMarksDirty() {
        let store = makeStore()
        store.moveBlocks(in: cfgURL, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(orderOf(store.documents[0]) == ["gamma", "alpha", "beta"])
        #expect(store.isDirty)
        // Serializing reflects the new order, and re-parsing keeps it.
        let reparsed = parse(SSHConfigSerializer.serialize(store.documents[0]))
        #expect(orderOf(reparsed) == ["gamma", "alpha", "beta"])
    }

    @Test func duplicateInsertsCopyAfterOriginalWithSameBody() {
        let store = makeStore()
        let beta = store.documents[0].blocks[1]
        let newID = store.duplicateBlock(id: beta.id)
        let blocks = store.documents[0].blocks
        #expect(orderOf(store.documents[0]) == ["alpha", "beta", "beta-copy", "gamma"])
        let copy = blocks[2]
        #expect(copy.id == newID)
        #expect(copy.id != beta.id)
        #expect(copy.firstValue(for: "HostName") == "b.example.com")
        #expect(store.selectedBlockID == newID)
    }

    /// A numbered alias increments rather than gaining a `-copy` suffix.
    @Test func duplicateIncrementsNumberedAlias() {
        let store = makeStore("Host web-2\n    HostName w.example.com\n")
        let id = store.documents[0].blocks[0].id
        store.duplicateBlock(id: id)
        #expect(orderOf(store.documents[0]) == ["web-2", "web-3"])
    }

    /// A second duplicate of the same source avoids the first clone's name (each is
    /// inserted directly below the source, so the newest lands nearest to it).
    @Test func duplicateTwiceAvoidsCollision() {
        let store = makeStore("Host web\n    HostName w.example.com\n")
        let id = store.documents[0].blocks[0].id
        store.duplicateBlock(id: id)
        store.duplicateBlock(id: id)
        #expect(Set(orderOf(store.documents[0])) == ["web", "web-copy", "web-copy-2"])
    }

    /// The clone preserves the label comment and renders its body byte-for-byte like
    /// the source did *before* duplication (the source gains only a trailing blank
    /// separator), and only the header alias is renamed.
    @Test func duplicatePreservesLeadingCommentAndBody() {
        let text =
            "Host other\n    HostName x\n\n# Production web tier\nHost web\n"
            + "    HostName 10.0.0.5\n    Port 22\n"
        let store = makeStore(text)
        let web = store.documents[0].blocks[1]
        let originalBody = web.body.map(\.rendered)
        let newID = store.duplicateBlock(id: web.id)!
        let clone = store.documents[0].blocks.first { $0.id == newID }!

        #expect(clone.leading.contains { $0.rendered == "# Production web tier" })
        #expect(clone.body.map(\.rendered) == originalBody)
        #expect(clone.patterns == ["web-copy"])
    }

    /// A multi-pattern header renames only its first concrete alias.
    @Test func duplicateMultiPatternRenamesOnlyFirstAlias() {
        let store = makeStore("Host web web.internal\n    HostName 10.0.0.5\n")
        let id = store.documents[0].blocks[0].id
        let newID = store.duplicateBlock(id: id)!
        let clone = store.documents[0].blocks.first { $0.id == newID }!
        #expect(clone.patterns == ["web-copy", "web.internal"])
    }

    /// A `Match` block has no alias, so it clones verbatim.
    @Test func duplicateMatchBlockClonesCriteriaUnchanged() {
        let store = makeStore("Match host *.internal user admin\n    ForwardAgent yes\n")
        let id = store.documents[0].blocks[0].id
        let newID = store.duplicateBlock(id: id)!
        let clone = store.documents[0].blocks.first { $0.id == newID }!
        #expect(clone.kind == .match)
        #expect(clone.header.value == "host *.internal user admin")
    }

    /// Duplicating then editing the clone leaves the source's directives intact —
    /// proof that fresh line ids decoupled the two blocks.
    @Test func editingDuplicateLeavesSourceUnchanged() {
        let store = makeStore()
        let beta = store.documents[0].blocks[1]
        let newID = store.duplicateBlock(id: beta.id)!
        store.updateBlock(id: newID) { $0.setValue("changed.example.com", for: "HostName") }
        let source = store.documents[0].blocks.first { $0.id == beta.id }!
        #expect(source.firstValue(for: "HostName") == "b.example.com")
    }

    @Test func addHostAppendsUniqueNameAndSelects() {
        let store = makeStore("")
        let id = store.addHost()
        #expect(store.documents[0].blocks.count == 1)
        #expect(store.documents[0].blocks[0].patterns == ["new-host1"])
        #expect(store.selectedBlockID == id)
    }

    @Test func deleteKeepsOrderOfRemaining() {
        let store = makeStore()
        let beta = store.documents[0].blocks[1]
        store.deleteBlock(id: beta.id)
        #expect(orderOf(store.documents[0]) == ["alpha", "gamma"])
    }

    @Test func saveStatusTracksAutosaveSetting() {
        let store = makeStore() // autosave off
        #expect(store.saveStatus == .upToDate)
        store.moveBlocks(in: cfgURL, fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(store.isDirty)
        #expect(store.saveStatus == .unsaved) // dirty + autosave off
        settings.autosaveEnabled = true
        #expect(store.saveStatus == .saving) // dirty + autosave on
    }

    @Test func allHostBlocksAndCopyCommand() {
        let store = makeStore()
        #expect(store.allHostBlocks.map { $0.title } == ["alpha", "beta", "gamma"])
        // Assert the command `copySSHCommand` builds, rather than round-tripping the
        // shared NSPasteboard (which races other copy tests under parallel runs).
        let block = store.documents[0].blocks[0]
        let alias = block.primaryAlias ?? ""
        let resolved = EffectiveConfigResolver.resolve(target: alias, in: store.documents)
        // Explicit mode expands HostName: alpha → a.example.com.
        #expect(SSHCommandBuilder.explicitCommand(target: alias, resolved: resolved).shellString == "ssh a.example.com")
    }
}

// MARK: - Expanded keyword registry + categorization

struct RegistryTests {
    @Test func knownKeywordsHaveCorrectCategory() {
        #expect(KeywordRegistry.category(for: "HostName") == .connection)
        #expect(KeywordRegistry.category(for: "IdentityFile") == .identity)
        #expect(KeywordRegistry.category(for: "ForwardAgent") == .forwarding)
        #expect(KeywordRegistry.category(for: "Ciphers") == .security)
        #expect(KeywordRegistry.category(for: "LogLevel") == .advanced)
    }

    @Test func unknownKeywordsAreCategorizedByHeuristic() {
        #expect(KeywordRegistry.category(for: "ForwardSomethingNew") == .forwarding)
        #expect(KeywordRegistry.category(for: "ProxyWhatever") == .connection)
        #expect(KeywordRegistry.category(for: "FancyCipherSuite") == .security)
        #expect(KeywordRegistry.category(for: "WeirdAuthThing") == .identity)
        #expect(KeywordRegistry.category(for: "CompletelyMadeUp") == .advanced)
    }

    @Test func securityKeywordsAreEncoded() {
        for keyword in [
            "Ciphers", "MACs", "KexAlgorithms", "HostKeyAlgorithms",
            "PubkeyAcceptedAlgorithms", "CASignatureAlgorithms",
            "FingerprintHash", "UpdateHostKeys", "HashKnownHosts",
            "VerifyHostKeyDNS", "RekeyLimit", "RequiredRSASize",
        ] {
            let info = KeywordRegistry.info(for: keyword)
            #expect(info != nil, "missing keyword \(keyword)")
            #expect(info?.category == .security || keyword == "RequiredRSASize")
        }
    }

    @Test func algorithmListsUseListFieldKind() {
        #expect(KeywordRegistry.info(for: "Ciphers")?.field == .list)
        #expect(KeywordRegistry.info(for: "KexAlgorithms")?.field == .list)
    }

    @Test func enumerationsCarryAllowedValues() {
        if case .enumeration(let values)? = KeywordRegistry.info(for: "StrictHostKeyChecking")?.field {
            #expect(values.contains("accept-new"))
        } else {
            Issue.record("StrictHostKeyChecking should be an enumeration")
        }
    }

    @Test func repeatablesAreFlagged() {
        for keyword in [
            "IdentityFile", "CertificateFile", "LocalForward",
            "RemoteForward", "DynamicForward", "SendEnv", "SetEnv", "Include",
        ] {
            #expect(KeywordRegistry.isRepeatable(keyword), "\(keyword) should be repeatable")
        }
        #expect(!KeywordRegistry.isRepeatable("HostName"))
    }

    @Test func searchMatchesNameHelpAndCategoryAndExcludes() {
        let cipherHits = KeywordRegistry.search("cipher")
        #expect(cipherHits.contains { $0.canonical == "Ciphers" })

        let excluded = KeywordRegistry.search("cipher", excluding: ["ciphers"])
        #expect(!excluded.contains { $0.canonical == "Ciphers" })

        // Help-text and category matches, not just the name.
        #expect(KeywordRegistry.search("keepalive").contains { $0.canonical == "ServerAliveInterval" })
        #expect(KeywordRegistry.search("forwarding").contains { $0.category == .forwarding })

        // Empty query returns everything available.
        #expect(KeywordRegistry.search("").count == KeywordRegistry.all.count)
    }

    @Test func everyKeywordHasHelpAndIsUnique() {
        var seen = Set<String>()
        for info in KeywordRegistry.all {
            #expect(!info.help.isEmpty, "\(info.canonical) missing help")
            #expect(seen.insert(info.key).inserted, "duplicate keyword \(info.canonical)")
        }
        #expect(KeywordRegistry.all.count > 60) // comprehensive coverage of ssh_config
    }
}

// MARK: - Identity-key helpers (the key picker)

struct IdentityKeyTests {
    private var sshDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
    }

    private func key(algorithm: String, name: String, hasPrivate: Bool) -> SSHPublicKey {
        let pub = sshDir.appendingPathComponent("\(name).pub")
        return SSHPublicKey(
            id: UUID(),
            publicKeyURL: pub,
            privateKeyURL: hasPrivate ? sshDir.appendingPathComponent(name) : nil,
            algorithm: algorithm,
            fingerprint: "SHA256:abc",
            comment: "user@host"
        )
    }

    @Test func identityFilePathIsTildeRelative() {
        let k = key(algorithm: "ssh-ed25519", name: "id_ed25519", hasPrivate: true)
        #expect(k.identityFilePath == "~/.ssh/id_ed25519")
    }

    @Test func identityFilePathFallsBackToPublicStem() {
        let k = key(algorithm: "ssh-ed25519", name: "id_ed25519", hasPrivate: false)
        #expect(k.identityFilePath == "~/.ssh/id_ed25519")
    }

    @Test func typeLabelsAreFriendly() {
        #expect(key(algorithm: "ssh-rsa", name: "id_rsa", hasPrivate: true).typeLabel == "RSA")
        #expect(key(algorithm: "ecdsa-sha2-nistp256", name: "id_ecdsa", hasPrivate: true).typeLabel == "ECDSA")
        #expect(
            key(algorithm: "sk-ssh-ed25519@openssh.com", name: "id_sk", hasPrivate: true).typeLabel == "Security Key")
    }
}

// MARK: - Block directive ordering (settings stay where added)

struct DirectiveOrderingTests {
    @Test func addedDirectivesKeepInsertionOrder() {
        var block = parse("Host x\n    HostName x.example.com\n").blocks[0]
        block.addDirective(keyword: "Port", value: "2222")
        block.addDirective(keyword: "Compression", value: "yes")
        let keywords = block.body.compactMap { $0.directive?.keyword }
        #expect(keywords == ["HostName", "Port", "Compression"])
    }

    @Test func repeatedIdentityFilesKeepOrder() {
        var block = parse("Host x\n").blocks[0]
        block.addDirective(keyword: "IdentityFile", value: "~/.ssh/one")
        block.addDirective(keyword: "IdentityFile", value: "~/.ssh/two")
        #expect(block.values(for: "IdentityFile") == ["~/.ssh/one", "~/.ssh/two"])
    }
}
