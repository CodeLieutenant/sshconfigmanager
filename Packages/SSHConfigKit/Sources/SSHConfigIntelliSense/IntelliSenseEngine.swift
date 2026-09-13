//
//  IntelliSenseEngine.swift
//  SSHConfigIntelliSense
//
//  The public face of the module: hand it the document text and a UTF-16 cursor
//  offset, get back a ranked list of `CompletionItem`s (and, separately, hover docs).
//  It composes the pure pieces — `EditContext` (where am I?), `ValueCatalog`
//  (what's legal here?), `DocumentSymbols` (what does *this* file define?), and
//  `PathCompletion` (what files are on disk?) — and ranks with the app's existing
//  `FuzzyMatch` so behaviour matches the command palette the user already knows.
//
//  No state, no I/O, no actor isolation: a `let engine = IntelliSenseEngine()` is
//  cheap to keep around and safe to call from anywhere. Filesystem completion is the
//  one thing the engine can't do alone, so it enters through an injected, optional
//  `FileSystemBrowsing` provider — omit it (the default) and behaviour is unchanged.
//

import Foundation
import SSHConfigCore

public struct IntelliSenseEngine: Sendable {
    public init() {}

    /// Directives that can open a block; offered as keywords even though they aren't
    /// in `KeywordRegistry` (which only describes in-block settings).
    private static let blockKeywords: [(canonical: String, help: String)] = [
        ("Host", "Begin a host block. Settings until the next Host/Match apply to hosts matching these patterns."),
        ("Match", "Begin a conditional block, e.g. `Match host *.internal user admin`."),
    ]

    /// Multi-token templates for the directives that are fiddly to type from memory.
    /// Offered alongside the bare keyword (distinct labels, `.snippet` kind) so the
    /// user can drop in a ready-to-edit skeleton — VS Code / JetBrains style.
    private static let snippets: [(label: String, insert: String, help: String)] = [
        (
            "LocalForward — local port forward",
            "LocalForward 127.0.0.1:8080 example.com:80",
            "Forward a local port to a host reachable from the server (`-L`)."
        ),
        (
            "RemoteForward — remote port forward",
            "RemoteForward 127.0.0.1:8080 example.com:80",
            "Forward a port on the server back to a local address (`-R`)."
        ),
        (
            "DynamicForward — SOCKS proxy",
            "DynamicForward 127.0.0.1:1080",
            "Open a local SOCKS proxy that routes through the connection (`-D`)."
        ),
        (
            "Match — conditional block",
            "Match host example.com",
            "Begin a conditional block matched on host, user, exec result, etc."
        ),
    ]

    // MARK: - Completion

    /// Ranked completions at `utf16CursorOffset`. Pass a `fileSystem` to enable
    /// file-path completion for path-typed keywords (IdentityFile, …); omit it and
    /// those keywords simply offer nothing, as before.
    public func completions(
        in text: String, utf16CursorOffset: Int, limit: Int = 60,
        fileSystem: FileSystemBrowsing? = nil
    ) -> [CompletionItem] {
        let context = EditContext.analyze(text: text, utf16Offset: utf16CursorOffset)
        switch context.target {
        case .none:
            return []
        case .keyword(let prefix, let replace):
            return keywordCompletions(prefix: prefix, replace: replace, limit: limit)
        case .value(let keyword, let prefix, let replace, let tokenIndex):
            return valueCompletions(
                keyword: keyword, prefix: prefix, replace: replace,
                tokenIndex: tokenIndex, text: text, limit: limit,
                fileSystem: fileSystem)
        }
    }

    private func keywordCompletions(prefix: String, replace: ReplacementRange, limit: Int) -> [CompletionItem] {
        // A keyword on a fresh line replaces nothing useful until the user commits to
        // one, so only volunteer suggestions once they've typed a character. (The UI
        // can still force an empty-prefix list on an explicit trigger if it wants.)
        guard !prefix.isEmpty else { return [] }

        var items: [CompletionItem] = []

        for block in Self.blockKeywords {
            if let item = makeItem(
                label: block.canonical, insertText: block.canonical + " ",
                detail: "block", documentation: block.help, kind: .keyword,
                replace: replace, matchPrefix: prefix, scoreBias: 2)
            {
                items.append(item) // nudge structural directives up
            }
        }

        for info in KeywordRegistry.all {
            if let item = makeItem(
                label: info.canonical, insertText: info.canonical + " ",
                detail: info.category.rawValue, documentation: info.help,
                kind: .keyword, replace: replace, matchPrefix: prefix, scoreBias: 0)
            {
                items.append(item)
            }
        }

        for snippet in Self.snippets {
            if let item = makeItem(
                label: snippet.label, insertText: snippet.insert,
                detail: "snippet", documentation: snippet.help, kind: .snippet,
                replace: replace, matchPrefix: prefix, scoreBias: 0)
            {
                items.append(item)
            }
        }

        return rank(items, limit: limit)
    }

