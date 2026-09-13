import AppKit
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import SwiftUI

struct AddKnownHostSheet: View {
    let fileName: String
    let onAdd: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Known Host").font(.headline)
            Text("Paste or type a known_hosts line. It will be appended to \u{201C}\(fileName)\u{201D}.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .accessibilityLabel("Known hosts entry")
            Text("Example: github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA…")
                .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { if onAdd(trimmed) { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }
}
