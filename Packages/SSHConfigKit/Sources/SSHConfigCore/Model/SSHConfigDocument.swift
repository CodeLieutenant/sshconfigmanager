//
//  SSHConfigDocument.swift
//  sshconfigmanager
//
//  An in-memory representation of a single ssh_config file.
//

import Foundation

/// A parsed ssh_config file. `preamble` holds global options and comments that
/// appear before the first `Host`/`Match` block; `blocks` holds the host/match
/// blocks in file order.
public struct SSHConfigDocument: Identifiable, Equatable {
    public let id: UUID
    /// The file on disk this document was loaded from / will be saved to.
    public var sourceURL: URL
    /// Lines before the first `Host`/`Match` (global defaults, header comments).
    public var preamble: [ConfigLine]
    /// The host and match blocks, in order.
    public var blocks: [HostBlock]
    /// Whether the original file ended with a trailing newline (preserved on save).
    public var trailingNewline: Bool

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        preamble: [ConfigLine] = [],
        blocks: [HostBlock] = [],
        trailingNewline: Bool = true
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.preamble = preamble
        self.blocks = blocks
        self.trailingNewline = trailingNewline
    }

    /// A display name for the file (e.g. `config`, `work.conf`).
    public var displayName: String { sourceURL.lastPathComponent }

    /// The line terminator this file uses — `"\r"` for CRLF, `""` for LF. Derived from
    /// the lines already present (`SSHConfigParser` keeps a CRLF file's `\r` in each
    /// line's `trailingText`, so it shows up in `rendered`), so a line the app *inserts*
    /// can match the file it's going into.
    ///
    /// Without this, every insertion path — add host, add Global Defaults, new from
    /// template, import, duplicate, move between files, wire up an `Include` — wrote
    /// LF-only lines into a CRLF config and left it with mixed endings.
    ///
    /// Returns on the first `\r` seen, so a CRLF file costs one line; a pure-LF file
    /// walks the document, which only happens at an explicit insertion point.
    public var lineEnding: String {
        for line in preamble where line.rendered.hasSuffix("\r") { return "\r" }
        for block in blocks {
            for line in block.leading where line.rendered.hasSuffix("\r") { return "\r" }
            if block.header.rendered.hasSuffix("\r") { return "\r" }
            for line in block.body where line.rendered.hasSuffix("\r") { return "\r" }
        }
        return ""
    }

    /// Appends `newBlocks` at the end of the file, separated from what's already there
    /// by one blank line, and guarantees the file ends with a newline.
    ///
    /// The one home for "add a block to this file". Six call sites in `ConfigStore`
    /// (add host, Global Defaults, template, import, duplicate-into, move-into) each
    /// carried their own copy of this, down to the same three-line comment about not
    /// indexing `blocks[-1]` on a preamble-only config — so a fix to any one of them
    /// (such as honouring `lineEnding`) had to be made six times or not at all.
    public mutating func appendBlocks(_ newBlocks: [HostBlock]) {
        guard !newBlocks.isEmpty else { return }
        let ending = lineEnding
        // Only when there IS a previous block: guarding on `!preamble.isEmpty` instead
        // would index `blocks[-1]` on a preamble-only config (globals and comments but
        // no `Host` block), a common shape that used to crash every add path.
        if !blocks.isEmpty {
            blocks[blocks.count - 1].body.append(.blank(ending))
        }
        blocks.append(contentsOf: newBlocks.map { $0.adoptingLineEnding(ending) })
        trailingNewline = true
    }

    /// Appends a directive to the preamble, separated by a blank line when the preamble
    /// isn't empty. Used to wire up an `Include`; matches the file's line ending.
    public mutating func appendPreamble(directive: Directive) {
        let ending = lineEnding
        if !preamble.isEmpty { preamble.append(.blank(ending)) }
        var directive = directive
        if !ending.isEmpty, !directive.trailingText.hasSuffix(ending) {
            directive.trailingText += ending
            directive.isDirty = true
        }
        preamble.append(.directive(directive))
    }

    /// `Include` directives found in this document (preamble or any block body),
    /// in file order.
    public var includeDirectives: [Directive] {
        var result: [Directive] = []
        for line in preamble {
            if let directive = line.directive, directive.canonicalKeyword == "include" {
                result.append(directive)
            }
        }
        for block in blocks {
            for line in block.body {
                if let directive = line.directive, directive.canonicalKeyword == "include" {
                    result.append(directive)
                }
            }
        }
        return result
    }
}
