//
//  sshconfigmanagerTests.swift
//  sshconfigmanagerTests
//
//  Created by Dusan Malusev on 4. 6. 2026..
//

import Foundation
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

// MARK: - Fixtures

private enum Fixture {
    /// A realistic config with a global block, comments, multiple patterns, and indentation.
    static let realistic =
        [
            "# Global defaults",
            "Host *",
            "    ServerAliveInterval 60",
            "    ServerAliveCountMax 3",
            "    AddKeysToAgent yes",
            "",
            "# Work bastion",
            "Host bastion",
            "    HostName bastion.example.com",
            "    User admin",
            "    Port 2222",
            "    IdentityFile ~/.ssh/id_ed25519",
            "",
            "Host web prod-web",
            "    HostName 10.0.0.5",
            "    User deploy",
            "    ForwardAgent yes",
        ].joined(separator: "\n") + "\n"

    /// Uses `=` separators and tab indentation; no trailing newline.
    static let equalsAndTabs = "Host foo\n\tHostName=foo.example.com\n\tPort = 22"

    /// Comments inside a block, an unknown keyword, a Match block, and an Include.
    static let withMatchAndInclude =
        [
            "Include ~/.ssh/conf.d/*",
            "",
            "Host gamma",
            "    HostName gamma.local",
            "    # a note in the body",
            "    SomeUnknownKey value here",
            "",
            "Match host gamma user root",
            "    ForwardAgent no",
        ].joined(separator: "\n") + "\n"
}

// MARK: - Round-trip (lossless)

struct RoundTripTests {
    private func assertRoundTrips(_ text: String, _ sourceComment: Comment? = nil) {
        let url = URL(fileURLWithPath: "/tmp/config")
        let document = SSHConfigParser.parse(text, sourceURL: url)
        let output = SSHConfigSerializer.serialize(document)
        #expect(output == text, sourceComment ?? "round-trip mismatch")
    }

    @Test func realisticConfigRoundTripsByteForByte() {
        assertRoundTrips(Fixture.realistic)
    }

    @Test func equalsAndTabsRoundTrip() {
        assertRoundTrips(Fixture.equalsAndTabs)
    }

    @Test func matchAndIncludeRoundTrip() {
        assertRoundTrips(Fixture.withMatchAndInclude)
    }

    @Test func emptyStringRoundTrips() {
        assertRoundTrips("")
    }

    @Test func trailingWhitespaceAndBlankLinesPreserved() {
        let text = "Host a   \n    Port 22  \n\n\n"
        assertRoundTrips(text)
    }

    @Test func crlfLineEndingsPreserved() {
        let text = "Host a\r\n    Port 22\r\n"
        assertRoundTrips(text)
    }
}

// MARK: - Line splitting

struct LineSplittingTests {
    @Test func trailingNewlineDetected() {
        let (lines, trailing) = SSHConfigParser.splitLines("a\nb\n")
        #expect(lines == ["a", "b"])
        #expect(trailing)
    }

    @Test func noTrailingNewline() {
        let (lines, trailing) = SSHConfigParser.splitLines("a\nb")
        #expect(lines == ["a", "b"])
        #expect(!trailing)
    }

    @Test func emptyString() {
        let (lines, trailing) = SSHConfigParser.splitLines("")
        #expect(lines.isEmpty)
        #expect(!trailing)
    }

    @Test func singleNewline() {
        let (lines, trailing) = SSHConfigParser.splitLines("\n")
        #expect(lines == [""])
        #expect(trailing)
    }
}

// MARK: - Single line parsing

struct LineParsingTests {
    private func directive(_ raw: String) -> Directive? {
        SSHConfigParser.parseLine(raw).directive
    }

    @Test func parsesSpaceSeparatedDirective() {
        let d = directive("    Port 2222")
        #expect(d?.leadingIndent == "    ")
        #expect(d?.keyword == "Port")
        #expect(d?.value == "2222")
        #expect(d?.usesEquals == false)
    }

    @Test func parsesEqualsSeparatedDirective() {
        let d = directive("HostName=foo.example.com")
        #expect(d?.keyword == "HostName")
        #expect(d?.value == "foo.example.com")
        #expect(d?.usesEquals == true)
    }

    @Test func parsesEqualsWithSpaces() {
        let d = directive("Port = 22")
        #expect(d?.keyword == "Port")
        #expect(d?.value == "22")
        #expect(d?.separatorText == " = ")
    }

    @Test func detectsCommentLine() {
        if case .comment = SSHConfigParser.parseLine("  # hi") {
        } else {
            Issue.record("expected comment")
        }
    }

