//
//  SSHConfigParser.swift
//  sshconfigmanager
//
//  Parses ssh_config text into a lossless document model.
//

import Foundation

/// Parses ssh_config text into a `SSHConfigDocument`.
///
/// The parser is deliberately lossless: every physical line keeps its exact text,
/// so re-serializing an unedited document reproduces the input byte-for-byte
/// (including indentation, `=` separators, comments, blank lines, and CRLF endings).
public enum SSHConfigParser {

    /// Parses a single file's contents.
    public static func parse(_ text: String, sourceURL: URL) -> SSHConfigDocument {
        let (rawLines, trailingNewline) = splitLines(text)
        let parsed = rawLines.map { parseLine($0) }

        var preamble: [ConfigLine] = []
        var blocks: [HostBlock] = []

        for line in parsed {
            if let directive = line.directive, isHeaderKeyword(directive.canonicalKeyword) {
                // Pull a run of comment lines directly above into the new block so a
                // label comment stays attached to its host.
                let leading: [ConfigLine]
                if blocks.isEmpty {
                    leading = detachTrailingComments(from: &preamble)
                } else {
                    leading = detachTrailingComments(from: &blocks[blocks.count - 1].body)
                }
                let block = HostBlock(
                    kind: directive.canonicalKeyword == "host" ? .host : .match,
                    leading: leading,
                    header: directive,
                    body: [],
                    sourceURL: sourceURL
                )
                blocks.append(block)
            } else if blocks.isEmpty {
                preamble.append(line)
            } else {
                blocks[blocks.count - 1].body.append(line)
            }
        }

        return SSHConfigDocument(
            sourceURL: sourceURL,
            preamble: preamble,
            blocks: blocks,
            trailingNewline: trailingNewline
        )
    }

    // MARK: - Line splitting

    /// Splits text into lines (without their newline) and reports whether the text
    /// ended with a trailing newline. CRLF endings are preserved inside each line's
    /// raw text (the trailing `\r`).
    public static func splitLines(_ text: String) -> (lines: [String], trailingNewline: Bool) {
        if text.isEmpty { return ([], false) }
        // Compare SCALARS, not Characters. Swift folds "\r\n" into a single grapheme
        // cluster, so `text.hasSuffix("\n")` is false for every CRLF file — its last
        // Character is "\r\n", which is not "\n". That mis-report left the trailing
        // empty component in `components` as a phantom blank line at the end of the
        // last block, and the accidental symmetry (phantom line + join("\n")) is the
        // only reason an untouched CRLF file still round-tripped byte-for-byte.
        //
        // It stopped being accidental the moment anything was appended: a directive
        // added to the last block landed *after* the phantom blank, so the file gained
        // a stray empty line in the middle and lost its final newline.
        let trailingNewline = text.unicodeScalars.last == "\n"
        var components = text.components(separatedBy: "\n")
        if trailingNewline {
            components.removeLast() // drop the empty trailing element after the final "\n"
        }
        return (components, trailingNewline)
    }

    // MARK: - Single line parsing

    public static func parseLine(_ raw: String) -> ConfigLine {
        // A leading UTF-8 BOM (only possible on the file's very first line, from
        // certain Windows editors) must not itself become part of the recognized
        // keyword — `\u{FEFF}Host` doesn't match the canonical "host" keyword, so
        // the block silently fell into the preamble instead of being recognized
        // (audit #36). Classify off `content` (BOM stripped); `raw` — and
        // therefore `rawText` below — still carries the BOM byte-for-byte, so
        // round-tripping an unedited line is unaffected.
        let bom = "\u{FEFF}"
        let hasBOM = raw.hasPrefix(bom)
        var content = hasBOM ? String(raw.dropFirst(bom.count)) : raw

        // A CRLF file's `\r` belongs to the line *terminator*, not to the line's
        // content, so split it off before classifying anything and carry it in
        // `trailingText`. `rawText` (and `rendered` for a dirty line) still reproduce
        // the byte-exact original, but `keyword`/`value`/`patterns` now come out clean.
        //
        // It used to stay glued to the last field, making the strip every *consumer's*
        // job (audit #27) — and four consumers forgot: `ConfigLinter` read a valid
        // `Port 22` as "not a number" and silently dropped the
        // `StrictHostKeyChecking no` warning, `KeyAuditor` reported every referenced
        // key as orphaned (with a one-click delete), `HostNaming.renamingFirstAlias`
        // destroyed the `\r` when renaming a single-pattern header, and `setValue`
        // re-rendered the edited line without it, leaving mixed endings in the file.
        // Handling it once, here, is what stops the next consumer from forgetting too.
        //
        // A bare `"\r"` line also used to parse as a *directive* whose keyword was
        // `"\r"`; stripping first lets it fall through to `.blank` where it belongs.
        let lineEnding: String
        if content.hasSuffix("\r") {
            lineEnding = "\r"
            content = String(content.dropLast())
        } else {
            lineEnding = ""
        }

        // Leading whitespace.
        let indentEnd = content.firstIndex { $0 != " " && $0 != "\t" } ?? content.endIndex
        let indent = (hasBOM ? bom : "") + content[content.startIndex..<indentEnd]
        let rest = content[indentEnd...]

        if rest.isEmpty {
            return .blank(id: UUID(), raw: raw)
        }
        if rest.first == "#" {
            return .comment(id: UUID(), raw: raw)
        }

        // Keyword: up to the first whitespace or '='.
        let keywordEnd = rest.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" } ?? rest.endIndex
        let keyword = String(rest[rest.startIndex..<keywordEnd])

        if keywordEnd == rest.endIndex {
            // Keyword with no value (unusual). Treat the whole thing as a directive.
            return .directive(
                Directive(
                    leadingIndent: indent,
                    keyword: keyword,
                    separatorText: "",
                    value: "",
                    trailingText: lineEnding,
                    rawText: raw
                ))
        }

        // Separator: run of whitespace, an optional single '=', then whitespace.
        var index = keywordEnd
        func consumeWhitespace() {
            while index < rest.endIndex, rest[index] == " " || rest[index] == "\t" {
                index = rest.index(after: index)
            }
        }
        consumeWhitespace()
        if index < rest.endIndex, rest[index] == "=" {
            index = rest.index(after: index)
            consumeWhitespace()
        }
        let separatorText = String(rest[keywordEnd..<index])

        // Remainder = value + trailing whitespace.
        let remainder = rest[index...]
        let valueEnd = remainder.lastIndex { $0 != " " && $0 != "\t" }
        let value: String
        let trailing: String
        if let valueEnd {
            let afterValue = remainder.index(after: valueEnd)
            value = String(remainder[remainder.startIndex...valueEnd])
            trailing = String(remainder[afterValue...]) + lineEnding
        } else {
            value = ""
            trailing = String(remainder) + lineEnding
        }

        return .directive(
            Directive(
                leadingIndent: indent,
                keyword: keyword,
                separatorText: separatorText,
                value: value,
                trailingText: trailing,
                rawText: raw
            ))
    }

    // MARK: - Helpers

    private static func isHeaderKeyword(_ canonical: String) -> Bool {
        canonical == "host" || canonical == "match"
    }

    /// Removes and returns a trailing run of comment lines from `lines` (stopping at
    /// the first blank line or directive), preserving their order.
    private static func detachTrailingComments(from lines: inout [ConfigLine]) -> [ConfigLine] {
        var detached: [ConfigLine] = []
        while let last = lines.last, case .comment = last {
            detached.insert(last, at: 0)
            lines.removeLast()
        }
        return detached
    }
}
