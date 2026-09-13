//
//  CardSection.swift
//  SSHConfigMacUI
//
//  The grouped-content primitive for the Liquid Glass redesign: an uppercase section
//  label above a lifted white card whose direct children are automatically separated by
//  hairlines. This replaces the per-screen `Form { Section }` styling so GENERAL,
//  CONNECTION, IDENTITY KEYS, ACTIONS, … all render as the same card, and a new screen
//  composes one instead of inventing its own.
//
//  Dividers are interposed with `_VariadicView` so a caller just lists rows — no manual
//  `Divider()` between each. `CardRow` gives the standard 40pt row insets; `RowLabel`
//  the fixed leading column from the readout cards.
//

import SwiftUI

// MARK: - Section (label + card)

struct CardSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let title { SectionLabel(title) }
            Card { content }
        }
    }
}

/// The uppercase, tracked, secondary label that titles a section.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Card container

/// A lifted rounded card that auto-divides its direct children with hairlines.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    private let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)

    var body: some View {
        DividedVStack { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appContent, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.cardBorder, lineWidth: 1))
            .shadow(color: Color.primary.opacity(0.07), radius: 9, y: 8)
            .shadow(color: Color.primary.opacity(0.04), radius: 1, y: 1)
    }
}

// MARK: - Rows

/// One card row: the standard 40pt height and 15pt horizontal insets. Compose the row's
/// content (label, value, controls) inside; group several in a `Card`.
struct CardRow<Content: View>: View {
    var minHeight: CGFloat = 40
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Spacing.lg) {
            content
        }
        .padding(.horizontal, 15)
        .frame(minHeight: minHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The fixed-width secondary label that opens a readout row (the Figma 168pt column).
struct RowLabel: View {
    let text: String
    var width: CGFloat? = 168
    init(_ text: String, width: CGFloat? = 168) {
        self.text = text
        self.width = width
    }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }
}

// MARK: - Action row

/// A tappable card row: leading glyph · label · trailing chevron (or a custom trailing
/// view). The "Copy ssh Command" / "Deploy to Host…" / "Reveal in Finder" entries in an
/// Actions card.
struct ActionRow<Trailing: View>: View {
    let icon: String
    let label: String
    var role: ButtonRole?
    @ViewBuilder var trailing: () -> Trailing
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            CardRow(minHeight: 42) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(role == .destructive ? Color.red : .secondary)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(role == .destructive ? Color.red : .primary)
                Spacer(minLength: Spacing.sm)
                trailing()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ActionRow where Trailing == CardChevron {
    init(icon: String, label: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(
            icon: icon, label: label, role: role,
            trailing: { CardChevron() }, action: action)
    }
}

/// The trailing disclosure chevron on an `ActionRow`.
struct CardChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Auto-divided stack

/// A vertical stack that draws a `cardDivider` hairline between each of its direct
/// children — the same idiom AppKit's grouped lists use. Built on `_VariadicView` so the
/// child views stay individually identified (animations, transitions) instead of being
/// flattened into an array.
struct DividedVStack<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        _VariadicView.Tree(DividedLayout()) { content }
    }
}

private struct DividedLayout: _VariadicView_MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle()
                        .fill(Color.cardDivider)
                        .frame(height: 1)
                }
            }
        }
    }
}
