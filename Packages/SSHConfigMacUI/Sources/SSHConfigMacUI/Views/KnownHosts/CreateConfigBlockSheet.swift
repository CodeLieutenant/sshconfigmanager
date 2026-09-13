import AppKit
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import SwiftUI

struct CreateConfigBlockSheet: View {
    let hostName: String
    let suggestedAlias: String
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""

    private var trimmedAlias: String { alias.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Config Entry").font(.headline)
            Text(
                "A new Host block will be added to your ssh_config with HostName \u{201C}\(hostName)\u{201D} pre-filled. Give it an alias so you can type `ssh <alias>`."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Alias") {
                TextField("e.g. myserver", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
            Text("HostName: \(hostName)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { onCreate(trimmedAlias) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedAlias.isEmpty)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { alias = suggestedAlias }
    }
}