    private func valueCompletions(
        keyword: String, prefix: String, replace: ReplacementRange,
        tokenIndex: Int, text: String, limit: Int,
        fileSystem: FileSystemBrowsing?
    ) -> [CompletionItem] {
        // File-path keywords complete against the filesystem (when a provider is given).
        // IdentityAgent is special: it's a socket path *and* accepts env/none tokens, so
        // only switch to path mode once the value starts looking like a path.
        if let fileSystem, ValueCatalog.isPathKeyword(keyword) {
            let isIdentityAgent = keyword.lowercased() == "identityagent"
            if !(isIdentityAgent && !Self.looksLikePath(prefix)) {
                return pathCompletions(
                    prefix: prefix, replace: replace,
                    fileSystem: fileSystem, limit: limit)
            }
        }

        let symbols = DocumentSymbols.extract(from: text)
        let candidates = ValueCatalog.candidates(forKeyword: keyword, symbols: symbols)
        guard !candidates.isEmpty else { return [] }

        // Algorithm lists accept a leading +/-/^ on the first element to amend the
        // built-in default set; keep the operator on the line and match the rest.
        var matchPrefix = prefix
        var operatorPrefix = ""
        if tokenIndex == 0, ValueCatalog.algorithmListKeywords.contains(keyword.lowercased()),
            let first = prefix.first, first == "+" || first == "-" || first == "^"
        {
            operatorPrefix = String(first)
            matchPrefix = String(prefix.dropFirst())
        }

        // `ProxyJump` values are [user@]host[:port]; complete the host part only, so
        // `admin@ba` still finds `bastion` and replaces just `ba`.
        var effectiveReplace = replace
        if keyword.lowercased() == "proxyjump", let at = prefix.lastIndex(of: "@") {
            let consumed = prefix[...at]
            let consumedLen = consumed.utf16.count
            effectiveReplace = ReplacementRange(
                location: replace.location + consumedLen,
                length: replace.length - consumedLen)
            matchPrefix = String(prefix[prefix.index(after: at)...])
            operatorPrefix = ""
        }

        var items: [CompletionItem] = []
        for candidate in candidates {
            if let item = makeItem(
                from: candidate, matchPrefix: matchPrefix,
                insertPrefix: operatorPrefix, replace: effectiveReplace, scoreBias: 0)
            {
                items.append(item)
            }
        }

        // Preserve catalog order on an empty prefix (preference order matters for
        // algorithm lists); otherwise rank by fuzzy score.
        if matchPrefix.isEmpty {
            return finalize(Array(items.prefix(limit)))
        }
        return rank(items, limit: limit)
    }

    /// Files/folders for a path-typed value. The directory portion of the value stays
    /// on the line; the accept replaces only the segment after the last "/".
    private func pathCompletions(
        prefix: String, replace: ReplacementRange,
        fileSystem: FileSystemBrowsing, limit: Int
    ) -> [CompletionItem] {
        guard let result = PathCompletion.complete(value: prefix, fileSystem: fileSystem) else { return [] }
        let effectiveReplace = ReplacementRange(
            location: replace.location + result.consumedUTF16,
            length: replace.length - result.consumedUTF16)

        var items: [CompletionItem] = []
        for candidate in result.candidates {
            if let item = makeItem(
                from: candidate, matchPrefix: result.namePrefix,
                insertPrefix: "", replace: effectiveReplace, scoreBias: 0)
            {
                items.append(item)
            }
        }

        if result.namePrefix.isEmpty {
            return finalize(Array(items.prefix(limit)))
        }
        return rank(items, limit: limit)
    }

    /// Heuristic: does this value look like a path the user is typing (vs. a bare
    /// token like `SSH_AUTH_SOCK`)? Used only to decide IdentityAgent's mode.
    private static func looksLikePath(_ value: String) -> Bool {
        value.contains("/") || value.hasPrefix("~") || value.hasPrefix(".")
    }

    // MARK: - Item construction

    /// Build a completion item, fuzzy-scoring `label` against `matchPrefix` and
    /// recording which characters matched (for IDE-style highlighting). Returns nil
    /// when the prefix is non-empty and `label` doesn't match. `insertPrefix` is
    /// prepended to the inserted text (an algorithm-list operator, say); `scoreBias`
    /// nudges ranking (structural keywords sit higher).
    private func makeItem(
        label: String, insertText: String, detail: String?,
        documentation: String?, kind: CompletionKind, replace: ReplacementRange,
        matchPrefix: String, scoreBias: Int
    ) -> CompletionItem? {
        guard let m = FuzzyMatch.match(query: matchPrefix, candidate: label) else { return nil }
        return CompletionItem(
            label: label, insertText: insertText, detail: detail,
            documentation: documentation, kind: kind, replace: replace,
            score: m.score + scoreBias,
            matchedRanges: Self.matchedRanges(in: label, charIndices: m.matchedIndices))
    }

