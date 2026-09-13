//
//  AgentView.swift
//  sshconfigmanager
//
//  The ssh-agent integration screen — restyled to the Liquid Glass redesign: a frosted
//  screen header, a glass identity list (loaded / on-disk sections), and a detail pane of
//  lifted cards (Details · Actions). The live correlation against on-disk keys, in-app
//  load/remove over the socket, the "keep loaded after restart" Keychain flow, and the
//  ssh-add fallback sheet are all unchanged. See docs/plans/keys/agent-integration.md.
//

import AppKit
import SSHConfigCore
import SSHConfigCrypto
import SwiftUI

struct AgentView: View {
    @Environment(ConfigStore.self) private var store
    // Select by the row's stable key (fingerprint, or synthetic id) so the
    // selection survives a refresh that rebuilds the row list.
    @State private var selectedKey: String?
    @State private var confirmRemoveAll = false
    /// Drives the "copy ssh-add command" fallback sheet (Keychain persistence).
    @State private var commandSheetKey: SSHPublicKey?
    /// selectionID of the key currently being added over the socket, for the spinner.
    @State private var addingKey: String?

    private var rows: [AgentKeyRow] {
        AgentKeyCorrelation.merge(diskKeys: store.publicKeys, agentIdentities: store.agentIdentities)
    }

