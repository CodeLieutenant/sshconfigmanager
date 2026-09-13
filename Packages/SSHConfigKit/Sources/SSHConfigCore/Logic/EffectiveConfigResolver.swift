//
//  EffectiveConfigResolver.swift
//  sshconfigmanager
//
//  Computes the settings ssh will actually use for a given destination, applying
//  Host/Match precedence and first-obtained-value-wins, the way ssh_config does.
//

import Foundation

/// One resolved setting and where it came from.
public struct ResolvedSetting: Equatable, Identifiable {
    public let keyword: String
    public let value: String
    /// Human-readable origin, e.g. "Host bastion" or "global (config)".
    public let source: String

    /// Stable identity derived from the content, so re-resolving the same
    /// destination yields the same ids — a `ForEach` over resolved settings then
    /// diffs in place instead of rebuilding every row on each recompute. (A fresh
    /// `UUID()` per instance defeated that.)
    public var id: String { "\(keyword)\u{1}\(value)\u{1}\(source)" }

    public static func == (lhs: ResolvedSetting, rhs: ResolvedSetting) -> Bool {
        lhs.keyword == rhs.keyword && lhs.value == rhs.value && lhs.source == rhs.source
    }
}

extension Sequence where Element == ResolvedSetting {
    /// The first value for a keyword (case-insensitive). Mirrors
    /// `HostBlock.firstValue(for:)` so resolved-setting call sites read the same.
    public func firstValue(of keyword: String) -> String? {
        let target = keyword.lowercased()
        return first { $0.keyword.lowercased() == target }?.value
    }

    /// Every value for a keyword (case-insensitive), in order — e.g. repeated
    /// `IdentityFile` / `LocalForward` lines.
    public func values(of keyword: String) -> [String] {
        let target = keyword.lowercased()
        return filter { $0.keyword.lowercased() == target }.map(\.value)
    }
}

public enum EffectiveConfigResolver {
    /// Resolves the effective configuration for `target` across a *flat* document
    /// list (the main config first, then included files, in load order), processing
    /// each document in sequence.
    ///
    /// ssh uses the *first* obtained value for each keyword, except keywords that
    /// accumulate (e.g. IdentityFile), which collect every match in order.
    ///
    /// - Important: This overload appends included files *after* the entire main
    ///   document, so an `Include` directive's position relative to the main file's
    ///   own `Host`/`Match` blocks is lost. When that position matters (it does
    ///   whenever an `Include` near the top should outrank a later block in the same
    ///   file), use ``resolve(target:in:)`` with a ``ConfigGraph`` instead — it
    ///   splices each include inline at its directive, the single linearized
    ///   directive stream real ssh reads.
    public static func resolve(target: String, in documents: [SSHConfigDocument]) -> [ResolvedSetting] {
        var result: [ResolvedSetting] = []
        var seen: Set<String> = []

        for document in documents {
            // Directives before the first Host/Match apply globally (highest priority
            // when they sit at the top of the file).
            consider(
                document.preamble.compactMap(\.directive),
                source: "global (\(document.displayName))", result: &result, seen: &seen)
            for block in document.blocks where matches(block, target: target) {
                consider(
                    block.body.compactMap(\.directive),
                    source: sourceLabel(for: block), result: &result, seen: &seen)
            }
        }
        return result
    }

    /// Resolves the effective configuration for `target` over a ``ConfigGraph``,
    /// walking the main config top-to-bottom and splicing each included file inline
    /// at the position of its `Include` directive before continuing — the single
    /// ordered directive stream real ssh builds. First-obtained value wins; repeatable
    /// keywords (e.g. `IdentityFile`) accumulate in stream order.
    ///
    /// Because includes expand in place, an `Include` near the top of the main file
    /// makes the included file's values outrank a *later* `Host *` (or other matching
    /// block) in that same file — matching `ssh -G`, unlike the flat overload.
    public static func resolve(target: String, in graph: ConfigGraph) -> [ResolvedSetting] {
        var result: [ResolvedSetting] = []
        var seen: Set<String> = []
        var visitedDocs: Set<UUID> = []

        func walk(_ document: SSHConfigDocument) {
            // Guard against include cycles. A file already spliced earlier in the
            // stream has already contributed its (first-wins) values, so re-walking
            // would be a no-op anyway.
            guard visitedDocs.insert(document.id).inserted else { return }
            considerWithIncludes(document.preamble, source: "global (\(document.displayName))")
            for block in document.blocks where matches(block, target: target) {
                considerWithIncludes(block.body, source: sourceLabel(for: block))
            }
        }

        // Walks a run of lines in order, recursing into an included file the moment
        // an `Include` directive is reached so its directives land at that position.
        func considerWithIncludes(_ lines: [ConfigLine], source: String) {
            for line in lines {
                guard let directive = line.directive else { continue }
                if directive.canonicalKeyword == "include" {
                    for included in graph.inclusions[directive.id] ?? [] { walk(included) }
                } else {
                    consider([directive], source: source, result: &result, seen: &seen)
                }
            }
        }

        if let root = graph.root { walk(root) }
        return result
    }

