//
//  AddSettingCatalogView.swift
//  sshconfigmanager
//
//  A browsable, searchable catalog of ssh_config settings, grouped by category,
//  each shown with its name and description. Stays open so several can be added.
//

import SSHConfigCore
import SwiftUI

struct AddSettingCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    /// Current lowercased keys already present (recomputed so added rows disappear).
    let present: () -> Set<String>
    let onAdd: (KeywordInfo) -> Void
    let onAddCustom: (String) -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var exactKnown: Bool { KeywordRegistry.info(for: trimmed) != nil }

    private func items(in category: KeywordCategory) -> [KeywordInfo] {
        KeywordRegistry.search(query, excluding: present()).filter { $0.category == category }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Setting").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name or description…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16).padding(.bottom, 8)

            Divider()

            List {
                if !trimmed.isEmpty && !exactKnown {
                    Section {
                        Button {
                            onAddCustom(trimmed)
                        } label: {
                            Label("Add custom keyword “\(trimmed)”", systemImage: "plus.circle")
                        }
                    }
                }
                ForEach(KeywordCategory.allCases, id: \.self) { category in
                    let list = items(in: category)
                    if !list.isEmpty {
                        Section(category.rawValue) {
                            ForEach(list, id: \.canonical) { info in
                                row(info)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 600)
        .accessibilityIdentifier("add-setting-sheet")
        .onAppear { focused = true }
    }

    private func row(_ info: KeywordInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.canonical).font(.body.monospaced())
                Text(info.help)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Add") { onAdd(info) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
