import AppKit
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import SwiftUI

struct KnownHostDetail: View {
    let group: KnownHostGroup
    let outcome: VerifyOutcome?
    let isVerifying: Bool
    let linkedBlockID: HostBlock.ID?
    let onVerify: () -> Void
    let onResolve: () -> Void
    let onCopyFingerprints: () -> Void
    let onReveal: () -> Void
    let onDeleteEntry: (KnownHostEntry) -> Void
    let onDeleteAll: () -> Void
    let onCopyEntry: (KnownHostEntry) -> Void
    let onConnect: () -> Void
    let onSetMarker: (KnownHostMarker, KnownHostEntry) -> Void
    let onRevealInEditor: (HostBlock.ID) -> Void
    let onCreateConfigBlock: () -> Void
    var offer = PeerAlgorithmOffer()

    @Environment(HostKeyMonitor.self) private var monitor

    @State private var showHistorySheet = false
    @State private var historyRecords: [AppDatabase.HostKeyCheckRecord] = []
    @State private var isLoadingHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                header
                if isVerifying || outcome != nil { verifyBanner }
                if group.connectHost != nil { securityCard }
                if group.kind != .hashed { configLinkCard }
                if !group.configAliases.isEmpty { configuredAsCard }
                if !group.aliases.isEmpty { aliasesCard }
                if !offer.isEmpty { offeredAlgorithmsCard }
                keysCard
                actionsCard
                if group.kind == .hashed { hashedNote }
            }
            .padding(Spacing.xxxl)
        }
        .sheet(isPresented: $showHistorySheet) {
            HostKeyHistorySheet(
                groupName: group.displayName, records: historyRecords,
                isLoading: isLoadingHistory)
        }
    }

    private var offeredAlgorithmsCard: some View {
        let weaknesses = offer.weaknesses
        return CardSection("Server Offers") {
            ForEach(ServerAlgorithmAudit.Role.allCases, id: \.self) { role in
                let verdicts = offer.verdicts(for: role)
                if !verdicts.isEmpty {
                    CardRow(minHeight: 40) {
                        RowLabel(role.label)
                        Spacer(minLength: Spacing.sm)
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(verdicts) { verdict in
                                HStack(spacing: 4) {
                                    Text(verdict.name)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(verdict.isWeak ? .primary : .secondary)
                                    if let severity = verdict.severity {
                                        Image(systemName: severity.symbol)
                                            .font(.system(size: 9))
                                            .foregroundStyle(severity == .error ? .red : .orange)
                                            .help(verdict.reason)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !weaknesses.isEmpty {
                CardRow(minHeight: 40) {
                    Text(
                        "\(weaknesses.count) offered algorithm\(weaknesses.count == 1 ? "" : "s") "
                            + "\(weaknesses.count == 1 ? "is" : "are") weak. This connection never picks them, "
                            + "but another client might."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: group.kind.symbol, color: group.kind.tile, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(group.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1).truncationMode(.middle)
                    if group.revealedCandidate != nil {
                        Text("matched by hash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
                    }
                }
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.lg)
            if group.isConnectable {
                ChromeButton(title: "Connect", systemImage: "terminal", action: onConnect)
            }
            if group.connectHost != nil {
                if isVerifying {
                    ProgressView().controlSize(.small).frame(width: 92)
                } else {
                    ChromeButton(
                        title: "Verify", systemImage: "checkmark.shield",
                        kind: .prominent, action: onVerify
                    )
                    .accessibilityIdentifier("known-hosts-verify")
                }
            }
            moreMenu
        }
    }

    private var headerSubtitle: String {
        let keys = group.entries.count == 1 ? "1 key" : "\(group.entries.count) keys"
        switch group.kind {
        case .hashed: return "\(keys) · hashed host names"
        case .ipAddress, .hostname:
            var parts: [String] = []
            if group.displayName != group.title { parts.append(group.title) }
            parts.append(keys)
            if group.connectPort != 22 { parts.append("port \(group.connectPort)") }
            return parts.joined(separator: " · ")
        }
    }

    private var moreMenu: some View {
        Menu {
            if group.isConnectable {
                Button("Connect") { onConnect() }
            }
            if group.connectHost != nil {
                Button("Verify Host Key") { onVerify() }
            }
            Button("Copy Fingerprint\(group.entries.count > 1 ? "s" : "")") { onCopyFingerprints() }
            Button("Reveal known_hosts in Finder") { onReveal() }
            Divider()
            Button("Delete All Keys for Host", role: .destructive) { onDeleteAll() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 29)
                .background(.controlWash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.cardBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    @ViewBuilder
    private var verifyBanner: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: Spacing.lg) {
            Group {
                if isVerifying {
                    ProgressView().controlSize(.small)
                } else if let outcome {
                    Image(systemName: outcome.status.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(outcome.status.color)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(isVerifying ? "Verifying…" : (outcome?.headline ?? ""))
                    .font(.system(size: 13, weight: .semibold))
                Text(
                    isVerifying
                        ? "Connecting to \(group.title) to read its current host key."
                        : (outcome?.detail ?? "")
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let fp = outcome?.fingerprint {
                    Text(fp)
                        .font(.system(size: 11.5).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: Spacing.sm)
            if outcome?.scannedKeyToTrust != nil {
                ChromeButton(
                    title: "Resolve…",
                    systemImage: "checkmark.seal",
                    kind: .prominent,
                    tint: outcome?.isChange == true ? .orange : nil,
                    action: onResolve)
            }
        }
        .padding(Spacing.lg)
        .background((outcome?.status.color ?? .secondary).opacity(0.08), in: shape)
        .overlay(shape.strokeBorder((outcome?.status.color ?? .secondary).opacity(0.25), lineWidth: 1))
    }

    private var securityCard: some View {
        let record = monitor.latestCheckPerHost[group.id]
        return CardSection("Security") {
            CardRow(minHeight: record != nil ? 54 : 46) {
                Image(systemName: record.map { hostCheckOutcomeSymbol($0.outcome) } ?? "shield.slash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(record.map { hostCheckOutcomeColor($0.outcome) } ?? Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    if let record {
                        Text("Last checked \(record.checkedAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 12.5, weight: .medium))
                        HStack(spacing: 6) {
                            Text(hostCheckOutcomeName(record.outcome))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            if !record.keyType.isEmpty {
                                Text(record.keyType)
                                    .font(.system(size: 11, weight: .medium).monospaced())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.secondary.opacity(0.1), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !record.fingerprint.isEmpty && record.outcome == "verified" {
                            Text(record.fingerprint)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                                .padding(.top, 1)
                        }
                    } else {
                        Text("Never checked")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Tap Verify to probe the server\u{2019}s current host key.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: Spacing.sm)
                if record != nil {
                    Button {
                        isLoadingHistory = true
                        historyRecords = []
                        showHistorySheet = true
                        Task {
                            guard let db = AppDatabase.shared else {
                                isLoadingHistory = false
                                return
                            }
                            historyRecords = (try? await db.loadHostKeyHistory(groupID: group.id)) ?? []
                            isLoadingHistory = false
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("View full check history")
                }
            }
        }
    }

    @ViewBuilder
    private var configLinkCard: some View {
        let isCaPattern =
            entries.allSatisfy { $0.resolvedMarker == .certAuthority }
            && (group.title.contains("*") || group.title.contains("?"))
        if !isCaPattern {
            CardSection("Config Link") {
                CardRow {
                    Image(systemName: linkedBlockID != nil ? "arrow.right.circle" : "plus.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(linkedBlockID != nil ? .blue : .secondary)
                        .frame(width: 22)
                    if let blockID = linkedBlockID {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Host block found")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("Jump to the matching ssh_config entry in the editor.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Spacing.sm)
                        Button("Go to Host") { onRevealInEditor(blockID) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No config entry")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("Create a Host block with HostName pre-filled, then add User, Port, or IdentityFile.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Spacing.sm)
                        Button("Create Entry…") { onCreateConfigBlock() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var entries: [KnownHostEntry] { group.entries }

    private var configuredAsCard: some View {
        CardSection("Configured As") {
            CardRow {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                FlowChips(
                    items: group.configAliases,
                    onTap: linkedBlockID.map { id in
                        { _ in onRevealInEditor(id) }
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    private var aliasesCard: some View {
        CardSection("Also Known As") {
            CardRow {
                FlowChips(items: group.aliases)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
    }

    private var keysCard: some View {
        CardSection("Host Keys") {
            ForEach(group.entries) { entry in
                keyRow(entry)
            }
        }
    }

    private func keyRow(_ entry: KnownHostEntry) -> some View {
        CardRow(minHeight: 46) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let marker = entry.marker {
                        Text(marker)
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(markerColor(marker).opacity(0.15), in: Capsule())
                            .foregroundStyle(markerColor(marker))
                    }
                    Text(entry.keyType)
                        .font(.system(size: 12.5, weight: .medium).monospaced())
                    if matchesVerified(entry) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                            .help("Matches the key the server presented")
                    }
                }
                Text(entry.fingerprint ?? "Fingerprint unavailable")
                    .font(.system(size: 11.5).monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                markerControl(for: entry)
            }
            Spacer(minLength: Spacing.sm)
            Button {
                onCopyEntry(entry)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy fingerprint")
            .disabled(entry.fingerprint == nil)

            Button {
                onDeleteEntry(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Delete this key")
        }
        .contextMenu {
            if entry.fingerprint != nil { Button("Copy Fingerprint") { onCopyEntry(entry) } }
            Button("Delete Key", role: .destructive) { onDeleteEntry(entry) }
        }
    }

    @ViewBuilder
    private func markerControl(for entry: KnownHostEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(
                "Trust",
                selection: Binding(
                    get: { entry.resolvedMarker },
                    set: { onSetMarker($0, entry) }
                )
            ) {
                ForEach(KnownHostMarker.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(entry.resolvedMarker.helpText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if entry.resolvedMarker == .certAuthority
                && !(group.title.contains("*") || group.title.contains("?"))
            {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("CA entries typically cover a host pattern (e.g. *.corp.example.com), not a single host.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 4)
    }

    private func matchesVerified(_ entry: KnownHostEntry) -> Bool {
        guard let fp = outcome?.fingerprint, case .verified = outcome else { return false }
        return entry.fingerprint == fp
    }

    private func markerColor(_ marker: String) -> Color {
        marker.lowercased().contains("revoked") ? .red : .orange
    }

    private var actionsCard: some View {
        CardSection("Actions") {
            if group.isConnectable {
                ActionRow(icon: "terminal", label: "Connect") { onConnect() }
            }
            if group.connectHost != nil {
                ActionRow(icon: "checkmark.shield", label: "Verify Host Key") { onVerify() }
            }
            ActionRow(
                icon: "doc.on.doc",
                label: "Copy Fingerprint\(group.entries.count > 1 ? "s" : "")"
            ) { onCopyFingerprints() }
            ActionRow(icon: "folder", label: "Reveal known_hosts in Finder") { onReveal() }
            ActionRow(icon: "trash", label: "Delete All Keys for Host", role: .destructive) { onDeleteAll() }
        }
    }

    private var hashedNote: some View {
        Label {
            Text(
                "These entries have hashed host names (HashKnownHosts), so the original host can't be recovered — they can't be grouped by name or verified against a live server. You can still inspect and delete them."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
