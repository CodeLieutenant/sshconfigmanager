//
//  GlassChrome.swift
//  SSHConfigMacUI
//
//  The frosted chrome of the Liquid Glass redesign — the sidebar panel and the detail
//  header — plus the small controls that ride on it (pill buttons, the search field) and
//  the faint colour washes behind everything.
//
//  Why materials and not `.glassEffect()`: the app's deployment target is macOS 14, and
//  true Liquid Glass is macOS 26+. The Figma "backdrop-blur over a translucent fill" is
//  exactly a system material, which we get on 14. `glassChrome()` is the single seam to
//  later opt into real Liquid Glass behind an `if #available(macOS 26)` without touching
//  call sites.
//

import SwiftUI

extension View {
    /// Frosted-glass background for chrome surfaces (sidebar, header). The material bleeds
    /// past the safe area to the window edge (so it fills behind the transparent titlebar
    /// and traffic-light controls) while the chrome's *content* stays inside the safe
    /// area. System material today; the one place to adopt real Liquid Glass on macOS 26.
    func glassChrome() -> some View {
        background {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
        }
    }
}

// MARK: - Window wash

/// The faint colour washes that sit behind the glass chrome — the Liquid Glass "blobs".
/// Subtle on purpose: colour lives in the chrome, content stays legible. Placed as the
/// window's backmost layer so the sidebar/header materials frost over it.
struct WindowWash: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Circle()
                .fill(TilePalette.accent.opacity(0.16))
                .frame(width: 460)
                .blur(radius: 130)
                .offset(x: -340, y: -260)
            Circle()
                .fill(Color.purple.opacity(0.10))
                .frame(width: 420)
                .blur(radius: 130)
                .offset(x: -260, y: 220)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Chrome controls

/// A header pill-button. `.prominent` is the accent-filled primary (Connect); `.secondary`
/// the wash-filled default (Add Setting); `.icon` a square wash button with no label.
struct ChromeButton: View {
    enum Kind { case prominent, secondary, icon }

    let title: String
    var systemImage: String?
    var kind: Kind = .secondary
    /// Tints the label/glyph on a non-prominent button (e.g. red for a destructive
    /// "Remove All"). Ignored for `.prominent` (always white on accent).
    var tint: Color?
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                if kind != .icon {
                    Text(title).font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(kind == .prominent ? Color.white : (tint ?? .primary))
            .padding(.horizontal, kind == .icon ? 8 : 12)
            .padding(.vertical, 7)
            .background(fillColor, in: shape)
            .overlay(kind == .prominent ? nil : shape.strokeBorder(Color.cardBorder, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var fillColor: Color {
        kind == .prominent ? (tint ?? .accentColor) : .controlWash
    }
}

extension ChromeButton {
    /// Icon-only convenience: the label doubles as the help text.
    init(icon systemImage: String, help: String, action: @escaping () -> Void) {
        self.init(title: help, systemImage: systemImage, kind: .icon, action: action)
    }
}

// MARK: - Screen header

/// The frosted 84pt header at the top of a top-level screen: an optional colour tile, a
/// bold title + optional subtitle, and trailing actions (typically `ChromeButton`s). Used
/// by Keys, Agent, Known Hosts, Issues, Tunnels, Version History, … so every screen opens
/// the same way. (The Host detail builds its own richer header with status/tag pills.)
struct ScreenHeader<Trailing: View>: View {
    var tile: (icon: String, color: Color)?
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(
        tile: (icon: String, color: Color)? = nil, title: String, subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.tile = tile
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Spacing.lg) {
            if let tile { IconTile(systemImage: tile.icon, color: tile.color, size: 34) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.lg)
            trailing()
        }
        .padding(.horizontal, Spacing.xxxl)
        .padding(.vertical, Spacing.xl)
        .frame(minHeight: 84)
        .glassChrome()
        .overlay(alignment: .bottom) { Rectangle().fill(.appSeparator).frame(height: 1) }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(tile: (icon: String, color: Color)? = nil, title: String, subtitle: String? = nil) {
        self.init(tile: tile, title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

// MARK: - Selectable glass row

extension View {
    /// The shared accent-fill (selected) / hover-wash background + white-on-accent text for
    /// a selectable row in a glass list (sidebar, the Keys/Tunnels master lists).
    func glassRowBackground(selected: Bool) -> some View {
        modifier(GlassRowBackground(selected: selected))
    }
}

struct GlassRowBackground: ViewModifier {
    let selected: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? Color.white : .primary)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(fill)
                    .shadow(color: selected ? .black.opacity(0.22) : .clear, radius: 3, y: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .onHover { hovering = $0 }
    }
    private var fill: Color {
        if selected { return .accentColor }
        return hovering ? .controlWash : .clear
    }
}

// MARK: - Search field

/// The sidebar search pill: a magnifier + a borderless text field on the neutral wash.
/// `onFocusChange` lets the host show/hide a suggestions dropdown; `onSubmit` fires on
/// Return.
struct SearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    var onFocusChange: ((Bool) -> Void)? = nil
    var onSubmit: (() -> Void)? = nil
    /// Set by callers that need to drive this specific instance from a UI test
    /// (multiple `SearchField`s exist, e.g. sidebar vs. Known Hosts filter).
    var identifier: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit { onSubmit?() }
                .accessibilityIdentifier(identifier ?? "")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .onChange(of: focused) { _, f in onFocusChange?(f) }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.controlWash, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 1)
        )
    }
}
