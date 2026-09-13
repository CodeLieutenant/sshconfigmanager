//
//  Theme.swift
//  sshconfigmanager
//
//  The single source of truth for design tokens — colour, status, and spacing.
//
//  Why this file exists: before it, every call site re-derived its own colours and
//  paddings inline. Status colours (.green/.yellow/.orange/.red) were re-chosen in
//  five different views, so they drifted; spacing was a scatter of magic numbers.
//  Per `docs/design/design-language.md`, all of those decisions are centralised here
//  so the app stays coherent and a new screen reads from one vocabulary instead of
//  inventing its own. Nothing in here paints a custom background or gradient: surfaces
//  are macOS system materials, and the accent is the user's system accent (we no
//  longer ship an AccentColor override). Colour means status or diff — nothing else.
//

import SwiftUI

// MARK: - Spacing

/// The one spacing scale, in points. Use these instead of literal paddings/gaps so the
/// app shares a single rhythm (§4.3 of the design language).
nonisolated enum Spacing {
    static let xs: CGFloat = 2
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 24
    static let xxxxl: CGFloat = 32
}

// MARK: - Status

/// The five — and only five — states colour is allowed to express outside the accent
/// and diffs. Every status indicator (tunnel badge, agent pill, sidebar dot, issue
/// severity, menu-bar rows) maps onto one of these so "what *running* looks like" is
/// decided exactly once. Colours are the system semantic colours, which adapt to dark
/// mode and the user's settings for free.
enum StatusKind: Sendable {
    case idle // stopped / not-loaded / inactive — no attention
    case pending // starting / retrying — transient, in progress
    case ok // active / running / loaded / healthy
    case warn // degraded / warning — works, needs attention
    case error // failed / broken

    /// The token colour. `idle` is deliberately `.secondary` (a non-colour) so an
    /// inactive state doesn't compete for attention.
    var color: Color {
        switch self {
        case .idle: return .secondary
        case .pending: return .yellow
        case .ok: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }

    /// Default SF Symbol for a status dot. Shape *and* colour both convey the state, so
    /// the indicator stays legible for colour-blind users and in greyscale.
    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .pending: return "circle.dotted"
        case .ok: return "circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

// MARK: - Surfaces

/// Semantic surface colours, each a macOS system material so the app inherits the
/// platform's light/dark/vibrancy behaviour. These exist to *name* the intent ("this is
/// a code surface") and to give the old hand-painted backgrounds — most notably the
/// Version History dark gradient — one honest replacement.
extension ShapeStyle where Self == Color {
    /// Default window content background.
    static var appWindow: Color { Color(nsColor: .windowBackgroundColor) }
    /// Rows, cards, and grouped-form content.
    static var appContent: Color { Color(nsColor: .controlBackgroundColor) }
    /// Real text/code surfaces — the tunnel console and the diff viewer. Not black.
    static var appCode: Color { Color(nsColor: .textBackgroundColor) }
    /// Hairline separators between rows and sections.
    static var appSeparator: Color { Color(nsColor: .separatorColor) }
}

// MARK: - Diff

/// The only place, besides status, where colour carries meaning: added/removed lines in
/// a diff. Text uses the system green/red; the row tint is a faint wash so the colour
/// reads as a highlight, not a fill.
enum DiffPalette {
    static let addedText = Color.green
    static let removedText = Color.red
    static let addedRow = Color.green.opacity(0.10)
    static let removedRow = Color.red.opacity(0.10)
}

// MARK: - Radius

/// The corner-radius scale for the Liquid Glass v4 surfaces. Cards, controls, chips, and
/// the colour tiles each have one radius so depth reads consistently across screens.
enum Radius {
    static let window: CGFloat = 20 // the (informational) outer window rounding
    static let card: CGFloat = 13 // grouped content cards
    static let control: CGFloat = 9 // header pill-buttons (Add Setting, Connect…)
    static let chip: CGFloat = 8 // add-setting chips, search pill, sidebar tiles
    static let tile: CGFloat = 8 // colour icon tiles
}

// MARK: - Tile palette

/// System-Settings-style category tile colours. Each names a *destination's identity*
/// (SSH Keys, Tunnels, …) and is purely decorative — it is **not** status, so it doesn't
/// go through `StatusKind`. They use the vivid system palette so they stay saturated and
/// adapt to dark mode for free. The focused host and the header app-tile use the user's
/// system accent (`accent`) rather than a fixed hue.
enum TilePalette {
    static let keys = Color.blue
    static let agent = Color.purple
    static let knownHosts = Color.green
    static let tunnels = Color.teal
    static let issues = Color.orange
    static let history = Color.indigo
    static let gistSync = Color.cyan
    static let host = Color(nsColor: .systemGray)
    static let accent = Color.accentColor
}

// MARK: - Liquid Glass surfaces

extension ShapeStyle where Self == Color {
    /// Neutral wash behind secondary controls — chips, the search pill, header icon
    /// buttons, tag pills. A faint ink that flips with the appearance (dark-on-light /
    /// light-on-dark), matching the Figma `rgba(120,120,135,~.13)` fill.
    static var controlWash: Color { Color.primary.opacity(0.06) }
    /// Slightly stronger wash for count badges.
    static var badgeWash: Color { Color.primary.opacity(0.08) }
    /// Hairline between rows *inside* a card (a touch lighter than `appSeparator`, which
    /// separates whole regions).
    static var cardDivider: Color { Color.primary.opacity(0.07) }
    /// The 1px border drawn around a lifted card.
    static var cardBorder: Color { Color.primary.opacity(0.06) }
}
