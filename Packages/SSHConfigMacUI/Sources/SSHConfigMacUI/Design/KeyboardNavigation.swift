//
//  KeyboardNavigation.swift
//  SSHConfigMacUI
//
//  Arrow-key navigation for the custom glass lists. Going fully custom (rather than
//  restyling `List`) cost us `List`'s built-in keyboard navigation; this puts it back.
//  Attach `.arrowKeyNavigation(items:selection:)` to a list container: the view becomes
//  focusable, takes focus on appear, and ↑/↓ move the selection through `items` (the rows
//  in display order). Re-asserting focus is exposed via `focusOnSelect()` for row taps so
//  arrowing resumes after a click.
//

import SwiftUI

extension View {
    /// Make a list container keyboard-navigable: ↑/↓ move `selection` through `items`
    /// (in display order). Wrap-free clamping at both ends, matching `List`.
    func arrowKeyNavigation<ID: Hashable>(items: [ID], selection: Binding<ID?>) -> some View {
        modifier(ArrowKeyNavigation(items: items, selection: selection))
    }
}

private struct ArrowKeyNavigation<ID: Hashable>: ViewModifier {
    let items: [ID]
    @Binding var selection: ID?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            // Reclaim focus whenever a row sets the selection (e.g. a click), so the
            // very next arrow press keeps moving instead of doing nothing.
            .onChange(of: selection) { _, _ in focused = true }
            .onMoveCommand { direction in
                guard !items.isEmpty else { return }
                let current = selection.flatMap { items.firstIndex(of: $0) }
                switch direction {
                case .up:
                    if let i = current { selection = items[max(0, i - 1)] } else { selection = items.last }
                case .down:
                    if let i = current {
                        selection = items[min(items.count - 1, i + 1)]
                    } else {
                        selection = items.first
                    }
                default:
                    break
                }
            }
    }
}
