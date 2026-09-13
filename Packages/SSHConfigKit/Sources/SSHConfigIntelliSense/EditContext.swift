//
//  EditContext.swift
//  SSHConfigIntelliSense
//
//  The first half of "what should I suggest here?": given the full document and a
//  UTF-16 cursor offset, classify the cursor as sitting on a keyword, on a value for
//  some keyword, or somewhere we stay quiet (a comment).
//
//  ssh_config's per-line grammar is tiny — `Keyword[=| ]value [value …]` — so this
//  is a deliberate single-line scan rather than a parser. It only looks at the text
//  *before* the cursor on the current line; the token it reports as replaceable runs
//  from the token's start to the cursor, which is the splice point a completion needs.
//

import Foundation

/// What the cursor is positioned to complete.
public enum CompletionTarget: Equatable, Sendable {
    /// Typing a directive name. `prefix` is what's typed so far (may be empty).
    case keyword(prefix: String, replace: ReplacementRange)
    /// Typing a value for `keyword`. `valueTokenIndex` is the 0-based position among
    /// the line's whitespace-separated values (0 = first value).
    case value(keyword: String, prefix: String, replace: ReplacementRange, valueTokenIndex: Int)
    /// A comment, or a place with nothing to offer.
    case none
}

public struct EditContext: Equatable, Sendable {
    public let target: CompletionTarget

    /// Characters that end a value token (so completion replaces only the element the
    /// cursor is in). Whitespace separates values; `=` separates key from value and
    /// `,` separates algorithm-list elements.
    private static let valueBreakers: Set<Character> = [" ", "\t", "=", ","]
    private static let whitespace: Set<Character> = [" ", "\t"]

    public static func analyze(text: String, utf16Offset: Int) -> EditContext {
        let count16 = text.utf16.count
        let off = max(0, min(utf16Offset, count16))
        let cursor = String.Index(utf16Offset: off, in: text)

        // Start of the current logical line (char after the previous newline).
        var lineStart = cursor
        while lineStart > text.startIndex {
            let prev = text.index(before: lineStart)
            if text[prev] == "\n" { break }
            lineStart = prev
        }

        let line = text[lineStart..<cursor]

        // Skip leading indentation; a `#` there means we're inside a comment.
        var contentStart = line.startIndex
        while contentStart < line.endIndex, whitespace.contains(line[contentStart]) {
            contentStart = line.index(after: contentStart)
        }
        if contentStart < line.endIndex, line[contentStart] == "#" {
            return EditContext(target: .none)
        }

        // The keyword token: from content start up to whitespace or `=`.
        var keywordEnd = contentStart
        while keywordEnd < line.endIndex,
            line[keywordEnd] != "=", !whitespace.contains(line[keywordEnd])
        {
            keywordEnd = line.index(after: keywordEnd)
        }

        // No separator yet between the keyword and the cursor → still naming the keyword.
        if keywordEnd == line.endIndex {
            let prefix = String(line[contentStart..<keywordEnd])
            let loc = contentStart.utf16Offset(in: text)
            let replace = ReplacementRange(location: loc, length: off - loc)
            return EditContext(target: .keyword(prefix: prefix, replace: replace))
        }

        let keyword = String(line[contentStart..<keywordEnd])

        // We're past the keyword: find the value element the cursor is inside, i.e. the
        // run of non-breaker characters immediately before the cursor.
        var elementStart = cursor
        while elementStart > line.startIndex {
            let prev = line.index(before: elementStart)
            if valueBreakers.contains(line[prev]) { break }
            elementStart = prev
        }

        let prefix = String(line[elementStart..<cursor])
        let loc = elementStart.utf16Offset(in: text)
        let replace = ReplacementRange(location: loc, length: off - loc)

        // Count whole value tokens before the one being typed. Everything after the
        // keyword (and its optional `=`) up to the element start, split on whitespace.
        let valuesRegion = line[keywordEnd..<elementStart]
        let tokenIndex = valuesRegion.split(whereSeparator: { whitespace.contains($0) || $0 == "=" }).count

        return EditContext(
            target: .value(
                keyword: keyword, prefix: prefix,
                replace: replace, valueTokenIndex: tokenIndex))
    }

    init(target: CompletionTarget) { self.target = target }
}
