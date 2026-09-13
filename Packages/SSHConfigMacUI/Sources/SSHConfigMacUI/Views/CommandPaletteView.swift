//
//  CommandPaletteView.swift
//  sshconfigmanager
//
//  ⌘K quick-open: fuzzy-jump to any host.
//

import SSHConfigCore
import SwiftUI

struct CommandPaletteView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelStore.self) private var tunnels
    @Environment(\.dismiss) private var dismiss
    let onOpen: (HostBlock.ID) -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    /// Tunnel presets whose name or host matches the query (for start/stop verbs).
    private var tunnelMatches: [TunnelPreset] {
        guard !query.isEmpty else { return tunnels.runningPresets }
        let q = query.lowercased()
        return tunnels.presets.filter {
            $0.displayName.lowercased().contains(q) || $0.hostAlias.lowercased().contains(q)
        }
    }

    /// Undo/redo verbs to surface: shown when the manager can perform them and the
    /// query is empty or matches the verb or its action name (e.g. "undo", "delete").
    private func undoVerb(redo: Bool) -> String? {
        guard let manager = store.undoManager else { return nil }
        let can = redo ? manager.canRedo : manager.canUndo
        guard can else { return nil }
        let action = redo ? manager.redoActionName : manager.undoActionName
        let title = (redo ? "Redo" : "Undo") + (action.isEmpty ? "" : " \(action)")
        guard query.isEmpty || FuzzyMatch.score(query: query, candidate: title) != nil else { return nil }
        return title
    }

    private var matches: [HostBlock] {
        let hosts = store.allHostBlocks.filter { !$0.isWildcard }
        let scored = hosts.compactMap { block -> (HostBlock, Int)? in
            let haystack = block.title + " " + (block.firstValue(for: "HostName") ?? "")
            guard let score = FuzzyMatch.score(query: query, candidate: haystack) else { return nil }
            return (block, score)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to host…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if let first = matches.first { open(first.id) } }
            }
            .padding(14)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if matches.isEmpty {
                        Text(query.isEmpty ? "Type to search your hosts" : "No matches")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    if !matches.isEmpty {
                        SectionLabel("Hosts").padding(.horizontal, Spacing.md).padding(.top, Spacing.sm)
                    }
                    ForEach(matches) { block in
                        hostRow(block, active: block.id == matches.first?.id)
                    }

                    if !tunnelMatches.isEmpty {
                        SectionLabel("Tunnels").padding(.horizontal, Spacing.md).padding(.top, Spacing.md)
                        ForEach(tunnelMatches) { preset in
                            tunnelRow(preset)
                        }
                    }

                    let undoTitle = undoVerb(redo: false)
                    let redoTitle = undoVerb(redo: true)
                    if undoTitle != nil || redoTitle != nil {
                        SectionLabel("Edit").padding(.horizontal, Spacing.md).padding(.top, Spacing.md)
                        if let undoTitle {
                            editRow(undoTitle, systemImage: "arrow.uturn.backward") {
                                store.undoManager?.undo()
                            }
                        }
                        if let redoTitle {
                            editRow(redoTitle, systemImage: "arrow.uturn.forward") {
                                store.undoManager?.redo()
                            }
                        }
                    }
                }
                .padding(Spacing.md)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 480)
        .onAppear { focused = true }
    }

    private func hostRow(_ block: HostBlock, active: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: "server.rack", color: active ? .white.opacity(0.28) : TilePalette.host)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title).font(.system(size: 13, weight: .medium))
                if let host = block.firstValue(for: "HostName") {
                    Text(host).font(.system(size: 11))
                        .foregroundStyle(active ? Color.white.opacity(0.85) : .secondary)
                }
            }
            Spacer(minLength: Spacing.sm)
            if block.kind == .host { rowActions(for: block, active: active) }
        }
        .padding(.horizontal, Spacing.md)
        .frame(minHeight: 42)
        .glassRowBackground(selected: active)
        .contentShape(Rectangle())
        .onTapGesture { open(block.id) }
    }

    private func tunnelRow(_ preset: TunnelPreset) -> some View {
        let running = tunnels.status(for: preset.id).isRunning
        return HStack(spacing: Spacing.md) {
            IconTile(systemImage: running ? "stop.fill" : "play.fill", color: TilePalette.tunnels)
            Text("\(running ? "Stop" : "Start") tunnel: \(preset.displayName)")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: Spacing.sm)
            Text(preset.hostAlias).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.md)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
        .onTapGesture {
            tunnels.toggle(preset)
            dismiss()
        }
    }

    /// An Undo/Redo row. Performs the action and dismisses the palette.
    private func editRow(_ title: String, systemImage: String, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: systemImage, color: TilePalette.accent)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: Spacing.sm)
        }
        .padding(.horizontal, Spacing.md)
        .frame(minHeight: 42)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
            dismiss()
        }
    }

    /// Trailing quick verbs on a host row: Connect, Copy ssh command, and Duplicate (always).
    /// Each fires the same `ConfigStore` helper the sidebar/detail menus use, then dismisses.
    private func rowActions(for block: HostBlock, active: Bool) -> some View {
        HStack(spacing: 10) {
            if block.connectionTarget != nil {
                Button {
                    store.connect(block)
                    dismiss()
                } label: {
                    Image(systemName: "terminal")
                }
                .help("Connect: \(block.title)")

                Button {
                    store.copySSHCommand(for: block)
                    dismiss()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy ssh command: \(block.title)")
            }

            Button {
                if let newID = store.duplicateBlock(id: block.id) { open(newID) } else { dismiss() }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("Duplicate: \(block.title)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(active ? Color.white.opacity(0.9) : .secondary)
    }

    private func open(_ id: HostBlock.ID) {
        onOpen(id)
        dismiss()
    }
}
