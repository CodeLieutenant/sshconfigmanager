//
//  DocumentSymbols.swift
//  SSHConfigIntelliSense
//
//  The dynamic, document-derived facts that make value completion context-aware:
//  the Host aliases defined elsewhere in the file (so `ProxyJump <tab>` offers the
//  bastions you've actually declared) and the Tag names in scope.
//
//  Intentionally a tolerant line scan, not the real parser: the buffer being edited
//  is frequently mid-keystroke and syntactically invalid, and a single concrete host
//  with no wildcard is all a jump target needs.
//

import Foundation

public struct DocumentSymbols: Equatable, Sendable {
    /// Concrete `Host` aliases (wildcards / negations excluded), first-seen order,
    /// de-duplicated. These are the legitimate `ProxyJump` / `Match host` targets.
    public let hostAliases: [String]
    /// `Tag` values declared in the file, for `Match tagged …` completion.
    public let tags: [String]

    public init(hostAliases: [String], tags: [String]) {
        self.hostAliases = hostAliases
        self.tags = tags
    }

    public static let empty = DocumentSymbols(hostAliases: [], tags: [])

    public static func extract(from text: String) -> DocumentSymbols {
        var aliases: [String] = []
        var seenAliases = Set<String>()
        var tags: [String] = []
        var seenTags = Set<String>()

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.drop { $0 == " " || $0 == "\t" }
            guard let first = line.first, first != "#" else { continue }

            // keyword = leading run up to whitespace or '='.
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let keyword = tokens.first else { continue }
            let key = keyword.lowercased()

            if key == "host" {
                for pattern in tokens.dropFirst() {
                    let p = String(pattern)
                    guard !p.contains("*"), !p.contains("?"), !p.hasPrefix("!") else { continue }
                    if seenAliases.insert(p).inserted { aliases.append(p) }
                }
            } else if key == "tag", let value = tokens.dropFirst().first {
                let t = String(value)
                if seenTags.insert(t).inserted { tags.append(t) }
            }
        }

        return DocumentSymbols(hostAliases: aliases, tags: tags)
    }
}
