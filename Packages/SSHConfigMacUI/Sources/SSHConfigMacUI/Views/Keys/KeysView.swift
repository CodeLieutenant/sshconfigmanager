//
//  KeysView.swift
//  sshconfigmanager
//
//  The SSH Keys screen — restyled to the Liquid Glass redesign: a frosted screen header,
//  a glass key list grouped by type, and a detail pane of lifted cards (Details · Actions ·
//  Randomart). Behaviour (selection by file name, generate/refresh, deploy, clipboard) is
//  unchanged from the former `List` + grouped-detail version.
//

import AppKit
import SSHConfigCore
import SwiftUI

struct KeysView: View {
    @Environment(ConfigStore.self) private var store
    // Select by file name, not the SSHPublicKey UUID: discovery reassigns UUIDs on
    // every reload(), so a name survives Refresh / key generation where an id won't.
    @State private var selectedName: String?
    @State private var showingGenerateSheet = false
    /// Set when arriving via the Issues "Generate Replacement" deep-link, to pre-fill
    /// the sheet with the weak key's comment.
    @State private var generationRequest: ConfigStore.KeyGenerationRequest?
    /// The key whose ssh-copy-id deploy sheet is open, if any.
    @State private var deployTarget: SSHPublicKey?
    /// The key pending delete confirmation, if any.
    @State private var deleteCandidate: SSHPublicKey?
    @State private var toastMessage: String?

