//
//  ConfigLine.swift
//  SSHConfigCore
//
//  A single physical line of an ssh_config file.
//

import Foundation

/// One physical line in an ssh_config file. Blank and comment lines preserve their
/// exact text so untouched files round-trip byte-for-byte.
public enum ConfigLine: Identifiable, Equatable, Hashable, Sendable {
    /// An empty line, or a line containing only whitespace. `raw` holds that whitespace.
    case blank(id: UUID, raw: String)
    /// A whole-line comment (first non-blank character is `#`).
    case comment(id: UUID, raw: String)
    /// A `Keyword Value` directive line.
    case directive(Directive)

    public var id: UUID {
        switch self {
        case .blank(let id, _): return id
        case .comment(let id, _): return id
        case .directive(let directive): return directive.id
        }
    }

    /// The exact text to write for this line (no trailing newline).
    public var rendered: String {
        switch self {
        case .blank(_, let raw): return raw
        case .comment(_, let raw): return raw
        case .directive(let directive): return directive.rendered
        }
    }

    /// The directive payload, if this line is a directive.
    public var directive: Directive? {
        if case .directive(let directive) = self { return directive }
        return nil
    }

    public static func blank(_ raw: String = "") -> ConfigLine { .blank(id: UUID(), raw: raw) }
    public static func comment(_ raw: String) -> ConfigLine { .comment(id: UUID(), raw: raw) }

    /// A copy with a fresh `id` but identical text, so a cloned block's lines never
    /// share identity with the source's. Preserves `raw`, so untouched lines still
    /// round-trip byte-for-byte.
    public func withFreshID() -> ConfigLine {
        switch self {
        case .blank(_, let raw): return .blank(id: UUID(), raw: raw)
        case .comment(_, let raw): return .comment(id: UUID(), raw: raw)
        case .directive(let directive): return .directive(directive.withFreshID())
        }
    }
}
