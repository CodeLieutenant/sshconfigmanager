//
//  HostBlock.swift
//  sshconfigmanager
//
//  A `Host` or `Match` block: a header line plus the directives beneath it.
//

import Foundation

/// A `Host`/`Match` block and everything that belongs to it.
///
/// `leading` holds comment lines that sit directly above the header (e.g. a label
/// comment) so they travel with the block when it is moved or deleted. `body`
/// holds the directives, comments, and blank lines under the header up to the next
/// `Host`/`Match`.
public struct HostBlock: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case host, match

        /// The model-level noun for this block kind (header title, labels).
        public var noun: String { self == .host ? "Host" : "Match" }

        /// The title shown when a block has no patterns yet.
        public var emptyTitle: String { self == .host ? "(unnamed host)" : "Match" }
    }

    public let id: UUID
    public var kind: Kind
    /// Comment lines immediately preceding the header (no blank line between).
    public var leading: [ConfigLine]
    /// The `Host ...` / `Match ...` line itself.
    public var header: Directive
    /// Lines under the header, in order.
    public var body: [ConfigLine]
    /// The file this block lives in (the main config or an included file).
    public var sourceURL: URL

    public init(
        id: UUID = UUID(),
        kind: Kind,
        leading: [ConfigLine] = [],
        header: Directive,
        body: [ConfigLine] = [],
        sourceURL: URL
    ) {
        self.id = id
        self.kind = kind
        self.leading = leading
        self.header = header
        self.body = body
        self.sourceURL = sourceURL
    }

    /// The host patterns (for `.host`) or match criteria tokens (for `.match`),
    /// split on whitespace, honoring double quotes the way ssh_config does — so
    /// `Host "my server" web` yields `["my server", "web"]` rather than splitting
    /// the quoted name and leaking quote characters into aliases.
    public var patterns: [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var sawToken = false
        // `SSHConfigParser.parseLine` keeps a CRLF file's `\r` in `trailingText`, not in
        // the value, so this is belt-and-braces for a `Directive` built by hand: no
        // consumer may ever see a `\r` glued onto the last pattern (audit #27).
        let value = header.value.hasSuffix("\r") ? String(header.value.dropLast()) : header.value
        for character in value {
            if character == "\"" {
                inQuotes.toggle()
                sawToken = true
            } else if character == " " || character == "\t", !inQuotes {
                if sawToken {
                    tokens.append(current)
                    current = ""
                    sawToken = false
                }
            } else {
                current.append(character)
                sawToken = true
            }
        }
        if sawToken { tokens.append(current) }
        return tokens
    }

    /// A human-readable title for the sidebar.
    public var title: String {
        let patterns = self.patterns
        if patterns.isEmpty { return kind.emptyTitle }
        return patterns.joined(separator: ", ")
    }

    /// `true` if this block is a wildcard `Host *` (global defaults) block.
    public var isWildcard: Bool {
        kind == .host && patterns.allSatisfy { $0 == "*" } && !patterns.isEmpty
    }

    /// Whether a pattern is a concrete alias rather than a glob (`*`/`?`). The one
    /// definition of "a usable alias" — don't re-spell this test at call sites.
    /// `nonisolated` so it's passable as a plain predicate to `first(where:)` /
    /// `filter` under the target's default main-actor isolation.
    public nonisolated static func isConcreteAlias(_ pattern: String) -> Bool {
        !pattern.contains("*") && !pattern.contains("?")
    }

    /// The first concrete (non-pattern) alias — the destination a real `ssh`
    /// invocation resolves against. `nil` for a pure-wildcard or `Match` block.
    public var primaryAlias: String? { patterns.first(where: Self.isConcreteAlias) }

    /// Every concrete (non-glob) alias this block defines.
    public var concreteAliases: [String] { patterns.filter(Self.isConcreteAlias) }

    /// The host and port to probe for a reachability test: HostName if set, else
    /// the first concrete alias; Port if set, else 22. Nil if nothing usable.
    public var connectionTarget: (host: String, port: Int)? {
        let host = firstValue(for: "HostName") ?? primaryAlias
        guard let host, !host.isEmpty else { return nil }
        let port = firstValue(for: "Port").flatMap(Int.init) ?? 22
        return (host, port)
    }

    // MARK: - Directive access

    /// All directives in the body matching the given keyword (case-insensitive).
    public func directives(for keyword: String) -> [Directive] {
        let target = keyword.lowercased()
        return body.compactMap { $0.directive }.filter { $0.canonicalKeyword == target }
    }

    /// The first value for a keyword, if present.
    public func firstValue(for keyword: String) -> String? {
        directives(for: keyword).first.map { Self.semanticValue($0.value, keyword: keyword) }
    }

    /// All values for a keyword (e.g. multiple `IdentityFile` lines).
    public func values(for keyword: String) -> [String] {
        directives(for: keyword).map { Self.semanticValue($0.value, keyword: keyword) }
    }

    /// The "what ssh actually sees" form of a stored directive value: for `.path`
    /// keywords, a surrounding pair of double quotes stripped (so
    /// `IdentityAgent "~/…/agent.sock"` resolves and displays as the bare path).
    /// The stored `Directive.value` is left verbatim for lossless round-tripping;
    /// quoting is re-applied on write by `setValue`.
    private static func semanticValue(_ value: String, keyword: String) -> String {
        let stripped = stripTrailingCR(value)
        return KeywordRegistry.isPath(keyword) ? SSHValueQuoting.unquoted(stripped) : stripped
    }

    /// Belt-and-braces `\r` strip. `SSHConfigParser.parseLine` now carries a CRLF
    /// file's carriage return in `trailingText` instead of gluing it to the value, so
    /// this is a no-op for anything the parser produced — it still guards a
    /// `Directive` built by hand (audit #27).
    private static func stripTrailingCR(_ value: String) -> String {
        value.hasSuffix("\r") ? String(value.dropLast()) : value
    }

    /// The indentation to use when inserting a new directive: reuses the indent of
    /// an existing body directive, otherwise two spaces.
    public var bodyIndent: String {
        for line in body {
            if let directive = line.directive { return directive.leadingIndent }
        }
        return "    "
    }

    /// The line terminator this block's existing lines already use — `"\r"` in a CRLF
    /// file, `""` otherwise — to be carried in a newly inserted directive's
    /// `trailingText`. Without it, adding one directive to a CRLF config wrote a
    /// single LF-terminated line into an otherwise CRLF file.
    ///
    /// An *edited* directive needs no such lookup: `setValue` replaces only `value`,
    /// so the terminator the parser put in `trailingText` survives untouched.
    public var lineEndingSuffix: String {
        let lines = [header.rendered] + body.map(\.rendered) + leading.map(\.rendered)
        return lines.contains { $0.hasSuffix("\r") } ? "\r" : ""
    }

    // MARK: - Mutation

    /// Sets the single value for a keyword. Updates the first matching directive,
    /// inserts a new one if none exists, or removes all matches when `value` is nil/empty.
    public mutating func setValue(_ value: String?, for keyword: String) {
        // The editor hands us the bare, unquoted value (that's what `firstValue`
        // showed). A `.path` value containing spaces must be re-quoted so the file
        // stays valid ssh_config — e.g. a 1Password agent socket under "Group
        // Containers". Non-path values (and whitespace-free paths) are stored as-is.
        let cleaned = value?.trimmingCharacters(in: .whitespaces)
        let trimmed = cleaned.map {
            KeywordRegistry.isPath(keyword) ? SSHValueQuoting.quotedIfNeeded($0) : $0
        }
        let target = keyword.lowercased()

        if let trimmed, !trimmed.isEmpty {
            if let index = body.firstIndex(where: { $0.directive?.canonicalKeyword == target }) {
                if var directive = body[index].directive {
                    directive.value = trimmed
                    directive.isDirty = true
                    body[index] = .directive(directive)
                }
            } else {
                let directive = Directive(
                    leadingIndent: bodyIndent,
                    keyword: keyword,
                    value: trimmed,
                    trailingText: lineEndingSuffix,
                    isDirty: true
                )
                body.append(.directive(directive))
            }
        } else {
            body.removeAll { $0.directive?.canonicalKeyword == target }
        }
    }

    /// Appends a new directive to the body.
    public mutating func addDirective(keyword: String, value: String) {
        let directive = Directive(
            leadingIndent: bodyIndent,
            keyword: keyword,
            value: value,
            trailingText: lineEndingSuffix,
            isDirty: true
        )
        body.append(.directive(directive))
    }

    /// Removes a body line by id.
    public mutating func removeLine(id: UUID) {
        body.removeAll { $0.id == id }
    }

    /// A copy whose every line is terminated with `lineEnding`, for a block built in
    /// memory (a new host, a template, an imported block, a clone) that is about to be
    /// appended to a file using a different terminator.
    ///
    /// A line already ending correctly is returned untouched — including its `rawText`
    /// and `isDirty` — so appending an unedited block to a file it already matches stays
    /// byte-exact. Only a line that has to change is marked dirty and re-rendered.
    public func adoptingLineEnding(_ lineEnding: String) -> HostBlock {
        /// Re-terminates one line's tail: drop whatever `\r` it has, then apply the one
        /// we want. Symmetric on purpose — moving a CRLF block into an LF file has to
        /// *strip* the carriage return just as surely as the reverse has to add it.
        func reterminated(_ tail: String) -> String {
            (tail.hasSuffix("\r") ? String(tail.dropLast()) : tail) + lineEnding
        }
        func fixed(_ directive: Directive) -> Directive {
            let wanted = reterminated(directive.trailingText)
            guard wanted != directive.trailingText else { return directive }
            var copy = directive
            copy.trailingText = wanted
            copy.isDirty = true // re-render from fields; `rawText` is now stale
            return copy
        }
        func fixed(_ line: ConfigLine) -> ConfigLine {
            switch line {
            case .blank(let id, let raw):
                let wanted = reterminated(raw)
                return wanted == raw ? line : .blank(id: id, raw: wanted)
            case .comment(let id, let raw):
                let wanted = reterminated(raw)
                return wanted == raw ? line : .comment(id: id, raw: wanted)
            case .directive(let directive):
                return .directive(fixed(directive))
            }
        }
        var copy = self
        copy.leading = leading.map(fixed)
        copy.header = fixed(header)
        copy.body = body.map(fixed)
        return copy
    }

    // MARK: - Cloning

    /// A faithful clone with a brand-new block `id` and fresh ids on every copied
    /// line and directive, so the clone shares no identity with the source — per-line
    /// edits and removals on one never touch the other. Text (`rawText`/`isDirty`,
    /// indentation, the `leading` label comment) is preserved verbatim, so the clone
    /// serializes byte-for-byte like the source until its header alias is renamed.
    public func deepCopyWithFreshIDs() -> HostBlock {
        HostBlock(
            kind: kind,
            leading: leading.map { $0.withFreshID() },
            header: header.withFreshID(),
            body: body.map { $0.withFreshID() },
            sourceURL: sourceURL
        )
    }
}
