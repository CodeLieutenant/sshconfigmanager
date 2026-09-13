//
//  ConfigGraph.swift
//  SSHConfigCore
//
//  An ssh_config plus its includes, with each `Include` directive linked to the
//  files it expands to — enough to resolve the effective config the way real ssh
//  does, by splicing each included file inline at its `Include` directive's
//  position rather than appending whole files after the main document.
//

import Foundation

/// A main ssh_config and every file reachable through its `Include` directives,
/// retaining where each include sits in the stream.
///
/// `documents` is the same flat, load-order list used elsewhere (linting, key
/// audit): the main config first, then included files in DFS load order.
/// `inclusions` maps an `Include` directive's `id` to the documents it expanded
/// to (in order), so a resolver can recurse into an include at the exact point
/// its directive appears — the single linearized directive stream real ssh reads.
public struct ConfigGraph: Equatable {
    /// Main config first, then included files in load order.
    public let documents: [SSHConfigDocument]

    /// Each `Include` directive's `id` → the documents it expanded to, in order.
    /// A directive with no resolvable files maps to an empty array (or is absent).
    public let inclusions: [UUID: [SSHConfigDocument]]

    public init(documents: [SSHConfigDocument] = [], inclusions: [UUID: [SSHConfigDocument]] = [:]) {
        self.documents = documents
        self.inclusions = inclusions
    }

    /// The main config (the resolution entry point), if any.
    public var root: SSHConfigDocument? { documents.first }

    /// Every `Host`/`Match` block across the graph, in the linearized stream order
    /// real ssh reads: each `Include` directive's target files spliced in at the
    /// directive's position (whether that directive sits in a document's preamble
    /// or inside another block's body) rather than appended after the whole file.
    /// Used to check block ordering — e.g. whether a `Host *` block sits after
    /// every other `Host` block, the position it must hold to act as a fallback
    /// default rather than shadowing later blocks' overrides.
    public var linearizedBlocks: [HostBlock] {
        var result: [HostBlock] = []
        var visited: Set<UUID> = []

        func scanForIncludes(_ lines: [ConfigLine]) {
            for line in lines {
                guard let directive = line.directive, directive.canonicalKeyword == "include" else { continue }
                for included in inclusions[directive.id] ?? [] { walk(included) }
            }
        }
        func walk(_ document: SSHConfigDocument) {
            guard visited.insert(document.id).inserted else { return }
            scanForIncludes(document.preamble)
            for block in document.blocks {
                result.append(block)
                scanForIncludes(block.body)
            }
        }

        if let root { walk(root) }
        return result
    }
}
