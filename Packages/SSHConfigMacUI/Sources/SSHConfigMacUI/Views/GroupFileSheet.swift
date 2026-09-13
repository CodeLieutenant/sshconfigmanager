//
//  GroupFileSheet.swift
//  sshconfigmanager
//
//  Sheet for creating a file-backed group from scratch, or promoting ("extracting")
//  an existing virtual group to one — same form either way, since both end up
//  calling ConfigStore with a name + filename + directory.
//

import AppKit
import SSHConfigServices
import SwiftUI

/// Identifies which flow presented `GroupFileSheet` and pre-fills accordingly.
struct GroupFileSheetContext: Identifiable {
    enum Mode: Equatable {
        /// Brand-new group, created file-backed from the start.
        case newGroup
        /// Promote an existing virtual group (by id) to file-backed.
        case extractExisting(PersistedGroup.ID)
    }

    let id = UUID()
    var mode: Mode
    var suggestedName: String = ""
}

struct GroupFileSheet: View {
    let context: GroupFileSheetContext
    /// Called with the new/promoted group's id once it's created, so the caller
    /// can trigger the same inline-rename affordance a plain "New Group" gets.
    var onCreated: (PersistedGroup.ID) -> Void

    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var fileName: String
    @State private var useCustomLocation = false
    @State private var customDirectory: URL?
    @State private var errorMessage: String?

    init(context: GroupFileSheetContext, onCreated: @escaping (PersistedGroup.ID) -> Void) {
        self.context = context
        self.onCreated = onCreated
        let initialName = context.suggestedName
        _name = State(initialValue: initialName)
        _fileName = State(initialValue: Self.slug(initialName))
    }

    private var isExtracting: Bool {
        if case .extractExisting = context.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(isExtracting ? "Extract Group to File" : "New Group with File")
                .font(.headline)

            Text(
                "A file-backed group lives in its own file, wired into your SSH config with an `Include` line. Dragging a host into it moves the host's entry into that file."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("Group name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, newValue in
                        if !userEditedFileName { fileName = Self.slug(newValue) }
                    }
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("File name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("filename.conf", text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: fileName) { _, _ in userEditedFileName = true }
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
                Button(isExtracting ? "Extract" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                            || fileName.trimmingCharacters(in: .whitespaces).isEmpty
                            || (useCustomLocation && customDirectory == nil))
            }
        }
        .padding(Spacing.xl)
        .frame(width: 380)
    }

    @State private var userEditedFileName = false

    private func pickCustomDirectory() {
        guard let url = store.pickAdditionalDirectory() else {
            if customDirectory == nil { useCustomLocation = false }
            return
        }
        customDirectory = url
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var trimmedFile = fileName.trimmingCharacters(in: .whitespaces)
        if !trimmedFile.contains(".") { trimmedFile += ".conf" }
        // `pickCustomDirectory()` already granted (and persisted) access to
        // `customDirectory` via the open panel — nothing left to do here.
        let directory: URL? = useCustomLocation ? customDirectory : nil
        if useCustomLocation, directory == nil { return }

        switch context.mode {
        case .newGroup:
            guard let id = store.createFileBackedGroup(name: trimmedName, fileName: trimmedFile, in: directory) else {
                errorMessage = store.errorMessage ?? "Couldn't create the group's file."
                return
            }
            onCreated(id)
        case .extractExisting(let groupID):
            if trimmedName != context.suggestedName, let group = store.group(id: groupID) {
                store.renameGroup(group.id, to: trimmedName)
            }
            store.extractGroupToFile(groupID, fileName: trimmedFile, in: directory)
            if let error = store.errorMessage {
                errorMessage = error
                return
            }
        }
        dismiss()
    }

    private static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return lowered.isEmpty ? "group.conf" : lowered + ".conf"
    }
}
