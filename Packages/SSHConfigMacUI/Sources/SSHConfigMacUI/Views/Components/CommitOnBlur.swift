//
//  CommitOnBlur.swift
//  sshconfigmanager
//
//  A focus-boundary hook for free-text fields. Typing into a field flows through
//  `ConfigStore.updateBlock(coalescing: true)`, which folds the keystrokes into one
//  open undo group; this modifier fires `action` when the field loses focus so the
//  store can commit that group as a single undo step (`commitFieldEdit()`). See
//  docs/plans-done/ux/undo-redo.md §3 (the field-commit seam).
//

import SwiftUI

private struct CommitOnBlur: ViewModifier {
    let action: () -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                // Only the falling edge (lost first-responder) commits the edit.
                if !isFocused { action() }
            }
    }
}

extension View {
    /// Runs `action` when this field loses keyboard focus — the boundary at which a
    /// coalesced free-text edit becomes one undo step. Attach to any `TextField`
    /// whose binding writes through `updateBlock(coalescing: true)`.
    func commitsOnBlur(_ action: @escaping () -> Void) -> some View {
        modifier(CommitOnBlur(action: action))
    }
}
