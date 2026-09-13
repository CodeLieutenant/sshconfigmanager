//
//  AuditHostNamingQuotedAliasTests.swift
//  sshconfigmanagerTests
//
//  AUDIT 2026-07-11 (docs/release/macos-bug-audit-2026-07-11.md, finding CFG-1) — FIXED.
//  Duplicating a Host whose primary alias is double-quoted (contains a space) used to
//  corrupt the header. `HostBlock.patterns` honors quotes, so `primaryAlias` is the whole
//  space-containing alias — but `HostNaming.renamingFirstAlias` / `tokenRanges` split
//  purely on whitespace and were quote-blind, so they renamed only the fragment before
//  the first space and stranded the closing quote, and `ConfigStore.duplicateBlock` wrote
//  the mangled header straight to ~/.ssh/config. The rename is now quote-aware: a quoted
//  span is one token, and a replacement alias that contains whitespace is re-quoted.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct AuditHostNamingQuotedAliasTests {
    private func patterns(ofHeaderValue value: String) -> [String] {
        let doc = SSHConfigParser.parse("Host \(value)\n", sourceURL: URL(fileURLWithPath: "/x"))
        return doc.blocks.first!.patterns
    }

    /// Baseline: the parser/patterns layer correctly treats `"my server"` as ONE alias.
    @Test func quotedAliasParsesAsSingleToken() {
        #expect(patterns(ofHeaderValue: "\"my server\" web") == ["my server", "web"])
    }

    /// The former exploit, now fixed: renaming the first concrete alias of a quoted
    /// header keeps the quoted span intact and re-quotes the space-containing replacement.
    @Test func renamingQuotedAliasKeepsItIntact() {
        let header = "\"my server\" web"
        let renamed = HostNaming.renamingFirstAlias(in: header, to: "my server-copy")

        // The whole `"my server"` token is replaced, and because the new alias contains a
        // space it is re-quoted, leaving the extra `web` pattern and its spacing untouched.
        #expect(renamed == "\"my server-copy\" web")
    }

    /// Round-trip proof: the renamed header now re-parses back into exactly the two
    /// intended, balanced aliases.
    @Test func renamedHeaderReparsesIntoTheIntendedAliases() {
        let renamed = HostNaming.renamingFirstAlias(in: "\"my server\" web", to: "my server-copy")
        let reparsed = patterns(ofHeaderValue: renamed)

        #expect(reparsed == ["my server-copy", "web"])
        // Quotes are balanced (even count) -> valid config.
        #expect(renamed.filter { $0 == "\"" }.count % 2 == 0)
    }

    /// A replacement alias with no whitespace is left unquoted (the common case is
    /// unaffected by the quoting logic).
    @Test func plainReplacementAliasIsNotQuoted() {
        #expect(HostNaming.renamingFirstAlias(in: "web prod", to: "web-copy") == "web-copy prod")
    }
}
