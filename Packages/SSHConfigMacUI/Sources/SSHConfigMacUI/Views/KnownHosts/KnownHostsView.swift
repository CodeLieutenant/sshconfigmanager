//
//  KnownHostsView.swift
//  sshconfigmanager
//

import AppKit
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import SwiftUI

struct KnownHostsView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(HostKeyMonitor.self) private var monitor

    /// Selection is by the group's stable id (a host field string), not a `KnownHostEntry`
    /// UUID: the store reassigns UUIDs on every reload, so an id survives add/delete/verify.
    @State private var selectedID: String?
    @State private var searchText = ""

    @State private var showAddSheet = false

    // Deletion confirmations.
    @State private var pendingDeleteEntry: KnownHostEntry?
    @State private var pendingDeleteGroupID: String?

    // Verification state, keyed by group id so a result survives reselection.
    @State private var verifying: Set<String> = []
    @State private var results: [String: VerifyOutcome] = [:]
    /// Algorithms each server advertised, captured during Verify. This is the only view
    /// that catches a server which *supports* something broken — the engine implements
    /// nothing weak, so it would never negotiate one.
    @State private var offers: [String: PeerAlgorithmOffer] = [:]
    /// A changed/new key the user is resolving — drives the Replace / Add / Delete dialog.
    @State private var resolving: ResolutionContext?

    // Feature 1: Hashed host reveal
    /// Session-scoped reveal cache; built by bulk-reveal ("Reveal hashed") and search.
    @State private var revealedNames: [KnownHostEntry.ID: String] = [:]
    @State private var isRevealingHashed = false

    // Feature 3: Cleanup / Review
    @State private var showReviewSheet = false
    @State private var reviewFindings: [KnownHostEntry.ID: KnownHostsAudit.Finding] = [:]

    // Feature 4: Link config — create sheet
    @State private var showCreateConfigSheet = false
    @State private var createConfigHost = ""
    @State private var createConfigAlias = ""

    // Feature 5: Connect — revoked confirm dialog
    @State private var pendingConnectRevoked: KnownHostGroup?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                tile: ("checkmark.shield.fill", TilePalette.knownHosts),
                title: "Known Hosts", subtitle: subtitle
            ) {
                if hasVerifiableGroups { freshnessPill }
                reviewButton
                fileMenu
                ChromeButton(icon: "plus", help: "Add a known_hosts entry") {
                    gated { showAddSheet = true }
                }
                ChromeButton(icon: "arrow.clockwise", help: "Re-read known_hosts") { store.reload() }
            }

            if let change = store.externalKnownHostsChange {
                externalChangeBanner(change)
            }

            if store.knownHosts.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 280)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(WindowWash())
        .onAppear {
            selectFirstIfNeeded()
            consumePendingSelection()
        }
        .onChange(of: store.knownHosts.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .onChange(of: store.pendingKnownHostsSelection) { _, _ in consumePendingSelection() }
        .alert("Delete this host key?", isPresented: deleteEntryBinding) {
            Button("Cancel", role: .cancel) { pendingDeleteEntry = nil }
            Button("Delete", role: .destructive) {
                if let entry = pendingDeleteEntry { store.deleteKnownHost(entry) }
                pendingDeleteEntry = nil
            }
        } message: {
            Text("Removing this entry means ssh will ask to re-verify the host's key on the next connection.")
        }
        .alert("Delete all keys for this host?", isPresented: deleteGroupBinding) {
            Button("Cancel", role: .cancel) { pendingDeleteGroupID = nil }
            Button("Delete All", role: .destructive) {
                if let g = groups.first(where: { $0.id == pendingDeleteGroupID }) {
                    store.deleteKnownHosts(g.entries)
                }
                pendingDeleteGroupID = nil
            }
        } message: {
            Text(
                "Every stored key for this host will be removed. ssh will treat it as a brand-new host next time you connect."
            )
        }
        .confirmationDialog(resolveTitle, isPresented: resolveBinding, presenting: resolving) { ctx in
            if ctx.isChange {
                Button("Replace Trusted Key", role: .destructive) { resolve(ctx, replacingType: ctx.probe.keyType) }
                Button("Add as Additional Key") { resolve(ctx, replacingType: nil) }
                Button("Delete Old \(ctx.probe.keyType) Key", role: .destructive) { deleteOldKeys(ctx) }
            } else {
                Button("Add This Key") { resolve(ctx, replacingType: nil) }
            }
            Button("Cancel", role: .cancel) { resolving = nil }
        } message: { ctx in
            Text(resolveMessage(ctx))
        }
        .confirmationDialog(
            "This key is marked revoked — connect anyway?",
            isPresented: revokedConnectBinding,
            presenting: pendingConnectRevoked
        ) { group in
            Button("Connect", role: .destructive) { store.connect(knownHost: group) }
            Button("Cancel", role: .cancel) { pendingConnectRevoked = nil }
        } message: { group in
            Text(
                "\u{201C}\(group.displayName)\u{201D} has a @revoked marker. You explicitly distrusted this key. Connecting is unusual \u{2014} confirm if you know what you\u{2019}re doing."
            )
        }
        .sheet(isPresented: $showAddSheet) {
            AddKnownHostSheet(fileName: store.knownHostsFileName) { store.addKnownHostLine($0) }
        }
        .sheet(isPresented: $showReviewSheet) {
            ReviewKnownHostsView(findings: reviewFindings)
        }
        .sheet(isPresented: $showCreateConfigSheet) {
            CreateConfigBlockSheet(
                hostName: createConfigHost,
                suggestedAlias: createConfigAlias
            ) { alias in
                store.createConfigBlock(forKnownHost: createConfigHost, alias: alias)
                showCreateConfigSheet = false
            }
        }
    }

    // MARK: - Header

    private var subtitle: String {
        let n = store.knownHosts.count
        let count = n == 1 ? "1 entry" : "\(n) entries"
        let hostCount = groups.filter { $0.kind != .hashed }.count
        let hosts = hostCount == 1 ? "1 host" : "\(hostCount) hosts"
        return "\(store.knownHostsFileName) · \(hosts) · \(count)"
    }

    /// "Review Changes" button: runs static audit and opens the review sheet.
    private var reviewButton: some View {
        ChromeButton(icon: "doc.badge.gearshape", help: "Review known_hosts for issues") {
            reviewFindings = store.knownHostsStaticFindings()
            showReviewSheet = true
        }
    }

    /// The known_hosts file switcher.
    private var fileMenu: some View {
        Menu {
            ForEach(store.knownHostsFileChoices(), id: \.self) { name in
                Button {
                    gated { store.selectKnownHostsFile(named: name) }
                } label: {
                    Label(name, systemImage: name == store.knownHostsFileName ? "checkmark" : "doc")
                }
            }
            Divider()
            Button("Choose File…") { gated { store.chooseKnownHostsFile() } }
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
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
        .help("Switch known_hosts file")
    }

    private var freshnessPill: some View {
        let f = monitor.freshness
        return Button {
            gated { monitor.checkNow() }
        } label: {
            HStack(spacing: 5) {
                if monitor.isChecking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: f.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(f.tint.color)
                }
                Text(monitor.isChecking ? "Checking…" : monitor.freshnessShortLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.controlWash, in: Capsule())
            .overlay(Capsule().strokeBorder(f.tint == .ok ? Color.cardBorder : f.tint.color.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("\(monitor.freshnessLabel) · click to check every host's key now")
    }

    /// Shown when the real-time watcher (`ConfigStore.updateFileWatchers()`) detects
    /// `known_hosts` was written outside the app — e.g. `ssh` TOFU-adding a new host's
    /// key. `knownHosts` already reflects the fresh read; this just surfaces the diff.
    @ViewBuilder
    private func externalChangeBanner(_ change: KnownHostsChangeSummary) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: Spacing.lg) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("known_hosts changed outside SSH Config Manager")
                    .font(.system(size: 13, weight: .semibold))
                Text(externalChangeDetail(change))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            ChromeButton(title: "Dismiss", action: { store.dismissExternalKnownHostsChange() })
        }
        .padding(Spacing.lg)
        .background(Color.orange.opacity(0.08), in: shape)
        .overlay(shape.strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
    }

    private func externalChangeDetail(_ change: KnownHostsChangeSummary) -> String {
        var parts: [String] = []
        if !change.added.isEmpty {
            parts.append("\(change.added.count) key\(change.added.count == 1 ? "" : "s") added")
        }
        if !change.removed.isEmpty {
            parts.append("\(change.removed.count) key\(change.removed.count == 1 ? "" : "s") removed")
        }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Sidebar (grouped host list)

    private var sidebar: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, prompt: "Filter hosts")
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
            // Bulk reveal button — visible when there are unrevealed hashed entries.
            let hashedEntries = store.knownHosts.filter(\.isHashed)
            let unrevealed = hashedEntries.filter { revealedNames[$0.id] == nil }
            if !unrevealed.isEmpty {
                Button {
                    Task { await bulkReveal(hashed: hashedEntries) }
                } label: {
                    HStack(spacing: 5) {
                        if isRevealingHashed {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "eye")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(
                            isRevealingHashed
                                ? "Revealing…"
                                : "Reveal \(unrevealed.count) hashed \(unrevealed.count == 1 ? "entry" : "entries")"
                        )
                        .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(.controlWash)
                }
                .buttonStyle(.plain)
                .help("Try to match hashed entries against host names from your ssh_config")
            }
            Divider().overlay(Color.appSeparator)
            if filteredGroups.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(sections, id: \.sectionKey) { section in
                        Section(section.title) {
                            ForEach(section.groups) { group in
                                hostRow(group)
                                    .tag(group.id)
                                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                                    .listRowSeparator(.hidden)
                                    .contextMenu { rowMenu(group) }
                                    .accessibilityIdentifier("known-host-row-\(group.displayName)")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 280)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.appSeparator).frame(width: 1) }
    }

    private func hostRow(_ group: KnownHostGroup) -> some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: group.kind.symbol, color: group.kind.tile)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(group.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if group.revealedCandidate != nil {
                        Text("hash")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.orange.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
                    }
                    weakKeyBadge(for: group)
                }
                Text(group.rowDetail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Spacing.sm)
            verifyIndicator(for: group.id)
        }
        .frame(minHeight: 40)
    }

    /// Flags a host whose *every* stored key is weak. Judged per host, not per key: a
    /// server that also publishes an Ed25519 key is fine no matter what else it keeps
    /// around, since that is the one ssh negotiates.
    @ViewBuilder
    private func weakKeyBadge(for group: KnownHostGroup) -> some View {
        let verdicts = group.entries
            .filter { $0.resolvedMarker != .revoked }
            .map(ServerAlgorithmAudit.hostKeyVerdict(for:))
        if !verdicts.isEmpty, verdicts.allSatisfy(\.isWeak),
            let worst = ServerAlgorithmAudit.worstSeverity(in: verdicts), worst > .info,
            let reason = ServerAlgorithmAudit.weaknesses(in: verdicts).first?.reason
        {
            Text("weak")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(worst == .error ? .red : .orange)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background((worst == .error ? Color.red : Color.orange).opacity(0.1), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        (worst == .error ? Color.red : Color.orange).opacity(0.3), lineWidth: 0.5)
                )
                .help(reason)
                .accessibilityIdentifier("weak-host-key")
        }
    }

    @ViewBuilder
    private func verifyIndicator(for id: String) -> some View {
        if verifying.contains(id) {
            ProgressView().controlSize(.small)
        } else if let outcome = effectiveOutcome(for: id) {
            // Current session result (live verify or standing alert).
            Image(systemName: outcome.status.symbol)
                .font(.system(size: 12))
                .foregroundStyle(outcome.status.color)
                .help(outcome.headline)
        } else if let record = monitor.latestCheckPerHost[id] {
            // Persisted last-check badge — dimmer than a live result to signal "from a past sweep".
            Image(systemName: hostCheckOutcomeSymbol(record.outcome))
                .font(.system(size: 10))
                .foregroundStyle(hostCheckOutcomeColor(record.outcome).opacity(0.55))
                .help(
                    "Last checked \(record.checkedAt.formatted(.relative(presentation: .named))): \(hostCheckOutcomeName(record.outcome))"
                )
        }
    }

    @ViewBuilder
    private func rowMenu(_ group: KnownHostGroup) -> some View {
        if group.isConnectable {
            Button("Connect") { connectGroup(group) }
        }
        if group.connectHost != nil {
            Button("Verify Host Key") { verify(group) }
        }
        Button("Copy Fingerprint\(group.entries.count > 1 ? "s" : "")") { copyFingerprints(group) }
        Divider()
        Button("Delete All Keys for Host", role: .destructive) {
            gated { pendingDeleteGroupID = group.id }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let group = selectedGroup {
            KnownHostDetail(
                group: group,
                outcome: effectiveOutcome(for: group.id),
                isVerifying: verifying.contains(group.id),
                linkedBlockID: store.configBlock(forKnownHost: group.connectHost ?? group.title),
                onVerify: { verify(group) },
                onResolve: { requestResolve(group) },
                onCopyFingerprints: { copyFingerprints(group) },
                onReveal: { store.revealKnownHostsFileInFinder() },
                onDeleteEntry: { entry in gated { pendingDeleteEntry = entry } },
                onDeleteAll: { gated { pendingDeleteGroupID = group.id } },
                onCopyEntry: { entry in copy(entry.fingerprint ?? "") },
                onConnect: { connectGroup(group) },
                onSetMarker: { marker, entry in gated { store.setMarker(marker, on: entry) } },
                onRevealInEditor: { id in store.revealInEditor(id) },
                onCreateConfigBlock: {
                    let host = group.connectHost ?? group.title
                    createConfigHost = host
                    createConfigAlias = suggestedAlias(for: host)
                    showCreateConfigSheet = true
                },
                offer: offers[group.id] ?? PeerAlgorithmOffer()
            )
            .id(group.id)
        } else {
            ContentUnavailableView(
                "Select a host",
                systemImage: "checkmark.shield",
                description: Text(
                    "Pick a host on the left to see its keys, verify them against the live server, and remove stale entries."
                ))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No known hosts", systemImage: "checkmark.shield")
        } description: {
            Text(
                "\u{201C}\(store.knownHostsFileName)\u{201D} is empty or missing. Connect to a host, or add an entry to get started."
            )
        } actions: {
            Button("Add Entry…") { gated { showAddSheet = true } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection

    private var selectedGroup: KnownHostGroup? {
        groups.first { $0.id == selectedID }
            ?? filteredGroups.first { $0.id == selectedID }
    }

    private func selectFirstIfNeeded() {
        if selectedID == nil || !groups.contains(where: { $0.id == selectedID }) {
            selectedID = sections.first?.groups.first?.id
        }
    }

    // MARK: - Grouping

    /// Base groups from the full entry list, incorporating session-local bulk reveals.
    private var groups: [KnownHostGroup] {
        KnownHostGroup.build(
            from: store.knownHosts,
            configAliasesByHost: store.configAliasesByHost(),
            revealedNames: revealedNames)
    }

    /// Groups after applying the search filter. When the query is non-empty, also runs
    /// HMAC-SHA1 against unrevealed hashed entries so a typed hostname surfaces them.
    private var filteredGroups: [KnownHostGroup] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }

        var result = groups.filter { $0.matches(q) }

        // HMAC search against hashed entries not yet revealed in the session cache.
        let unrevealed = store.knownHosts.filter { $0.isHashed && revealedNames[$0.id] == nil }
        if !unrevealed.isEmpty {
            let matchedIDs = HashedHostSearch.matching(q, in: unrevealed)
            if !matchedIDs.isEmpty {
                let matched = unrevealed.filter { matchedIDs.contains($0.id) }
                let (host, port) = KnownHostGroup.connectTarget(for: q)
                let configAliases = store.configAliasesByHost()[q] ?? []
                let revealedGroup = KnownHostGroup(
                    id: "__search_revealed__:\(q)",
                    title: q,
                    aliases: [],
                    kind: KnownHostGroup.isIPLiteral(q) ? .ipAddress : .hostname,
                    connectHost: host,
                    connectPort: port,
                    entries: matched,
                    configAliases: configAliases,
                    revealedCandidate: q)
                result.append(revealedGroup)
            }
        }
        return result
    }

    private struct HostSection {
        let kind: KnownHostGroup.Kind
        let sectionKey: String
        let title: String
        let groups: [KnownHostGroup]
    }

    private var sections: [HostSection] {
        let order: [(KnownHostGroup.Kind, String)] = [
            (.hostname, "Hostnames"), (.ipAddress, "IP Addresses"), (.hashed, "Hashed"),
        ]
        return order.compactMap { kind, title in
            let g = filteredGroups.filter { $0.kind == kind }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return g.isEmpty ? nil : HostSection(kind: kind, sectionKey: "\(kind)", title: title, groups: g)
        }
    }

    private var hasVerifiableGroups: Bool { groups.contains { $0.connectHost != nil } }

    // MARK: - Connect

    private func connectGroup(_ group: KnownHostGroup) {
        if group.entries.allSatisfy({ $0.resolvedMarker == .revoked }) {
            pendingConnectRevoked = group
        } else {
            store.connect(knownHost: group)
        }
    }

    // MARK: - Bulk reveal (off main actor)

    @MainActor
    private func bulkReveal(hashed: [KnownHostEntry]) async {
        guard !isRevealingHashed else { return }
        isRevealingHashed = true
        let candidates = store.knownPlaintextNames()
        let revealed = await Task.detached(priority: .userInitiated) {
            HashedHostSearch.bulkReveal(hashed: hashed, candidates: candidates)
        }.value
        for (id, name) in revealed { revealedNames[id] = name }
        isRevealingHashed = false
    }

    // MARK: - Alias suggestion for create-config sheet

    private func suggestedAlias(for host: String) -> String {
        let clean =
            host
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        return clean.isEmpty ? "new-host" : clean
    }

    // MARK: - Verify

    private func verify(_ group: KnownHostGroup) {
        guard let host = group.connectHost else { return }
        verifying.insert(group.id)
        Task {
            let scanResult = await HostKeyScanner.scan(host: host, port: group.connectPort)
            verifying.remove(group.id)
            let probe: HostKeyScanner.Probe?
            let outcome: VerifyOutcome
            switch scanResult {
            case .success(let p):
                probe = p
                outcome = VerifyOutcome(probe: p, group: group)
                if !p.offer.isEmpty { offers[group.id] = p.offer }
            case .failure(let e):
                probe = nil
                outcome = .failed(e)
            }
            results[group.id] = outcome
            let outcomeStr: String
            switch outcome {
            case .verified: outcomeStr = "verified"
            case .changed: outcomeStr = "changed"
            case .notStored: outcomeStr = "newKey"
            case .failed: outcomeStr = "unreachable"
            }
            monitor.recordManualCheck(
                AppDatabase.HostKeyCheckRecord(
                    groupID: group.id, hostTitle: group.title, displayName: group.displayName,
                    hostToken: group.hostToken, keyType: probe?.keyType ?? "",
                    fingerprint: probe?.fingerprint ?? "", serverOpenSSH: probe?.openSSH ?? "",
                    outcome: outcomeStr, checkedAt: Date()))
        }
    }

    // MARK: - Monitor alerts → outcome

    private func effectiveOutcome(for id: String) -> VerifyOutcome? {
        if let result = results[id] { return result }
        guard let alert = monitor.alerts.first(where: { $0.groupID == id }) else { return nil }
        let probe = HostKeyScanner.Probe(
            keyType: alert.keyType, fingerprint: alert.serverFingerprint, openSSH: alert.serverOpenSSH)
        return alert.kind == .changed ? .changed(probe) : .notStored(probe)
    }

    private func consumePendingSelection() {
        guard let pending = store.pendingKnownHostsSelection else { return }
        if groups.contains(where: { $0.id == pending }) { selectedID = pending }
        store.pendingKnownHostsSelection = nil
    }

    // MARK: - Resolution

    private func requestResolve(_ group: KnownHostGroup) {
        guard let probe = effectiveOutcome(for: group.id)?.scannedKeyToTrust else { return }
        resolving = ResolutionContext(
            group: group, probe: probe,
            isChange: effectiveOutcome(for: group.id)?.isChange ?? false)
    }

    private func resolve(_ ctx: ResolutionContext, replacingType: String?) {
        let ok = store.resolveHostKey(
            hostToken: ctx.group.hostToken,
            newOpenSSHLine: ctx.probe.openSSH,
            replacingType: replacingType)
        if ok { clearResolution(ctx.group.id) }
        resolving = nil
    }

    private func deleteOldKeys(_ ctx: ResolutionContext) {
        let victims = ctx.group.entries.filter { $0.keyType == ctx.probe.keyType }
        store.deleteKnownHosts(victims)
        clearResolution(ctx.group.id)
        resolving = nil
    }

    private func clearResolution(_ id: String) {
        results[id] = nil
        monitor.dismissAlerts(forGroup: id)
    }

    // MARK: - Clipboard

    private func copyFingerprints(_ group: KnownHostGroup) {
        let text = group.entries.compactMap(\.fingerprint).joined(separator: "\n")
        copy(text)
    }

    private func copy(_ string: String) {
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func gated(_ action: () -> Void) {
        action()
    }

    // MARK: - Alert plumbing

    private var deleteEntryBinding: Binding<Bool> {
        Binding(get: { pendingDeleteEntry != nil }, set: { if !$0 { pendingDeleteEntry = nil } })
    }
    private var deleteGroupBinding: Binding<Bool> {
        Binding(get: { pendingDeleteGroupID != nil }, set: { if !$0 { pendingDeleteGroupID = nil } })
    }
    private var resolveBinding: Binding<Bool> {
        Binding(get: { resolving != nil }, set: { if !$0 { resolving = nil } })
    }
    private var revokedConnectBinding: Binding<Bool> {
        Binding(get: { pendingConnectRevoked != nil }, set: { if !$0 { pendingConnectRevoked = nil } })
    }
    private var resolveTitle: String {
        resolving?.isChange == true ? "Resolve changed host key?" : "Trust this new host key?"
    }
    private func resolveMessage(_ ctx: ResolutionContext) -> String {
        if ctx.isChange {
            return
                "\u{201C}\(ctx.group.displayName)\u{201D} is presenting a different \(ctx.probe.keyType) key (\(ctx.probe.fingerprint)) than the one you trust. Replace only if you know the host was rebuilt or re-keyed \u{2014} otherwise this could be a man-in-the-middle."
        }
        return
            "Append the \(ctx.probe.keyType) key \u{201C}\(ctx.group.displayName)\u{201D} presented (\(ctx.probe.fingerprint)) to your known_hosts."
    }

    struct ResolutionContext: Identifiable {
        let id = UUID()
        let group: KnownHostGroup
        let probe: HostKeyScanner.Probe
        let isChange: Bool
    }
}