    private func makeItem(
        from candidate: ValueCandidate, matchPrefix: String,
        insertPrefix: String, replace: ReplacementRange, scoreBias: Int
    ) -> CompletionItem? {
        makeItem(
            label: candidate.value, insertText: insertPrefix + candidate.value,
            detail: candidate.detail, documentation: candidate.documentation,
            kind: candidate.kind, replace: replace, matchPrefix: matchPrefix, scoreBias: scoreBias)
    }

    /// Map matched *character* indices (from `FuzzyMatch.match`) to UTF-16 ranges within
    /// `label`, coalescing consecutive indices into contiguous runs the UI can bold.
    static func matchedRanges(in label: String, charIndices: [Int]) -> [ReplacementRange] {
        guard !charIndices.isEmpty else { return [] }
        let chars = Array(label)
        // UTF-16 offset of each character boundary (chars.count + 1 entries).
        var offsets: [Int] = []
        offsets.reserveCapacity(chars.count + 1)
        var acc = 0
        for ch in chars {
            offsets.append(acc)
            acc += String(ch).utf16.count
        }
        offsets.append(acc)

        var ranges: [ReplacementRange] = []
        var runStart = charIndices[0]
        var prev = charIndices[0]
        func flush(endExclusive: Int) {
            guard runStart < offsets.count, endExclusive < offsets.count else { return }
            let loc = offsets[runStart]
            ranges.append(ReplacementRange(location: loc, length: offsets[endExclusive] - loc))
        }
        for idx in charIndices.dropFirst() {
            if idx == prev + 1 {
                prev = idx
                continue
            }
            flush(endExclusive: prev + 1)
            runStart = idx
            prev = idx
        }
        flush(endExclusive: prev + 1)
        return ranges
    }

    /// Sort by score desc, then alphabetically for stable ties, cap, and mark the best.
    private func rank(_ items: [CompletionItem], limit: Int) -> [CompletionItem] {
        let sorted = items.sorted {
            $0.score != $1.score
                ? $0.score > $1.score
                : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
        return finalize(sorted)
    }

    /// Flag the first item (the best match) so the popup can star/preselect it.
    private func finalize(_ items: [CompletionItem]) -> [CompletionItem] {
        guard let first = items.first else { return items }
        var out = items
        out[0] = first.preselected()
        return out
    }

    // MARK: - Hover

    /// Documentation for the keyword on the cursor's line, if it's a known directive.
    public func hover(in text: String, utf16CursorOffset: Int) -> HoverInfo? {
        // Reuse the line scan: pretend the cursor sits right after the first token.
        guard let keyword = leadingKeyword(in: text, utf16Offset: utf16CursorOffset),
            let info = KeywordRegistry.info(for: keyword.text)
        else { return nil }

        let detail: String
        switch info.field {
        case .yesNo: detail = "\(info.category.rawValue) · yes/no"
        case .integer: detail = "\(info.category.rawValue) · number"
        case .path: detail = "\(info.category.rawValue) · path"
        case .list: detail = "\(info.category.rawValue) · list"
        case .enumeration(let cases): detail = "\(info.category.rawValue) · \(cases.joined(separator: " | "))"
        case .string: detail = info.category.rawValue
        }

        return HoverInfo(
            title: info.canonical, detail: detail,
            documentation: info.help, range: keyword.range)
    }

    private func leadingKeyword(in text: String, utf16Offset: Int) -> (text: String, range: ReplacementRange)? {
        let count16 = text.utf16.count
        let off = max(0, min(utf16Offset, count16))
        let cursor = String.Index(utf16Offset: off, in: text)

        var lineStart = cursor
        while lineStart > text.startIndex {
            let prev = text.index(before: lineStart)
            if text[prev] == "\n" { break }
            lineStart = prev
        }
        var lineEnd = cursor
        while lineEnd < text.endIndex, text[lineEnd] != "\n" {
            lineEnd = text.index(after: lineEnd)
        }

        let line = text[lineStart..<lineEnd]
        var start = line.startIndex
        while start < line.endIndex, line[start] == " " || line[start] == "\t" {
            start = line.index(after: start)
        }
        guard start < line.endIndex, line[start] != "#" else { return nil }
        var end = start
        while end < line.endIndex, line[end] != " ", line[end] != "\t", line[end] != "=" {
            end = line.index(after: end)
        }
        guard end > start else { return nil }

        let loc = start.utf16Offset(in: text)
        let len = end.utf16Offset(in: text) - loc
        return (String(line[start..<end]), ReplacementRange(location: loc, length: len))
    }
}
