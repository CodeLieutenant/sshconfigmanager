//
//  Chip.swift
//  SSHConfigMacUI
//
//  The small wash-filled action chip used for "ADD SETTING" suggestions (and any
//  compact add affordance). A leading glyph + label on the neutral `controlWash`; the
//  `prominent` variant drops the fill and tints the label with the accent for the
//  trailing "More…" affordance.
//

import SwiftUI

struct Chip: View {
    let title: String
    var systemImage: String? = "plus"
    /// Borderless, accent-tinted text (the "More…" affordance).
    var prominent: Bool = false
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(prominent ? Color.accentColor : .primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(prominent ? Color.clear : Color.controlWash, in: shape)
            .overlay(prominent ? nil : shape.strokeBorder(Color.cardBorder, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}