    @Test func detectsBlankLine() {
        if case .blank = SSHConfigParser.parseLine("   ") {
        } else {
            Issue.record("expected blank")
        }
    }
}

// MARK: - Structure

struct StructureTests {
    private func parseRealistic() -> SSHConfigDocument {
        SSHConfigParser.parse(Fixture.realistic, sourceURL: URL(fileURLWithPath: "/tmp/config"))
    }

    @Test func groupsBlocks() {
        let doc = parseRealistic()
        #expect(doc.blocks.count == 3)
        #expect(doc.blocks[0].isWildcard)
        #expect(doc.blocks[1].patterns == ["bastion"])
        #expect(doc.blocks[2].patterns == ["web", "prod-web"])
    }

    @Test func leadingCommentAttachesToBlock() {
        let doc = parseRealistic()
        // "# Work bastion" should travel with the bastion block, not the wildcard block.
        let bastion = doc.blocks[1]
        #expect(
            bastion.leading.contains { line in
                if case .comment(_, let raw) = line { return raw.contains("Work bastion") }
                return false
            })
    }

    @Test func readsDirectiveValues() {
        let doc = parseRealistic()
        #expect(doc.blocks[1].firstValue(for: "hostname") == "bastion.example.com")
        #expect(doc.blocks[1].firstValue(for: "Port") == "2222")
    }

    @Test func detectsIncludeDirective() {
        let doc = SSHConfigParser.parse(
            Fixture.withMatchAndInclude,
            sourceURL: URL(fileURLWithPath: "/tmp/config"))
        #expect(doc.includeDirectives.count == 1)
        #expect(doc.includeDirectives.first?.value == "~/.ssh/conf.d/*")
    }

    @Test func detectsMatchBlock() {
        let doc = SSHConfigParser.parse(
            Fixture.withMatchAndInclude,
            sourceURL: URL(fileURLWithPath: "/tmp/config"))
        let match = doc.blocks.first { $0.kind == .match }
        #expect(match != nil)
        #expect(match?.patterns == ["host", "gamma", "user", "root"])
    }
}

// MARK: - Targeted editing

struct EditingTests {
    private let url = URL(fileURLWithPath: "/tmp/config")

    @Test func editingOneValueChangesOnlyThatLine() {
        var doc = SSHConfigParser.parse(Fixture.realistic, sourceURL: url)
        doc.blocks[1].setValue("2200", for: "Port")
        let output = SSHConfigSerializer.serialize(doc)

        let originalLines = Fixture.realistic.components(separatedBy: "\n")
        let newLines = output.components(separatedBy: "\n")
        #expect(originalLines.count == newLines.count)

        let differing = zip(originalLines, newLines).enumerated().filter { $0.element.0 != $0.element.1 }
        #expect(differing.count == 1)
        #expect(differing.first?.element.1 == "    Port 2200")
        // Indentation of the rewritten line is preserved.
        #expect(newLines.contains("    Port 2200"))
    }

    @Test func addingValueUsesBlockIndentation() {
        var doc = SSHConfigParser.parse(Fixture.realistic, sourceURL: url)
        doc.blocks[1].setValue("yes", for: "Compression")
        let output = SSHConfigSerializer.serialize(doc)
        #expect(output.contains("    Compression yes"))
    }

    @Test func removingValueDropsTheLine() {
        var doc = SSHConfigParser.parse(Fixture.realistic, sourceURL: url)
        doc.blocks[1].setValue(nil, for: "Port")
        let output = SSHConfigSerializer.serialize(doc)
        #expect(!output.contains("Port 2222"))
        // Sibling directives remain.
        #expect(output.contains("HostName bastion.example.com"))
    }

    @Test func multipleIdentityFilesReadAsList() {
        let text = "Host a\n    IdentityFile ~/.ssh/one\n    IdentityFile ~/.ssh/two\n"
        let doc = SSHConfigParser.parse(text, sourceURL: url)
        #expect(doc.blocks[0].values(for: "IdentityFile") == ["~/.ssh/one", "~/.ssh/two"])
    }
}

// MARK: - Keyword registry

struct KeywordRegistryTests {
    @Test func lookupIsCaseInsensitive() {
        #expect(KeywordRegistry.info(for: "hostname")?.canonical == "HostName")
        #expect(KeywordRegistry.info(for: "PORT")?.canonical == "Port")
    }

    @Test func unknownKeywordReturnsNil() {
        #expect(KeywordRegistry.info(for: "SomeUnknownKey") == nil)
    }

    @Test func identityFileIsRepeatable() {
        #expect(KeywordRegistry.isRepeatable("IdentityFile"))
        #expect(!KeywordRegistry.isRepeatable("HostName"))
    }
}

