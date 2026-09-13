//
//  HostNaming.swift
//  SSHConfigCore
//
//  Pure naming rules for cloning a host. Two jobs, both I/O-free and testable:
//  derive a fresh, collision-free alias, and splice that alias into a header value
//  without disturbing the rest of it (extra patterns, exact spacing). Kept separate
//  from `ConfigStore` so the rules are unit-tested in isolation and reusable by any
//  flow that needs a unique alias.
//

import Foundation

public nonisolated enum HostNaming {
    /// A unique alias derived from `base`, avoiding every name in `existing`:
    ///
    /// - `web`          → `web-copy`     (then `web-copy-2`, `web-copy-3`, …)
    /// - `web-copy`     → `web-copy-2`   (an existing `-copy` increments, never stacks
    ///                                    into `web-copy-copy`)
    /// - `web-2`        → `web-3`        (a user's own `-N` numbering is preserved)
    ///
    /// Always returns a name not present in `existing`.
    public static func duplicateName(for base: String, existing: Set<String>) -> String {
        // Already a clone (`web-copy` / `web-copy-3`) → stay in the `-copy[-N]` family.
        if let root = copyRoot(base) {
            return firstFree(prefix: "\(root)-copy", existing: existing)
        }
        // A user's own `-N` numbering → keep numbering: `web-2` → `web-3`.
        if let (stem, _) = splitTrailingNumber(base) {
            return firstFreeNumber(stem: stem, existing: existing)
        }
        // A plain name → start the `-copy` family.
        return firstFree(prefix: "\(base)-copy", existing: existing)
    }

    /// Rewrites a `Host` header *value*, renaming only its first concrete alias to
    /// `newAlias` and preserving the rest verbatim — extra patterns and the exact
    /// whitespace between them. Falls back to the first token when no concrete alias
    /// exists, or returns `newAlias` for an empty header.
    ///
    /// Quote-aware, matching `HostBlock.patterns`: a double-quoted, space-containing
    /// alias (`Host "my server" web`) is one token, so the whole quoted span is
    /// replaced, and a replacement alias that itself contains whitespace is re-quoted.
    /// A whitespace-blind rename would replace only the `"my` fragment and strand the
    /// closing quote, writing a corrupt header to `~/.ssh/config`. (Audit CFG-1.)
    /// A trailing `\r` is split off first and re-appended. `SSHConfigParser` now keeps
    /// a CRLF file's carriage return in `trailingText` rather than in the header value,
    /// so this shouldn't arrive here — but when it did, `tokenRanges` (which separates
    /// on space/tab only) folded the `\r` into the single token `"web\r"` and replacing
    /// that token destroyed it, writing an LF-only `Host` line into a CRLF file. A
    /// multi-pattern header kept its `\r` purely because only the *first* token was
    /// replaced, which is what marked this as an oversight rather than a decision.
    public static func renamingFirstAlias(in headerValue: String, to newAlias: String) -> String {
        let hasCR = headerValue.hasSuffix("\r")
        let value = hasCR ? String(headerValue.dropLast()) : headerValue
        let suffix = hasCR ? "\r" : ""

        let tokens = tokenRanges(in: value)
        guard !tokens.isEmpty else { return newAlias + suffix }
        let target = tokens.first { HostBlock.isConcreteAlias(unquoted(String(value[$0]))) } ?? tokens[0]
        var result = value
        result.replaceSubrange(target, with: quotedIfNeeded(newAlias))
        return result + suffix
    }

    // MARK: - Helpers

    /// `prefix` if free, otherwise `prefix-2`, `prefix-3`, … — the first not in
    /// `existing`. Drives the `-copy` family (`prefix == "<name>-copy"`).
    private static func firstFree(prefix: String, existing: Set<String>) -> String {
        if !existing.contains(prefix) { return prefix }
        var n = 2
        while existing.contains("\(prefix)-\(n)") { n += 1 }
        return "\(prefix)-\(n)"
    }

    /// The first free `stem-N` with `N >= 2` — drives the plain numbered family
    /// (`web-2` → `web-3`), skipping any taken numbers.
    private static func firstFreeNumber(stem: String, existing: Set<String>) -> String {
        var n = 2
        while existing.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }

    /// The family root of a clone name, or `nil` if `value` isn't one: `web-copy` and
    /// `web-copy-3` both yield `web`. Strips an optional trailing `-N`, then requires
    /// a `-copy` suffix with a non-empty root.
    private static func copyRoot(_ value: String) -> String? {
        var trimmed = value
        if let (stem, _) = splitTrailingNumber(trimmed) { trimmed = stem }
        guard trimmed.hasSuffix("-copy") else { return nil }
        let root = String(trimmed.dropLast("-copy".count))
        return root.isEmpty ? nil : root
    }

    /// Splits a trailing `-N` numeric suffix: `web-2` → `("web", 2)`. Returns `nil`
    /// when there is no such suffix (`web`, `web-copy`) or no stem before it (`-2`).
    private static func splitTrailingNumber(_ value: String) -> (stem: String, number: Int)? {
        guard let dash = value.lastIndex(of: "-") else { return nil }
        let suffix = value[value.index(after: dash)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber),
            let number = Int(suffix)
        else { return nil }
        let stem = String(value[..<dash])
        guard !stem.isEmpty else { return nil }
        return (stem, number)
    }

    /// The ranges of whitespace-delimited tokens in `value`, preserving the gaps so a
    /// single-token replacement leaves all surrounding spacing intact. Double quotes are
    /// honored the way `HostBlock.patterns` does, so a quoted span with internal
    /// whitespace (`"my server"`) is a single token whose range spans the quotes.
    private static func tokenRanges(in value: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = value.startIndex
        while index < value.endIndex {
            // Skip unquoted whitespace between tokens.
            while index < value.endIndex, value[index] == " " || value[index] == "\t" {
                index = value.index(after: index)
            }
            guard index < value.endIndex else { break }
            let start = index
            var inQuotes = false
            while index < value.endIndex {
                let character = value[index]
                if character == "\"" {
                    inQuotes.toggle()
                } else if character == " " || character == "\t", !inQuotes {
                    break
                }
                index = value.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    /// Strips a single pair of surrounding double quotes, so the concrete-alias test
    /// sees `my server` rather than `"my server"`.
    private static func unquoted(_ token: String) -> String {
        guard token.count >= 2, token.hasPrefix("\""), token.hasSuffix("\"") else { return token }
        return String(token.dropFirst().dropLast())
    }

    /// Wraps `alias` in double quotes when it contains whitespace (so ssh reads it as a
    /// single pattern), leaving ordinary aliases untouched.
    private static func quotedIfNeeded(_ alias: String) -> String {
        (alias.contains(" ") || alias.contains("\t")) ? "\"\(alias)\"" : alias
    }
}
