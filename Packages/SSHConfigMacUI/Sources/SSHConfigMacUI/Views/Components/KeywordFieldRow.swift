//
//  KeywordFieldRow.swift
//  sshconfigmanager
//
//  Renders one known keyword as the right kind of control.
//

import SSHConfigCore
import SwiftUI

struct KeywordFieldRow: View {
    let info: KeywordInfo
    @Binding var value: String
    @Binding var boolValue: Bool
    /// Show the keyword's help text under the label. Off inside the redesign's compact
    /// card rows (the help moves to a hover tooltip), on in the old grouped form.
    var showsHelp: Bool = true
    /// Called to remove this setting from the host block. Nil for essential fields
    /// (HostName, User, Port) that must not be deleted.
    var onDelete: (() -> Void)? = nil
    /// Called when a free-text field (string/path/list/integer) loses focus, so the
    /// store can commit the coalesced typing as one undo step. No-op for the discrete
    /// controls (toggle/picker), whose edits already register immediately.
    var onCommit: () -> Void = {}

    var body: some View {
        // Wrapping in an explicit HStack (rather than relying on LabeledContent's implicit
        // layout) gives us precise control over the trailing-edge alignment: Toggle is
        // fixed-size so LabeledContent outside a Form won't push it right on its own.
        HStack(spacing: Spacing.lg) {
            switch info.field {
            case .yesNo:
                label
                Spacer(minLength: Spacing.sm)
                toggle
            case .integer:
                LabeledContent {
                    numberField
                } label: {
                    label
                }
            case .enumeration(let options):
                LabeledContent {
                    picker(options)
                } label: {
                    label
                }
                // Picker is fixed-size; spacer is needed to push the delete button right.
                if onDelete != nil { Spacer(minLength: Spacing.sm) }
            case .string, .path, .list:
                LabeledContent {
                    textField
                } label: {
                    label
                }
            }
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(info.canonical)
            if showsHelp {
                Text(info.help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .help(info.help)
    }

    private var toggle: some View {
        Toggle("", isOn: $boolValue)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    private var textField: some View {
        TextField(info.canonical, text: $value)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .commitsOnBlur(onCommit)
    }

    private var numberField: some View {
        // No fixed width: like `textField`, let LabeledContent stretch the field to the
        // trailing edge so the digits right-align with the string rows above/below. A
        // rigid frame here would pin the field at the leading edge, hugging the label.
        TextField(info.canonical, text: $value)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .commitsOnBlur(onCommit)
    }

    private func picker(_ options: [String]) -> some View {
        Picker("", selection: $value) {
            if !options.contains(value) {
                Text(value.isEmpty ? "—" : value).tag(value)
            }
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