// MARK: - Key fingerprints

struct KeyServiceTests {
    // Reference vector generated by `ssh-keygen -t ed25519`.
    private let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIBo3Ptin48f2tR6Sa9f1nHtnIr6zs1vb5F+ewkzXJ39d"
    private let expectedFingerprint = "SHA256:2HlA4NjvAHo7XvSaZ+Mrruvu1QHZgQ5wqIglpnJ3K2I"
    private let pubLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBo3Ptin48f2tR6Sa9f1nHtnIr6zs1vb5F+ewkzXJ39d test@example.com"

    @Test func fingerprintMatchesSSHKeygen() {
        #expect(SSHKeyService.fingerprint(base64Blob: blob) == expectedFingerprint)
    }

    @Test func parsesPublicKey() {
        let url = URL(fileURLWithPath: "/tmp/id_ed25519.pub")
        let key = SSHKeyService.parsePublicKey(pubLine, url: url, siblings: ["id_ed25519"])
        #expect(key?.algorithm == "ssh-ed25519")
        #expect(key?.typeLabel == "Ed25519")
        #expect(key?.comment == "test@example.com")
        #expect(key?.fingerprint == expectedFingerprint)
        #expect(key?.privateKeyURL?.lastPathComponent == "id_ed25519")
    }

    @Test func parsesPublicKeyWithoutComment() {
        let url = URL(fileURLWithPath: "/tmp/id_ed25519.pub")
        let key = SSHKeyService.parsePublicKey("ssh-ed25519 \(blob)", url: url, siblings: [])
        #expect(key?.comment == "")
        #expect(key?.privateKeyURL == nil)
    }
}

// MARK: - known_hosts

struct KnownHostsTests {
    private let sample =
        [
            "# a comment",
            "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBo3Ptin48f2tR6Sa9f1nHtnIr6zs1vb5F+ewkzXJ39d",
            "|1|abcd= ssh-rsa AAAAB3Nz",
            "@cert-authority *.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBo3Ptin48f2tR6Sa9f1nHtnIr6zs1vb5F+ewkzXJ39d",
        ].joined(separator: "\n") + "\n"

    @Test func parsesEntriesSkippingComments() {
        let entries = KnownHostsService.parse(sample)
        #expect(entries.count == 3)
        #expect(entries[0].hostsDisplay == "github.com")
        #expect(entries[0].keyType == "ssh-ed25519")
        #expect(entries[0].fingerprint == "SHA256:2HlA4NjvAHo7XvSaZ+Mrruvu1QHZgQ5wqIglpnJ3K2I")
    }

    @Test func marksHashedEntries() {
        let entries = KnownHostsService.parse(sample)
        let hashed = entries.first { $0.isHashed }
        #expect(hashed?.hostsDisplay == "(hashed)")
    }

    @Test func parsesMarker() {
        let entries = KnownHostsService.parse(sample)
        let ca = entries.first { $0.marker != nil }
        #expect(ca?.marker == "@cert-authority")
        #expect(ca?.hostsDisplay == "*.example.com")
    }

    @Test func removesLineByIndex() {
        let entries = KnownHostsService.parse(sample)
        let github = entries[0]
        let updated = KnownHostsService.removing(lineIndex: github.lineIndex, from: sample)
        #expect(!updated.contains("github.com"))
        #expect(updated.contains("cert-authority"))
    }

    @Test func diffIsEmptyForIdenticalParses() {
        // Two independent `parse()` calls over the same text mint fresh UUIDs per
        // entry — the diff must compare by raw line text, not `id`.
        let a = KnownHostsService.parse(sample)
        let b = KnownHostsService.parse(sample)
        #expect(KnownHostsService.diff(old: a, new: b).isEmpty)
    }

    @Test func diffDetectsAddedLine() {
        let before = KnownHostsService.parse(sample)
        let appended = KnownHostsService.appending(
            line: "example.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBo3Ptin48f2tR6Sa9f1nHtnIr6zs1vb5F+ewkzXJ39d",
            to: sample)
        let after = KnownHostsService.parse(appended)
        let summary = KnownHostsService.diff(old: before, new: after)
        #expect(summary.added.count == 1)
        #expect(summary.removed.isEmpty)
        #expect(summary.added.first?.hostsDisplay == "example.net")
    }

    @Test func diffDetectsRemovedLine() {
        let before = KnownHostsService.parse(sample)
        let github = before[0]
        let after = KnownHostsService.parse(
            KnownHostsService.removing(lineIndex: github.lineIndex, from: sample))
        let summary = KnownHostsService.diff(old: before, new: after)
        #expect(summary.removed.count == 1)
        #expect(summary.added.isEmpty)
        #expect(summary.removed.first?.hostsDisplay == "github.com")
    }

