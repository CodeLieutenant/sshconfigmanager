//
//  CompletionModels.swift
//  SSHConfigIntelliSense
//
//  The value types the engine speaks. Everything here is pure, `Sendable`, and
//  Foundation-only so the engine is reusable from a CLI or a Linux UI — the macOS
//  AppKit popup is just one consumer that turns these into table rows and text
//  replacements.
//
//  Offsets are UTF-16 (NSTextView-native units) so a SwiftUI/AppKit caller can map
//  a `ReplacementRange` straight onto an `NSRange` without re-deriving the token.
//

import Foundation

/// What a completion inserts — drives the row icon and grouping in the UI.
public enum CompletionKind: String, Equatable, Sendable {
    case keyword // an ssh_config directive name (HostName, Port, …)
    case value // a free-form value hint for the current directive
    case enumCase // one case of a fixed enumeration (yes/no, ask, …)
    case algorithm // a crypto algorithm token (cipher / MAC / kex / host-key)
    case host // a Host alias referenced from elsewhere in the file
    case snippet // a multi-token template
    case file // a regular file on disk (IdentityFile, CertificateFile, …)
    case folder // a directory on disk (drill into it to keep completing)
}

/// A UTF-16 offset range in the edited document. The engine reports exactly the
/// token under the cursor so the caller replaces only that span on accept.
public struct ReplacementRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// A single suggestion. `id` is stable within one result list (kind + label are
/// unique there), which is all SwiftUI's `ForEach`/`Identifiable` needs.
public struct CompletionItem: Equatable, Sendable, Identifiable {
    /// Shown as the primary text in the popup row.
    public let label: String
    /// The text spliced into the document over `replace` when the item is accepted.
    public let insertText: String
    /// Secondary, right-aligned text (a category, a type, "default", …).
    public let detail: String?
    /// Long-form help shown in a detail pane / tooltip.
    public let documentation: String?
    public let kind: CompletionKind
    /// The document span the accept replaces.
    public let replace: ReplacementRange
    /// Higher ranks earlier. Comes from `FuzzyMatch` plus per-kind biases.
    public let score: Int
    /// Character offsets *within `label`* that the typed prefix matched, so the UI
    /// can bold the matched run (IDE-style). Empty when nothing was matched (e.g. an
    /// empty-prefix list, or a candidate offered without fuzzy scoring).
    public let matchedRanges: [ReplacementRange]
    /// The engine flags exactly one item per result list as the best match — the one
    /// the popup highlights and Tab/Return accepts. The UI marks it (a star) so it's
    /// obvious which suggestion will be inserted.
    public let isPreselected: Bool

    public var id: String { "\(kind.rawValue)\u{1}\(label)" }

    public init(
        label: String, insertText: String, detail: String?, documentation: String?,
        kind: CompletionKind, replace: ReplacementRange, score: Int,
        matchedRanges: [ReplacementRange] = [], isPreselected: Bool = false
    ) {
        self.label = label
        self.insertText = insertText
        self.detail = detail
        self.documentation = documentation
        self.kind = kind
        self.replace = replace
        self.score = score
        self.matchedRanges = matchedRanges
        self.isPreselected = isPreselected
    }

    /// A copy flagged as the best match. Used by the engine to mark exactly one item
    /// per result list (all fields are `let`, so preselection is a rebuild).
    public func preselected() -> CompletionItem {
        CompletionItem(
            label: label, insertText: insertText, detail: detail,
            documentation: documentation, kind: kind, replace: replace,
            score: score, matchedRanges: matchedRanges, isPreselected: true)
    }
}

/// Documentation for the token under the cursor — powers a hover / inline-docs
/// affordance independent of the completion popup.
public struct HoverInfo: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let documentation: String
    public let range: ReplacementRange

    public init(title: String, detail: String?, documentation: String, range: ReplacementRange) {
        self.title = title
        self.detail = detail
        self.documentation = documentation
        self.range = range
    }
}
