import Adwaita
import SSHConfigCore
import SSHConfigCrypto

/// L03 · SSH Agent. Shows which keys on disk the agent currently holds.
struct AgentView: View {
    @Binding var store: ConfigStore
    var onStatus: (String) -> Void

    @State private var identities: [AgentIdentity] = []
    @State private var error = ""
    @State private var loaded = false
    @State private var confirmingRemoveAll = false
    @State private var selection = ""
    @State private var showingAddToAgent = false

    private var rows: [AgentKeyRow] {
        AgentKeyCorrelation.merge(diskKeys: store.keys.map(\.key), agentIdentities: identities)
    }

    var view: Body {
        content
            .topToolbar {
                HeaderBar.end {
                    Button(icon: .default(icon: .viewRefresh)) { refresh() }
                        .flat()
                        .tooltip("Refresh")
                    Menu(icon: .default(icon: .openMenu)) {
                        MenuButton("Remove All Identities") { confirmingRemoveAll = true }
                    }
                    .primary()
                }
                .headerBarTitle {
                    WindowTitle(subtitle: subtitle, title: "SSH Agent")
                }
            }
            .onAppear { if !loaded { refresh() } }
            .alertDialog(
                visible: $confirmingRemoveAll,
                heading: "Remove every identity?",
                body: "The agent forgets all loaded keys. You will be asked for passphrases again."
            )
            .response("Cancel", role: .close) {}
            .response("Remove All", appearance: .destructive, role: .default) { removeAll() }
            .dialog(visible: $showingAddToAgent, title: "Add to Agent", width: 560, height: 420) {
                if let key = selectedKey {
                    AddToAgentView(
                        key: key,
                        onStatus: onStatus,
                        onClose: { showingAddToAgent = false }
                    )
                }
            }
    }

    private var selectedKey: SSHKeyEntry? {
        store.keys.first { $0.id.uuidString == selection } ?? store.keys.first
    }

    private var subtitle: String {
        let loadedCount = rows.filter(\.isLoaded).count
        let onDisk = rows.filter(\.isOnDiskOnly).count
        var parts = [loadedCount == 1 ? "1 loaded" : "\(loadedCount) loaded"]
        if onDisk > 0 { parts.append("\(onDisk) on disk, not loaded") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var headerPills: Body {
        if !SSHAgentClient.isAvailable {
            statusPill(kind: .error, text: "No agent")
        } else if !error.isEmpty {
            statusPill(kind: .error, text: "Unreachable")
        } else if rows.contains(where: \.isLoaded) {
            statusPill(kind: .ok, text: "Connected")
        } else {
            statusPill(kind: .idle, text: "Nothing loaded")
        }
    }

    @ViewBuilder private var content: Body {
        if !SSHAgentClient.isAvailable {
            StatusPage(
                "No agent is running",
                icon: .default(icon: .avatarDefault),
                description:
                    "SSH_AUTH_SOCK is not set, so there is no agent to talk to. "
                    + "Start one with ssh-agent, or let your desktop session start it."
            )
        } else if !error.isEmpty {
            StatusPage(
                "Cannot reach the agent",
                icon: .default(icon: .dialogError),
                description: error
            ) {
                Button("Try Again") { refresh() }
                    .suggested()
                    .pill()
                    .halign(.center)
            }
        } else {
            VStack {
                screenHeader(
                    icon: .default(icon: .avatarDefault),
                    tile: "tile-agent",
                    title: "SSH Agent",
                    subtitle: subtitle,
                    pills: { headerPills }
                )
                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        cardSection("Loaded in the Agent") {
                            let loadedRows = rows.filter(\.isLoaded)
                            if loadedRows.isEmpty {
                                ActionRow("Nothing loaded")
                                    .subtitle("Add a key with ssh-add.")
                            } else {
                                ForEach(loadedRows) { row in
                                    agentRow(row, loaded: true)
                                }
                            }
                        }
                        cardSection("On Disk Only") {
                            let diskRows = rows.filter(\.isOnDiskOnly)
                            if diskRows.isEmpty {
                                ActionRow("Every key is loaded")
                            } else {
                                ForEach(diskRows) { row in
                                    agentRow(row, loaded: false)
                                }
                            }
                        }
                        cardSection("Details") {
                            ActionRow("Agent socket")
                                .subtitle(SSHAgentClient.socketPath ?? "SSH_AUTH_SOCK is not set")
                                .subtitleSelectable()
                            ActionRow("Identities held")
                                .subtitle("\(identities.count)")
                            ActionRow("Keys on disk")
                                .subtitle("\(store.keys.count)")
                        }
                    }
                    .padding(Spacing.xxl)
                    .frame(maxWidth: 820)
                }
                .vexpand()
            }
        }
    }

    private func agentRow(_ row: AgentKeyRow, loaded: Bool) -> AnyView {
        ActionRow(AgentKeyCorrelation.displayName(row))
            .useMarkup(false)
            .subtitle(row.fingerprint)
            .subtitleSelectable()
            .prefix {
                Symbol(icon: .default(icon: .dialogPassword))
                    .style("area-tile")
                    .style("tile-agent")
                    .valign(.center)
            }
            .suffix {
                HStack(spacing: Spacing.md) {
                    statusPill(kind: loaded ? .ok : .idle, text: loaded ? "Loaded" : row.typeLabel)
                    if loaded {
                        Button("Unload") { remove(row) }
                            .flat()
                            .valign(.center)
                    } else {
                        Button("Add") {
                            selection = row.diskKey?.id.uuidString ?? ""
                            showingAddToAgent = true
                        }
                        .valign(.center)
                    }
                }
            }
    }

    // MARK: - Actions

    private func refresh() {
        loaded = true
        do {
            identities = try SSHAgentClient.listIdentities()
            error = ""
        } catch {
            identities = []
            self.error = error.localizedDescription
        }
    }

    private func remove(_ row: AgentKeyRow) {
        guard let identity = row.agentIdentity else { return }
        do {
            try SSHAgentClient.removeIdentity(keyBlob: identity.keyBlob)
            refresh()
            onStatus("Unloaded \(AgentKeyCorrelation.displayName(row))")
        } catch {
            onStatus("Could not unload: \(error.localizedDescription)")
        }
    }

    private func removeAll() {
        do {
            try SSHAgentClient.removeAll()
            refresh()
            onStatus("Removed every identity")
        } catch {
            onStatus("Could not remove: \(error.localizedDescription)")
        }
    }
}