    @Test func diffIsEmptyForReorderedIdenticalLines() {
        // Same set of raw lines, different order (e.g. an external `sort -u`) — no
        // entries were genuinely added or removed.
        let before = KnownHostsService.parse(sample)
        let reordered = KnownHostsService.parse(sample.split(separator: "\n").reversed().joined(separator: "\n"))
        #expect(KnownHostsService.diff(old: before, new: reordered).isEmpty)
    }

    @Test func diffDetectsRemovalOfOneDuplicateLine() {
        // A surviving identical copy must not mask the removal of the other copy —
        // a plain Set-membership diff would report this as no change.
        let duplicated =
            sample + "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBo3Ptin48f2tR6Sa9f1nHtnIr6zs1vb5F+ewkzXJ39d\n"
        let before = KnownHostsService.parse(duplicated)
        let github = before[0]
        let after = KnownHostsService.parse(
            KnownHostsService.removing(lineIndex: github.lineIndex, from: duplicated))
        let summary = KnownHostsService.diff(old: before, new: after)
        #expect(summary.removed.count == 1)
        #expect(summary.added.isEmpty)
    }

    // MARK: - Trust-on-first-use persistence (audit #9)

    private let tofuKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBo3Ptin48f2tR6Sa9f1nHtnIr6zs1vb5F+ewkzXJ39d"

    @Test func formatTrustLineUnhashedUsesPlainHostToken() {
        let line = KnownHostsService.formatTrustLine(
            host: "example.com", port: 22, openSSHKeyLine: tofuKeyLine,
            hashed: false, salt: Data(), hmacSHA1: KnownHostsValidatingDelegate.hmacSHA1)
        #expect(line == "example.com \(tofuKeyLine)")
    }

    @Test func formatTrustLineUnhashedBracketsNonDefaultPort() {
        let line = KnownHostsService.formatTrustLine(
            host: "example.com", port: 2222, openSSHKeyLine: tofuKeyLine,
            hashed: false, salt: Data(), hmacSHA1: KnownHostsValidatingDelegate.hmacSHA1)
        #expect(line == "[example.com]:2222 \(tofuKeyLine)")
    }

    @Test func formatTrustLineHashedRoundTripsThroughMatchesHashed() {
        let salt = Data((0..<20).map { UInt8($0) })
        let line = KnownHostsService.formatTrustLine(
            host: "example.com", port: 22, openSSHKeyLine: tofuKeyLine,
            hashed: true, salt: salt, hmacSHA1: KnownHostsValidatingDelegate.hmacSHA1)
        #expect(line.hasPrefix("|1|"))
        let entries = KnownHostsService.parse(line + "\n")
        #expect(entries.count == 1)
        #expect(entries[0].isHashed)
        #expect(
            KnownHostsVerifier.matchesHashed(
                entries[0], host: "example.com", port: 22,
                hmacSHA1: KnownHostsValidatingDelegate.hmacSHA1))
        // A different host must not match the same hashed entry.
        #expect(
            !KnownHostsVerifier.matchesHashed(
                entries[0], host: "other.example.com", port: 22,
                hmacSHA1: KnownHostsValidatingDelegate.hmacSHA1))
    }

    @Test func decideFlagsChangedKeyAfterTofuPersist() {
        // Simulates the audit #9 fix end-to-end at the pure-logic layer: a key
        // trusted-on-first-use gets formatted and appended exactly as
        // `ConfigStore.persistTrustedHostKey` would, then a later connection
        // presenting a *different* key for the same host must come back
        // `.mismatch` (possible MITM) instead of `.unknown` (silently re-trusted).
        let line = KnownHostsService.formatTrustLine(
            host: "db1.example.com", port: 22, openSSHKeyLine: tofuKeyLine,
            hashed: false, salt: Data(), hmacSHA1: KnownHostsValidatingDelegate.hmacSHA1)
        let entries = KnownHostsService.parse(line + "\n")
        let originalFingerprint = entries[0].fingerprint

        #expect(
            KnownHostsVerifier.decide(
                host: "db1.example.com", port: 22,
                fingerprint: originalFingerprint, entries: entries) == .match)

        let changedKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyEntirelyDifferentBlobHere1234"
        let changedFingerprint = KnownHostsService.parse(
            "db1.example.com \(changedKeyLine)\n")[0].fingerprint
        #expect(changedFingerprint != originalFingerprint)
        #expect(
            KnownHostsVerifier.decide(
                host: "db1.example.com", port: 22,
                fingerprint: changedFingerprint, entries: entries) == .mismatch)
    }
}
