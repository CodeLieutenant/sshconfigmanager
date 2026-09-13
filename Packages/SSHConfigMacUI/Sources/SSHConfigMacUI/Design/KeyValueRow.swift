//
//  KeyValueRow.swift
//  sshconfigmanager
//
//  One attribute-readout row: a secondary label in a fixed leading column, then the
//  value (monospaced when it's machine text), then an optional trailing affordance such
//  as Copy or Reveal. Replaces the per-view `LabeledContent` variants in the Keys, Agent,
//  and Tunnel detail panes with a single consistent row (§5.4). Group several inside a
//  `Form`/grouped section to get the standard macOS readout list.
//

import SwiftUI

struct KeyValueRow<Trailing: View>: View {
    let label: String
    let value: String
    /// Use the monospaced face for fingerprints, paths, ports, commands — anything a
    /// machine emitted or that you'd paste into a terminal.
    var monospaced: Bool = false
    var labelWidth: CGFloat = 130
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Spacing.sm)
            trailing()
        }
        .frame(minHeight: 30)
    }
}

extension KeyValueRow where Trailing == EmptyView {
    init(_ label: String, value: String, monospaced: Bool = false, labelWidth: CGFloat = 130) {
        self.init(
            label: label, value: value, monospaced: monospaced,
            labelWidth: labelWidth, trailing: { EmptyView() })
    }
}
