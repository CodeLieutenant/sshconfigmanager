//
//  Directive.swift
//  SSHConfigCore
//
//  A single `Keyword Value` line in an ssh_config file.
//

import Foundation

/// One configuration directive, e.g. `HostName example.com` or `Port=2222`.
///
/// To support lossless round-tripping, the exact original text of the line is kept
/// in `rawText` and emitted verbatim while `isDirty == false`. Once any field is
/// edited the line is re-rendered from its components, reusing the captured
/// indentation and separator so the result still matches the surrounding style.
public struct Directive: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID

    /// Whitespace before the keyword (preserves indentation inside a Host block).
    public var leadingIndent: String

    /// The keyword exactly as written, e.g. `HostName`. Case is preserved.
    public var keyword: String

    /// The exact characters between the keyword and the value: whitespace and/or
    /// an optional `=`, e.g. `" "`, `"\t"`, `"="`, or `" = "`.
    public var separatorText: String

    /// The value as written (without the surrounding separator or trailing space).
    public var value: String

    /// Any trailing whitespace after the value (preserved for round-tripping).
    public var trailingText: String

    /// The original line text (excluding the newline). Used verbatim when `!isDirty`.
    public var rawText: String

    /// `true` once a field has been edited; flips the serializer to re-render the line.
    public var isDirty: Bool

    public init(
        id: UUID = UUID(),
        leadingIndent: String = "",
        keyword: String,
        separatorText: String = " ",
        value: String,
        trailingText: String = "",
        rawText: String? = nil,
        isDirty: Bool = false
    ) {
        self.id = id
        self.leadingIndent = leadingIndent
        self.keyword = keyword
        self.separatorText = separatorText
        self.value = value
        self.trailingText = trailingText
        self.isDirty = isDirty
        self.rawText = rawText ?? (leadingIndent + keyword + separatorText + value + trailingText)
    }

    /// Lowercased keyword for case-insensitive comparison (ssh keywords are case-insensitive).
    public var canonicalKeyword: String { keyword.lowercased() }

    /// Whether the directive uses `=` as its separator (vs. plain whitespace).
    public var usesEquals: Bool { separatorText.contains("=") }

    /// The exact text to write for this line (no trailing newline).
    public var rendered: String {
        guard isDirty else { return rawText }
        let separator = separatorText.isEmpty ? " " : separatorText
        return leadingIndent + keyword + separator + value + trailingText
    }

    /// Returns a copy with a new value, marked dirty.
    public func settingValue(_ newValue: String) -> Directive {
        var copy = self
        copy.value = newValue
        copy.isDirty = true
        return copy
    }

    /// A copy with a brand-new `id` but every other field — including `rawText` and
    /// `isDirty` — preserved, so an unedited line still round-trips byte-for-byte.
    /// Used when cloning a block: two blocks must never share line identities.
    public func withFreshID() -> Directive {
        Directive(
            id: UUID(),
            leadingIndent: leadingIndent,
            keyword: keyword,
            separatorText: separatorText,
            value: value,
            trailingText: trailingText,
            rawText: rawText,
            isDirty: isDirty
        )
    }
}
