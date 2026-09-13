//
//  HostNamingTests.swift
//  sshconfigmanagerTests
//
//  The clone-naming rules are pure, so their contract lives here: the `-copy` /
//  numbered-increment derivation, collision avoidance, and the spacing-preserving
//  header rewrite that renames only the first concrete alias.
//

import Foundation
import SSHConfigCore
import Testing

struct HostNamingDuplicateNameTests {
    @Test func plainBaseGetsCopySuffix() {
        #expect(HostNaming.duplicateName(for: "web", existing: ["web"]) == "web-copy")
    }

    /// A second duplicate of the same host avoids the first clone.
    @Test func copySuffixIncrementsWhenTaken() {
        #expect(HostNaming.duplicateName(for: "web", existing: ["web", "web-copy"]) == "web-copy-2")
        #expect(
            HostNaming.duplicateName(
                for: "web", existing: ["web", "web-copy", "web-copy-2"]) == "web-copy-3")
    }

    /// A trailing `-N` increments instead of appending `-copy`.
    @Test func numberedBaseIncrements() {
        #expect(HostNaming.duplicateName(for: "web-2", existing: ["web-2"]) == "web-3")
    }

    /// The increment skips already-taken numbers to stay unique.
    @Test func numberedBaseSkipsTakenNumbers() {
        #expect(
            HostNaming.duplicateName(
                for: "web-2", existing: ["web-2", "web-3", "web-4"]) == "web-5")
    }

    /// An existing `-copy` increments rather than stacking into `web-copy-copy`.
    @Test func copyBaseIncrementsCopyNumber() {
        #expect(HostNaming.duplicateName(for: "web-copy", existing: ["web-copy"]) == "web-copy-2")
        #expect(
            HostNaming.duplicateName(
                for: "web-copy-2", existing: ["web-copy", "web-copy-2"]) == "web-copy-3")
    }

    /// A bare dash-suffix with no digits isn't a number.
    @Test func nonNumericDashSuffixSuffixes() {
        #expect(HostNaming.duplicateName(for: "db-prod", existing: ["db-prod"]) == "db-prod-copy")
    }
}

struct HostNamingRenameTests {
    @Test func renamesSoleAlias() {
        #expect(HostNaming.renamingFirstAlias(in: "web", to: "web-copy") == "web-copy")
    }

    /// Only the first concrete alias changes; the rest of the header is verbatim,
    /// including the exact (multi-space) gaps between patterns.
    @Test func renamesOnlyFirstConcreteAliasPreservingSpacing() {
        #expect(
            HostNaming.renamingFirstAlias(in: "web   web.internal  *.web", to: "web-copy")
                == "web-copy   web.internal  *.web")
    }

    /// A wildcard first token is skipped in favor of the first concrete alias.
    @Test func skipsLeadingWildcard() {
        #expect(
            HostNaming.renamingFirstAlias(in: "*.web web", to: "web-copy")
                == "*.web web-copy")
    }

    /// With no concrete alias at all, the first token is renamed as a fallback.
    @Test func fallsBackToFirstTokenWhenNoneConcrete() {
        #expect(
            HostNaming.renamingFirstAlias(in: "*.web *.internal", to: "clone")
                == "clone *.internal")
    }

    @Test func emptyHeaderBecomesTheAlias() {
        #expect(HostNaming.renamingFirstAlias(in: "", to: "clone") == "clone")
    }
}

// MARK: - Deep copy / clone identity

struct BlockCloneTests {
    private func firstBlock(_ text: String) -> HostBlock {
        SSHConfigParser.parse(text, sourceURL: URL(fileURLWithPath: "/tmp/config")).blocks[0]
    }

    /// A clone shares no identity with its source — block id, header id, and every
    /// body line id are fresh — so per-line edits to one never reach the other.
    @Test func cloneHasFreshIdentitiesButIdenticalText() {
        let block = firstBlock("Host web\n    HostName 10.0.0.5\n    Port 22\n")
        let clone = block.deepCopyWithFreshIDs()

        #expect(clone.id != block.id)
        #expect(clone.header.id != block.header.id)
        let sourceIDs = Set(block.body.map(\.id))
        let cloneIDs = Set(clone.body.map(\.id))
        #expect(sourceIDs.isDisjoint(with: cloneIDs))

        // Untouched lines round-trip byte-for-byte.
        #expect(clone.body.map(\.rendered) == block.body.map(\.rendered))
        #expect(clone.header.rendered == block.header.rendered)
    }

    /// Editing the clone leaves the source untouched (value semantics + fresh ids).
    @Test func editingCloneDoesNotAffectSource() {
        let block = firstBlock("Host web\n    HostName 10.0.0.5\n")
        var clone = block.deepCopyWithFreshIDs()
        clone.setValue("changed.example", for: "HostName")
        #expect(block.firstValue(for: "HostName") == "10.0.0.5")
        #expect(clone.firstValue(for: "HostName") == "changed.example")
    }

    /// The `leading` label comment is carried onto the clone with a fresh id.
    @Test func clonePreservesLeadingComment() {
        let block = firstBlock("# Production web tier\nHost web\n    HostName 10.0.0.5\n")
        let clone = block.deepCopyWithFreshIDs()
        #expect(clone.leading.map(\.rendered) == block.leading.map(\.rendered))
        #expect(!clone.leading.isEmpty)
        // Fresh ids on the leading lines too.
        #expect(Set(clone.leading.map(\.id)).isDisjoint(with: Set(block.leading.map(\.id))))
    }
}
