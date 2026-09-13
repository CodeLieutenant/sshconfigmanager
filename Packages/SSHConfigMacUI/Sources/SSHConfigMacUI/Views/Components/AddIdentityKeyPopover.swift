//
//  AddIdentityKeyPopover.swift
//  sshconfigmanager
//
//  A searchable picker for adding an IdentityFile — choose a key found in the
//  ~/.ssh folder, browse for one elsewhere, or enter a path manually.
//

import SSHConfigCore
import SwiftUI

struct AddIdentityKeyPopover: View {
    let keys: [SSHPublicKey]
    let onPick: (String) -> Void // identity file path ("" = manual entry)
    let onBrowse: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [SSHPublicKey] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return keys }
        return keys.filter {
            $0.name.lowercased().contains(q)
                || $0.comment.lowercased().contains(q)
                || $0.typeLabel.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search keys in ~/.ssh", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .padding(10)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if keys.isEmpty {
                        Text("No keys found in your SSH folder.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(matches) { key in
                        Button {
                            onPick(key.identityFilePath)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "key.fill").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(key.name)
                                    Text("\(key.typeLabel) · \(key.fingerprint)")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 240)

            Divider()
            VStack(spacing: 0) {
                Button {
                    dismiss()
                    onBrowse()
                } label: {
                    Label("Browse for a Key File…", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Button {
                    onPick("")
                    dismiss()
                } label: {
                    Label("Enter Path Manually", systemImage: "pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
        .frame(width: 360)
        .onAppear { focused = true }
    }
}
