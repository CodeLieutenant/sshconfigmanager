//
//  MoveToNewFileSheet.swift
//  sshconfigmanager
//
//  Sheet for the "New File…" entry in a host's "Move to File" menu: creates a
//  brand-new file, wires it into the config with an `Include`, and moves the
//  host's block (with its leading comments) into it.
//

import AppKit
import SSHConfigCore
import SwiftUI

/// Identifies which block "New File…" is moving and pre-fills a suggested name.
struct MoveToNewFileContext: Identifiable {
    let id: HostBlock.ID
    var suggestedName: String = ""
}

struct MoveToNewFileSheet: View {
    let context: MoveToNewFileContext

    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var fileName: String
    @State private var useCustomLocation = false
    @State private var customDirectory: URL?
    @State private var errorMessage: String?

    init(context: MoveToNewFileContext) {
        self.context = context
        _fileName = State(initialValue: context.suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Move to New File")
                .font(.headline)

            Text(
                "Moves this entry — and any comments directly above it — into a new file, wired into your SSH config with an `Include` line."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("File name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("filename.conf", text: $fileName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Location").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Picker("", selection: $useCustomLocation) {
                    Text("Default (~/.ssh/ssh-config-manager.d/)").tag(false)
                    Text("Choose…").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: useCustomLocation) { _, newValue in
                    if newValue { pickCustomDirectory() }
                }
                if useCustomLocation, let customDirectory {
                    Label(customDirectory.path, systemImage: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") { move() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        fileName.trimmingCharacters(in: .whitespaces).isEmpty
                            || (useCustomLocation && customDirectory == nil))
            }
        }
        .padding(Spacing.xl)
        .frame(width: 380)
    }

    private func pickCustomDirectory() {
        guard let url = store.pickAdditionalDirectory() else {
            if customDirectory == nil { useCustomLocation = false }
            return
        }
        customDirectory = url
    }

    private func move() {
        var trimmedFile = fileName.trimmingCharacters(in: .whitespaces)
        if !trimmedFile.contains(".") { trimmedFile += ".conf" }
        let directory: URL? = useCustomLocation ? customDirectory : nil
        if useCustomLocation, directory == nil { return }

        guard store.moveBlockToNewFile(id: context.id, fileName: trimmedFile, in: directory) != nil else {
            errorMessage = store.errorMessage ?? "Couldn't create the file."
            return
        }
        dismiss()
    }
}