    var body: some View {
        content
            .onAppear(perform: selectFirstIfNeeded)
            .onChange(of: store.publicKeys.map(\.name)) { _, _ in selectFirstIfNeeded() }
            // Consume a "Generate Replacement" deep-link from the Issues screen.
            .onChange(of: store.pendingKeyGeneration, initial: true) { _, request in
                guard let request else { return }
                store.pendingKeyGeneration = nil
                generationRequest = request
                showingGenerateSheet = true
            }
            .sheet(isPresented: $showingGenerateSheet) {
                GenerateKeySheet(initialComment: generationRequest?.comment ?? "") { newKey in
                    selectedName = newKey.name
                    toastMessage = "Key generated"
                }
            }
            .sheet(item: $deployTarget) { key in
                DeployKeySheet(
                    keyName: key.name,
                    publicKeyLine: publicKeyLine(key) ?? "",
                    hasPrivateKey: key.privateKeyURL != nil,
                    hosts: store.allHostBlocks.filter { !$0.isWildcard },
                    deploy: { store.deployKey(publicKeyLine(key) ?? "", to: $0) },
                    copyCommand: { store.copyDeployCommand(publicKeyLine(key) ?? "", to: $0) })
            }
            .confirmationDialog(deleteTitle, isPresented: deleteBinding, presenting: deleteCandidate) { key in
                if store.hostsUsing(key).isEmpty {
                    Button("Delete", role: .destructive) { deleteKey(key) }
                } else {
                    Button("Yes, I've Backed It Up — Delete", role: .destructive) { deleteKey(key) }
                }
                Button("Cancel", role: .cancel) { deleteCandidate = nil }
            } message: { key in
                Text(deleteMessage(key))
            }
            .toast($toastMessage)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                tile: (icon: "key.fill", color: TilePalette.keys),
                title: "SSH Keys", subtitle: subtitle
            ) {
                ChromeButton(title: "Generate Key…", systemImage: "key.viewfinder", kind: .secondary) {
                    requestGenerate()
                }
                .accessibilityIdentifier("generate-key-button")
                ChromeButton(icon: "arrow.clockwise", help: "Re-scan the SSH folder") { store.reload() }
            }
            if store.publicKeys.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    keyList.frame(width: 280)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(WindowWash())
    }

    private var subtitle: String {
        let total = store.publicKeys.count
        guard total > 0 else { return "" }
        let withPrivate = store.publicKeys.filter { $0.privateKeyURL != nil }.count
        return total == 1 ? "1 key" : "\(total) keys · \(withPrivate) with private key"
    }

    /// Keep a key selected so the detail pane is never empty.
    private func selectFirstIfNeeded() {
        if selectedName == nil || !store.publicKeys.contains(where: { $0.name == selectedName }) {
            selectedName = store.publicKeys.first?.name
        }
    }

    // MARK: - Key list

    private var keyList: some View {
        // A real `List` (not a custom ScrollView) so ↑/↓ keyboard navigation works for
        // free; styled to the glass look with a hidden scroll background + material.
        List(selection: $selectedName) {
            ForEach(typeGroups, id: \.type) { group in
                Section(group.type) {
                    ForEach(group.keys) { key in
                        keyRow(key)
                            .tag(key.name)
                            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                            .listRowSeparator(.hidden)
                            .contextMenu { rowMenu(key) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 280)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.appSeparator).frame(width: 1) }
    }

    private func keyRow(_ key: SSHPublicKey) -> some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: "key.fill", color: TilePalette.keys)
            VStack(alignment: .leading, spacing: 1) {
                Text(key.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(key.fingerprint.isEmpty ? "No fingerprint" : key.fingerprint)
                    .font(.system(size: 11).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.sm)
            KeyAvailabilityBadge(key: key)
        }
        .frame(minHeight: 40)
    }

    @ViewBuilder
    private func rowMenu(_ key: SSHPublicKey) -> some View {
        if key.publicKeyURL != nil {
            Button("Copy Public Key") { copyPublicKey(key) }
            Button("Copy Public Key (no comment)") { copyPublicKeyWithoutComment(key) }
            Button("Deploy to Host…") { requestDeploy(key) }
        }
        if key.privateKeyURL != nil {
            Button("Copy Private Key") { copyPrivateKey(key) }
        }
        if !key.fingerprint.isEmpty {
            Button("Copy Fingerprint") { copy(key.fingerprint) }
        }
        if let fileURL = key.publicKeyURL ?? key.privateKeyURL {
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
        Divider()
        Button("Delete Key…", role: .destructive) { deleteCandidate = key }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let key = selected {
            KeyDetailView(
                key: key,
                copyPublicKey: { copyPublicKey(key) },
                copyPublicKeyWithoutComment: { copyPublicKeyWithoutComment(key) },
                copyPrivateKey: { copyPrivateKey(key) },
                copyFingerprint: { copy(key.fingerprint) },
                deploy: { requestDeploy(key) },
                delete: { deleteCandidate = key }
            )
            .id(key.name)
        } else {
            ContentUnavailableView(
                "Select a key",
                systemImage: "key",
                description: Text("Pick a key on the left to see its fingerprint, files and actions."))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No keys found", systemImage: "key")
        } description: {
            Text("No SSH keys were found in your SSH folder. Generate one to get started.")
        } actions: {
            Button("Generate Key…") { requestGenerate() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestGenerate() {
        generationRequest = nil
        showingGenerateSheet = true
    }

    /// Deploys a key to a host with ssh-copy-id.
    private func requestDeploy(_ key: SSHPublicKey) {
        deployTarget = key
    }

    // MARK: - Delete

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })
    }

    private var deleteTitle: String {
        guard let deleteCandidate else { return "Delete key?" }
        return store.hostsUsing(deleteCandidate).isEmpty
            ? "Delete “\(deleteCandidate.name)”?"
            : "“\(deleteCandidate.name)” is still in use"
    }

    private func deleteMessage(_ key: SSHPublicKey) -> String {
        let hosts = store.hostsUsing(key)
        guard !hosts.isEmpty else {
            return
                "This removes the key file(s) from ~/.ssh (a backup is kept first). This can't be undone from within the app."
        }
        let hostWord = hosts.count == 1 ? "host" : "hosts"
        let hostList = hosts.joined(separator: ", ")
        return
            "This key is referenced by \(hostWord) \(hostList). Deleting it will break SSH access there unless you've already replaced it or have a backup elsewhere."
    }

    private func deleteKey(_ key: SSHPublicKey) {
        store.deleteOrphanedKey(privateKeyPath: key.privateKeyURL?.path, publicKeyPath: key.publicKeyURL?.path)
        deleteCandidate = nil
        toastMessage = "Key deleted"
    }

    // MARK: - Data

    private struct TypeGroup {
        let type: String
        let keys: [SSHPublicKey]
    }

    /// Keys grouped by their friendly type, with the common modern types first.
    private var typeGroups: [TypeGroup] {
        let order = ["Ed25519", "ECDSA", "RSA", "Security Key", "DSA"]
        return Dictionary(grouping: store.publicKeys, by: \.typeLabel)
            .map { TypeGroup(type: $0.key, keys: $0.value.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                let l = order.firstIndex(of: lhs.type) ?? order.count
                let r = order.firstIndex(of: rhs.type) ?? order.count
                return l != r ? l < r : lhs.type < rhs.type
            }
    }

    private var selected: SSHPublicKey? {
        guard let selectedName else { return nil }
        return store.publicKeys.first { $0.name == selectedName }
    }

    // MARK: - Clipboard

    /// The trimmed `.pub` line (`algo base64 [comment]`), or `nil` for a key with
    /// no public half on disk.
    private func publicKeyLine(_ key: SSHPublicKey) -> String? {
        guard let url = key.publicKeyURL,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyPublicKey(_ key: SSHPublicKey) {
        guard let line = publicKeyLine(key) else { return }
        copy(line)
        toastMessage = "Public key copied"
    }

    /// Copies `algo base64` without the trailing comment — what some providers
    /// (and older `authorized_keys` tooling) expect.
    private func copyPublicKeyWithoutComment(_ key: SSHPublicKey) {
        guard let line = publicKeyLine(key) else { return }
        let stripped = line.split(
            separator: " ", maxSplits: 2,
            omittingEmptySubsequences: true
        ).prefix(2).joined(separator: " ")
        copy(stripped)
        toastMessage = "Public key copied"
    }

    /// Copies the raw private key. Marked concealed so clipboard managers don't
    /// retain the secret (the key text itself is preserved exactly — no trimming).
    private func copyPrivateKey(_ key: SSHPublicKey) {
        guard let url = key.privateKeyURL,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        copy(text, concealed: true)
        toastMessage = "Private key copied"
    }

    /// `concealed` adds the nspasteboard.org concealed/transient markers so clipboard
    /// managers treat the contents as a secret and avoid persisting it to history.
    private func copy(_ string: String, concealed: Bool = false) {
        let pasteboard = NSPasteboard.general
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pasteboard.clearContents()
        if concealed {
            pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
            pasteboard.setString(string, forType: .string)
            pasteboard.setString(string, forType: concealedType)
            pasteboard.setString("", forType: transientType)
        } else {
            pasteboard.setString(string, forType: .string)
        }
    }
}

// MARK: - Availability badge

/// A small icon conveying which halves of the key pair are present on disk.
private struct KeyAvailabilityBadge: View {
    let key: SSHPublicKey
    var onAccent: Bool = false

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(onAccent ? Color.white.opacity(0.9) : color)
            .help(helpText)
    }

    private var hasPublic: Bool { key.publicKeyURL != nil }
    private var hasPrivate: Bool { key.privateKeyURL != nil }

    private var symbol: String {
        if hasPublic && hasPrivate { return "checkmark.seal.fill" }
        if hasPrivate { return "lock.fill" }
        return "key"
    }

    private var color: Color {
        if hasPublic && hasPrivate { return .green }
        if hasPrivate { return .orange }
        return .secondary
    }

    private var helpText: String {
        if hasPublic && hasPrivate { return "Public and private key present" }
        if hasPrivate { return "Private key only (no .pub)" }
        return "Public key only"
    }
}

// MARK: - Detail pane

private struct KeyDetailView: View {
    let key: SSHPublicKey
    let copyPublicKey: () -> Void
    let copyPublicKeyWithoutComment: () -> Void
    let copyPrivateKey: () -> Void
    let copyFingerprint: () -> Void
    let deploy: () -> Void
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                keyHeader
                HStack(alignment: .top, spacing: Spacing.xl) {
                    VStack(alignment: .leading, spacing: Spacing.xxl) {
                        detailsCard
                        actionsCard
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if randomart != nil {
                        randomartCard.frame(width: 212)
                    }
                }
            }
            .padding(Spacing.xxxl)
        }
    }

    private var keyHeader: some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: "key.fill", color: TilePalette.keys, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(key.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text(key.typeLabel).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.lg)
            if key.publicKeyURL != nil {
                ChromeButton(title: "Copy Public Key", systemImage: "doc.on.doc", kind: .prominent) { copyPublicKey() }
            }
            Menu {
                if key.publicKeyURL != nil {
                    Button("Copy Public Key (no comment)") { copyPublicKeyWithoutComment() }
                    Button("Deploy to Host…") { deploy() }
                    Divider()
                }
                if key.privateKeyURL != nil {
                    Button("Copy Private Key") { copyPrivateKey() }
                }
                if !key.fingerprint.isEmpty {
                    Button("Copy Fingerprint") { copyFingerprint() }
                }
                if let fileURL = key.publicKeyURL ?? key.privateKeyURL {
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                }
                Divider()
                Button("Delete Key…", role: .destructive) { delete() }
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
    }

    private var detailsCard: some View {
        CardSection("Details") {
            valueRow("Fingerprint", key.fingerprint.isEmpty ? "Unavailable" : key.fingerprint, mono: true)
            if let hex = key.sha256HexFingerprint {
                valueRow("SHA256 (hex)", hex, mono: true)
            }
            if !key.comment.isEmpty {
                valueRow("Comment", key.comment)
            }
            valueRow("Identity file", key.identityFilePath, mono: true)
            if let url = key.publicKeyURL { fileRow("Public key", url: url) }
            if let url = key.privateKeyURL { fileRow("Private key", url: url) }
        }
    }

    private func valueRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        CardRow {
            RowLabel(label, width: 120)
            Text(value)
                .font(mono ? .system(size: 13, weight: .medium).monospaced() : .system(size: 13, weight: .medium))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.sm)
        }
    }

    private func fileRow(_ label: String, url: URL) -> some View {
        CardRow {
            RowLabel(label, width: 120)
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .medium).monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.sm)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var actionsCard: some View {
        CardSection("Actions") {
            if key.publicKeyURL != nil {
                ActionRow(icon: "doc.on.doc", label: "Copy Public Key (no comment)") { copyPublicKeyWithoutComment() }
                ActionRow(icon: "square.and.arrow.up", label: "Deploy to Host…") { deploy() }
            }
            if key.privateKeyURL != nil {
                ActionRow(icon: "doc.on.doc", label: "Copy Private Key") { copyPrivateKey() }
            }
            if let fileURL = key.publicKeyURL ?? key.privateKeyURL {
                ActionRow(icon: "folder", label: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
            ActionRow(icon: "trash", label: "Delete Key…", role: .destructive) { delete() }
        }
    }

    private var randomartCard: some View {
        CardSection("Randomart") {
            Text(randomart ?? "")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.appCode, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .padding(14)
        }
    }

    /// The OpenSSH "drunken bishop" art for this key's SHA-256 fingerprint, or nil
    /// if no fingerprint is available (e.g. a classic-PEM private key with no `.pub`).
    private var randomart: String? {
        guard let digest = RandomArt.digest(fromSHA256Fingerprint: key.fingerprint) else { return nil }
        return RandomArt.drunkenBishop(digest: digest, title: randomartTitle, hashName: "SHA256")
    }

    private var randomartTitle: String {
        let type = key.typeLabel.uppercased()
        guard let bits = randomartBits else { return type }
        return "\(type) \(bits)"
    }

    /// Key size for the art's title, where it's intrinsic to the algorithm. RSA size
    /// isn't carried on the key, so RSA titles omit it — the art itself is unaffected.
    private var randomartBits: Int? {
        switch key.algorithm {
        case "ssh-ed25519": return 256
        case let a where a.contains("nistp256"): return 256
        case let a where a.contains("nistp384"): return 384
        case let a where a.contains("nistp521"): return 521
        default: return nil
        }
    }
}