    var body: some View {
        content
            .confirmationDialog(
                "Unload all identities from the agent?",
                isPresented: $confirmRemoveAll, titleVisibility: .visible
            ) {
                Button("Remove All", role: .destructive) {
                    Task { await store.removeAllAgentIdentities() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This unloads every key from the running ssh-agent. Your key files on disk are not affected.")
            }
            .sheet(item: $commandSheetKey) { key in AddToAgentSheet(key: key) }
            .task { await store.refreshAgent() }
            .onChange(of: rows.map(\.selectionID)) { _, _ in selectFirstIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                tile: (icon: "person.badge.key.fill", color: TilePalette.agent),
                title: "SSH Agent", subtitle: subtitle
            ) {
                ChromeButton(title: "Remove All", systemImage: "xmark.circle", kind: .secondary, tint: .red) {
                    confirmRemoveAll = true
                }
                .disabled(store.agentIdentities.isEmpty)
                ChromeButton(icon: "arrow.clockwise", help: "Re-read the agent's loaded identities") {
                    Task { await store.refreshAgent() }
                }
            }
            statusBody
        }
        .background(WindowWash())
    }

    @ViewBuilder
    private var statusBody: some View {
        switch store.agentStatus {
        case .unknown:
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            unavailableState
        case .failed(let message):
            failedState(message)
        case .available:
            if rows.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    identityList.frame(width: 300)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var subtitle: String {
        let loaded = rows.filter(\.isLoaded).count
        let onDiskOnly = rows.filter(\.isOnDiskOnly).count
        guard loaded + onDiskOnly > 0 else { return "" }
        var parts: [String] = []
        parts.append(loaded == 1 ? "1 loaded" : "\(loaded) loaded")
        if onDiskOnly > 0 { parts.append("\(onDiskOnly) on disk, not loaded") }
        return parts.joined(separator: " · ")
    }

    private func selectFirstIfNeeded() {
        if selectedKey == nil || !rows.contains(where: { $0.selectionID == selectedKey }) {
            selectedKey = rows.first?.selectionID
        }
    }

    // MARK: - Identity list

    private var identityList: some View {
        // A real `List` so ↑/↓ keyboard navigation works; styled to the glass look.
        List(selection: $selectedKey) {
            if !loadedRows.isEmpty {
                Section("Loaded in Agent") { ForEach(loadedRows) { row($0) } }
            }
            if !unloadedRows.isEmpty {
                Section("On Disk · Not Loaded") { ForEach(unloadedRows) { row($0) } }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 300)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.appSeparator).frame(width: 1) }
    }

    private func row(_ row: AgentKeyRow) -> some View {
        HStack(spacing: Spacing.md) {
            IconTile(
                systemImage: row.diskKey != nil ? "key.fill" : "person.badge.key.fill",
                color: TilePalette.agent)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentKeyCorrelation.displayName(row)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(row.fingerprint.isEmpty ? "No fingerprint" : row.fingerprint)
                    .font(.system(size: 11).monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.sm)
            Image(systemName: row.isLoaded ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(row.isLoaded ? .green : .secondary)
                .help(row.isLoaded ? "Loaded in the agent" : "Not loaded in the agent")
        }
        .frame(minHeight: 40)
        .tag(row.selectionID)
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .listRowSeparator(.hidden)
        .contextMenu { rowMenu(for: row) }
    }

    @ViewBuilder
    private func rowMenu(for row: AgentKeyRow) -> some View {
        if let identity = row.agentIdentity {
            Button("Remove from Agent", role: .destructive) {
                removeIdentity(keyBlob: identity.keyBlob)
            }
        }
        if row.isOnDiskOnly, let diskKey = row.diskKey, diskKey.privateKeyURL != nil {
            Button("Add to Agent") { addToAgent(diskKey) }
            Button("Copy ssh-add Command…") { requestCopyCommand(diskKey) }
        }
        if !row.fingerprint.isEmpty {
            Button("Copy Fingerprint") { copy(row.fingerprint) }
        }
    }

    /// Loads a key into the agent in-app over the socket (prompts for a passphrase
    /// if it's encrypted).
    private func addToAgent(_ key: SSHPublicKey) {
        addingKey = key.id.uuidString
        Task {
            defer { addingKey = nil }
            _ = await store.addKeyToAgent(key)
        }
    }

    /// Unloads an identity from the running agent.
    private func removeIdentity(keyBlob: [UInt8]) {
        Task { await store.removeAgentIdentity(keyBlob: keyBlob) }
    }

    /// Opens the Keychain "keep loaded" ssh-add command sheet.
    private func requestCopyCommand(_ key: SSHPublicKey) {
        commandSheetKey = key
    }

    /// Toggles "keep loaded after restart".
    private func setRemember(_ key: SSHPublicKey, _ on: Bool) {
        if on {
            addingKey = key.id.uuidString
            Task {
                defer { addingKey = nil }
                _ = await store.rememberKeyAcrossReboots(key)
            }
        } else {
            store.forgetKeyAcrossReboots(key)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selected {
            AgentIdentityDetailView(
                row: selected,
                isAdding: addingKey == selected.diskKey?.id.uuidString,
                isRemembered: selected.diskKey.map(store.isRememberedAcrossReboots) ?? false,
                onRemove: {
                    if let identity = selected.agentIdentity {
                        removeIdentity(keyBlob: identity.keyBlob)
                    }
                },
                onAdd: { if let diskKey = selected.diskKey { addToAgent(diskKey) } },
                onSetRemember: { on in if let diskKey = selected.diskKey { setRemember(diskKey, on) } },
                onCopyCommand: { if let diskKey = selected.diskKey { requestCopyCommand(diskKey) } },
                onCopyFingerprint: { copy(selected.fingerprint) }
            )
            .id(selected.selectionID)
        } else {
            ContentUnavailableView(
                "Select an identity",
                systemImage: "person.badge.key",
                description: Text("Pick an identity on the left to see its details and actions."))
        }
    }

    private var selected: AgentKeyRow? {
        guard let selectedKey else { return nil }
        return rows.first { $0.selectionID == selectedKey }
    }

    private var loadedRows: [AgentKeyRow] { rows.filter(\.isLoaded) }
    private var unloadedRows: [AgentKeyRow] { rows.filter { !$0.isLoaded } }

    // MARK: - Full-screen states

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No identities", systemImage: "key.slash")
        } description: {
            Text("The agent has no keys loaded and no keys were found on disk.")
        } actions: {
            Button("Refresh") { Task { await store.refreshAgent() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableState: some View {
        ContentUnavailableView {
            Label("No SSH agent running", systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text(
                "`SSH_AUTH_SOCK` is not set, so no agent is reachable. Start one "
                    + "(for example `eval $(ssh-agent)`) in your shell, then refresh.")
        } actions: {
            Button("Refresh") { Task { await store.refreshAgent() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't reach the agent", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await store.refreshAgent() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Clipboard

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Detail pane

private struct AgentIdentityDetailView: View {
    let row: AgentKeyRow
    /// True while this key is being loaded into the agent — shows a spinner.
    let isAdding: Bool
    /// Whether the key's passphrase is remembered for reload-at-login.
    let isRemembered: Bool
    let onRemove: () -> Void
    let onAdd: () -> Void
    let onSetRemember: (Bool) -> Void
    let onCopyCommand: () -> Void
    let onCopyFingerprint: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                header
                detailsCard
                actionsCard
            }
            .padding(Spacing.xxxl)
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.md) {
            IconTile(
                systemImage: row.diskKey != nil ? "key.fill" : "person.badge.key.fill",
                color: TilePalette.agent, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentKeyCorrelation.displayName(row)).font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text(row.typeLabel).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.lg)
            StatusPill(kind: row.isLoaded ? .ok : .idle, text: row.isLoaded ? "Loaded" : "Not loaded")
            primaryAction
            moreMenu
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if row.isLoaded {
            ChromeButton(title: "Remove from Agent", systemImage: "minus.circle", kind: .secondary, tint: .red) {
                onRemove()
            }
        } else if row.diskKey?.privateKeyURL != nil {
            if isAdding {
                ProgressView().controlSize(.small).frame(width: 120, height: 30)
            } else {
                ChromeButton(title: "Add to Agent", systemImage: "plus.circle", kind: .prominent) { onAdd() }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if row.isOnDiskOnly, row.diskKey?.privateKeyURL != nil {
                Button("Copy ssh-add Command (Keychain)…") { onCopyCommand() }
            }
            if !row.fingerprint.isEmpty {
                Button("Copy Fingerprint") { onCopyFingerprint() }
            }
            if let fileURL = row.diskKey?.publicKeyURL ?? row.diskKey?.privateKeyURL {
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 29)
                .background(.controlWash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(
                        Color.cardBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private var detailsCard: some View {
        CardSection("Details") {
            CardRow {
                RowLabel("Status", width: 150)
                Circle().fill((row.isLoaded ? Color.green : .secondary)).frame(width: 7, height: 7)
                Text(row.isLoaded ? "Loaded" : "Not loaded").font(.system(size: 13, weight: .medium))
                Spacer(minLength: Spacing.sm)
            }
            valueRow("Fingerprint", row.fingerprint.isEmpty ? "Unavailable" : row.fingerprint, mono: true)
            if !row.comment.isEmpty {
                valueRow("Comment", row.comment)
            }
            if let diskKey = row.diskKey {
                if diskKey.privateKeyURL != nil {
                    CardRow {
                        RowLabel("Keep loaded after restart", width: 220)
                        Spacer(minLength: Spacing.sm)
                        Toggle("", isOn: Binding(get: { isRemembered }, set: { onSetRemember($0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(isAdding)
                    }
                }
                valueRow("Identity file", diskKey.identityFilePath, mono: true)
                if let url = diskKey.publicKeyURL { fileRow("Public key", url: url) }
                if let url = diskKey.privateKeyURL { fileRow("Private key", url: url) }
            } else {
                CardRow {
                    RowLabel("Source", width: 150)
                    Text("Loaded from outside the SSH folder — e.g. a hardware key, 1Password, or Secretive.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.sm)
                }
            }
        }
    }

    private var actionsCard: some View {
        CardSection("Actions") {
            if row.isOnDiskOnly, row.diskKey?.privateKeyURL != nil {
                ActionRow(icon: "doc.on.doc", label: "Copy ssh-add Command (Keychain)…") { onCopyCommand() }
            }
            if !row.fingerprint.isEmpty {
                ActionRow(icon: "doc.on.doc", label: "Copy Fingerprint") { onCopyFingerprint() }
            }
            if let fileURL = row.diskKey?.publicKeyURL ?? row.diskKey?.privateKeyURL {
                ActionRow(icon: "folder", label: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        }
    }

    private func valueRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        CardRow {
            RowLabel(label, width: 150)
            Text(value)
                .font(mono ? .system(size: 13, weight: .medium).monospaced() : .system(size: 13, weight: .medium))
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Spacing.sm)
        }
    }

    private func fileRow(_ label: String, url: URL) -> some View {
        CardRow {
            RowLabel(label, width: 150)
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .medium).monospaced())
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Spacing.sm)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - Keychain-persistence fallback sheet

/// The fallback for one specific case: keeping a key loaded *across reboots*.
/// The "Add to Agent" button already loads keys in-app over the socket, but a
/// socket-loaded key only lasts the agent session. `ssh-add --apple-use-keychain`
/// stores the passphrase in the macOS Keychain so the system agent auto-reloads it
/// after a restart — an Apple `ssh-add` integration we can't replicate in-app — so
/// for that we hand the user the exact command to run.
struct AddToAgentSheet: View {
    let key: SSHPublicKey
    @Environment(\.dismiss) private var dismiss
    @State private var useKeychain = true
    @State private var copied = false

    private var command: String {
        SSHAgentService.addCommand(for: key, useKeychain: useKeychain) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep “\(key.name)” loaded across reboots").font(.headline)
                    Text(key.typeLabel).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Text(
                "The **Add to Agent** button loads a key for the current session. "
                    + "To have it survive a reboot, run this in your terminal — the "
                    + "passphrase is typed into `ssh-add` and stored in your Keychain; "
                    + "this app never sees it."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Remember passphrase in macOS Keychain", isOn: $useKeychain)

            HStack(spacing: 8) {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: useKeychain) { _, _ in copied = false }
    }
}