    /// Applies first-wins / repeatable-accumulate over `directives`, skipping the
    /// structural `host`/`match`/`include` keywords. Shared by both resolve overloads.
    private static func consider(
        _ directives: [Directive], source: String,
        result: inout [ResolvedSetting], seen: inout Set<String>
    ) {
        for directive in directives {
            let key = directive.canonicalKeyword
            if key == "host" || key == "match" || key == "include" { continue }
            // Path values are unquoted here so every consumer of a resolved setting —
            // the tunnel engine resolving an `IdentityAgent` socket, the sandbox-grant
            // prompt, the explicit-command builder — sees the bare path, not the
            // quotes ssh_config uses to carry spaces. The `\r` drop is belt-and-braces
            // since the parser stopped gluing it to the value: a `\r` past the closing
            // quote would defeat the unquote. Other values pass through verbatim.
            let value: String
            if KeywordRegistry.isPath(key) {
                let noCR =
                    directive.value.hasSuffix("\r")
                    ? String(directive.value.dropLast()) : directive.value
                value = SSHValueQuoting.unquoted(noCR)
            } else {
                value = directive.value
            }
            if KeywordRegistry.isRepeatable(key) {
                result.append(
                    ResolvedSetting(
                        keyword: directive.keyword,
                        value: value, source: source))
            } else if !seen.contains(key) {
                seen.insert(key)
                result.append(
                    ResolvedSetting(
                        keyword: directive.keyword,
                        value: value, source: source))
            }
        }
    }

    private static func sourceLabel(for block: HostBlock) -> String {
        "\(block.kind.noun) \(block.kind == .host ? block.title : block.patterns.joined(separator: " "))"
    }

    /// Whether a block applies to `target`.
    public static func matches(_ block: HostBlock, target: String) -> Bool {
        switch block.kind {
        case .host:
            return matchesHostPatterns(block.patterns, target: target)
        case .match:
            return matchesCriteria(block.patterns, target: target)
        }
    }

    /// Host-line pattern matching: matches if at least one positive pattern matches
    /// and no negated pattern matches. A negation-only list never matches any host
    /// (OpenSSH 9.x behaviour — such a block is effectively a no-op).
    ///
    /// Case-insensitive, because ssh_config is: OpenSSH's `match_hostname` lowercases
    /// the host and passes `dolower = 1` to `match_pattern_list`, so `Host Prod-DB`
    /// applies to `ssh prod-db` and vice versa. Matching case-sensitively meant a
    /// differently-cased alias resolved to *no settings at all* — the effective-config
    /// view and the "what ssh will do" preview showed nothing, and worse,
    /// `TunnelJumpChain` built the hop with a default user, port 22 and no identity
    /// instead of the block's real values. `KnownHostsVerifier` already case-folds at
    /// this same layer (audit #35).
    ///
    /// Folded here, not inside `fnmatchPattern`, which stays an exact glob.
    public static func matchesHostPatterns(_ patterns: [String], target: String) -> Bool {
        let target = target.lowercased()
        var matchedPositive = false
        var hasPositive = false
        for pattern in patterns {
            let pattern = pattern.lowercased()
            if let negated = pattern.dropFirstIfPrefix("!") {
                if fnmatchPattern(negated, target) { return false }
            } else {
                hasPositive = true
                if fnmatchPattern(pattern, target) { matchedPositive = true }
            }
        }
        return hasPositive && matchedPositive
    }

    /// Match-block criteria. Supports `all` and `host <patterns>`; other criteria
    /// (user, exec, etc.) cannot be evaluated statically, so the block is skipped.
    public static func matchesCriteria(_ tokens: [String], target: String) -> Bool {
        var index = 0
        while index < tokens.count {
            let token = tokens[index].lowercased()
            switch token {
            case "all":
                return true
            case "host":
                index += 1
                guard index < tokens.count else { return false }
                let patterns = tokens[index].split(separator: ",").map(String.init)
                if !matchesHostPatterns(patterns, target: target) { return false }
            case "canonical", "final":
                break // ignore these conditionals
            default:
                return false // user/exec/localuser/etc. — can't evaluate
            }
            index += 1
        }
        return true
    }

    private static func fnmatchPattern(_ pattern: String, _ string: String) -> Bool {
        pattern.withCString { patternC in
            string.withCString { stringC in
                fnmatch(patternC, stringC, 0) == 0
            }
        }
    }
}

extension String {
    /// Returns the remainder after `prefix` if present, else nil.
    fileprivate func dropFirstIfPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
