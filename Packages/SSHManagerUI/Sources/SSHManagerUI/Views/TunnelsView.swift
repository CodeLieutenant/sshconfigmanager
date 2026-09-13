import Adwaita
import Foundation
import SSHConfigCore

/// L06 · Tunnels. The tunnels the user defined, the forwards the configuration
/// declares, and the console.
///
/// The in-process engine is **not** wired up here. `SSHConfigEngine` pulls in the
/// vendored swift-nio-ssh, whose five patches have only ever been exercised on
/// macOS, so linking it is its own piece of work with its own verification —
/// see CLAUDE.md. Start is present, and it reports that the engine is
/// missing rather than pretending to connect.
struct TunnelsView: View {
    @Binding var store: ConfigStore
    var onStatus: (String) -> Void

    @State private var tunnels: [TunnelDraft] = TunnelStore.load()
    @State private var selection = ""
    @State private var editing = false
    @State private var isNew = false
    @State private var draft = TunnelDraft()
    @State private var console: [String] = []
    @State private var showingConsole = false
    @State private var confirmingDelete = false

    private var declared: [HostForward] {
        store.hosts.flatMap(HostForward.all(in:))
    }

    var view: Body {
        content
            .topToolbar {
                HeaderBar {
                    Button("Add Tunnel", icon: .default(icon: .listAdd)) { startNew() }
                        .flat()
                } end: {
                    Button(icon: .default(icon: .utilitiesTerminal)) {
                        showingConsole = !showingConsole
                    }
                    .flat()
                    .tooltip("Console")
                }
                .headerBarTitle {
                    WindowTitle(subtitle: subtitle, title: "Tunnels")
                }
            }
            .dialog(visible: $editing, title: "Tunnel", width: 620, height: 760) {
                TunnelEditorView(
                    draft: $draft,
                    hosts: store.hosts.map(\.sidebarKey),
                    isNew: isNew,
                    onCancel: { editing = false },
                    onSave: { save() }
                )
            }
            .alertDialog(
                visible: $confirmingDelete,
                heading: "Delete this tunnel?",
                body: "The definition is removed. Your ssh_config is not changed."
            )
            .response("Cancel", role: .close) {}
            .response("Delete", appearance: .destructive, role: .default) { delete() }
    }

    private var subtitle: String {
        let running = tunnels.filter { $0.status == .running }.count
        let total = tunnels.count + declared.count
        guard total > 0 else { return "" }
        return running == 0 ? "\(total) defined · none running" : "\(running) of \(total) running"
    }

    @ViewBuilder private var headerPills: Body {
        let running = tunnels.filter { $0.status == .running }.count
        let failed = tunnels.filter { $0.status == .failed }.count
        if running > 0 {
            statusPill(kind: .ok, text: "\(running) running")
        }
        if failed > 0 {
            statusPill(kind: .error, text: "\(failed) failed")
        }
        if !declared.isEmpty {
            tagPill(text: "\(declared.count) from config", icon: .default(icon: .textXGeneric))
        }
    }

    @ViewBuilder private var content: Body {
        if tunnels.isEmpty && declared.isEmpty {
            StatusPage(
                "No tunnels",
                icon: .default(icon: .networkTransmitReceive),
                description:
                    "Add a port forward to reach a service through one of your hosts."
            ) {
                Button("Add Tunnel") { startNew() }
                    .suggested()
                    .pill()
                    .halign(.center)
            }
        } else {
            VStack {
                screenHeader(
                    icon: .default(icon: .networkTransmitReceive),
                    tile: "tile-tunnels",
                    title: "Tunnels",
                    subtitle: subtitle,
                    pills: { headerPills }
                )
                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        Banner(
                            "Tunnels run through your ssh client for now. The in-app engine is not available on Linux yet.",
                            visible: true
                        )
                        if !tunnels.isEmpty { tunnelList }
                        if !declared.isEmpty { declaredList }
                        if showingConsole { consolePanel }
                    }
                    .padding(Spacing.xxl)
                    .frame(maxWidth: 900)
                }
                .vexpand()
            }
        }
    }

    private var tunnelList: AnyView {
        cardSection("Your Tunnels") {
            ForEach(tunnels) { tunnel in
                ActionRow(tunnel.name.isEmpty ? "Untitled tunnel" : tunnel.name)
                    .useMarkup(false)
                    .subtitle("\(tunnel.mode.label) · \(tunnel.summary) · through \(tunnel.hostAlias)")
                    .subtitleSelectable()
                    .prefix {
                        Symbol(icon: statusIcon(tunnel.status))
                            .style("area-tile")
                            .style(tunnel.status == .running ? "tile-tunnels" : "tile-defaults")
                            .valign(.center)
                    }
                    .suffix {
                        HStack(spacing: Spacing.md) {
                            statusPill(kind: statusKind(tunnel.status), text: tunnel.status.label)
                            Button(tunnel.status == .running ? "Stop" : "Start") {
                                toggle(tunnel)
                            }
                            .valign(.center)
                            Button(icon: .default(icon: .documentEdit)) { edit(tunnel) }
                                .flat()
                                .tooltip("Edit")
                                .valign(.center)
                            Button(icon: .default(icon: .editCopy)) {
                                AdwaitaApp.copy(tunnel.command)
                                onStatus("Copied the ssh command")
                            }
                            .flat()
                            .tooltip("Copy ssh command")
                            .valign(.center)
                            Button(icon: .default(icon: .userTrash)) {
                                selection = tunnel.id.uuidString
                                confirmingDelete = true
                            }
                            .flat()
                            .destructive()
                            .tooltip("Delete")
                            .valign(.center)
                        }
                    }
            }
        }
    }

    private var declaredList: AnyView {
        cardSection(
            "Declared in Your Configuration", describedBy: "These come from your host blocks, not from this app."
        ) {
            ForEach(declared) { forward in
                ActionRow(forward.title)
                    .useMarkup(false)
                    .subtitle(forward.detail)
                    .subtitleSelectable()
                    .prefix {
                        Symbol(icon: .default(icon: .networkTransmitReceive))
                            .style("area-tile")
                            .style("tile-tunnels")
                            .valign(.center)
                    }
            }
        }
    }

    private var consolePanel: AnyView {
        cardSection("Console", describedBy: "\(console.count) lines") {
            Text(console.isEmpty ? "No activity yet." : console.joined(separator: "\n"))
                .monospace()
                .style("code-surface")
                .halign(.start)
        }
    }

    private func statusIcon(_ status: TunnelDraft.Status) -> Icon {
        switch status {
        case .running: .default(icon: .emblemOk)
        case .starting: .default(icon: .contentLoading)
        case .failed: .default(icon: .dialogError)
        case .stopped: .default(icon: .mediaPlaybackStop)
        }
    }

    private func statusKind(_ status: TunnelDraft.Status) -> StatusKind {
        switch status {
        case .running: .ok
        case .starting: .pending
        case .failed: .error
        case .stopped: .idle
        }
    }

    // MARK: - Actions

    private func startNew() {
        draft = TunnelDraft()
        draft.hostAlias = store.hosts.first?.sidebarKey ?? ""
        isNew = true
        editing = true
    }

    private func edit(_ tunnel: TunnelDraft) {
        draft = tunnel
        isNew = false
        editing = true
    }

    private func save() {
        if let index = tunnels.firstIndex(where: { $0.id == draft.id }) {
            tunnels[index] = draft
        } else {
            tunnels.append(draft)
        }
        TunnelStore.save(tunnels)
        editing = false
        onStatus(isNew ? "Tunnel added" : "Tunnel updated")
    }

    private func delete() {
        tunnels.removeAll { $0.id.uuidString == selection }
        TunnelStore.save(tunnels)
        onStatus("Tunnel deleted")
    }

    /// Honest about the missing engine rather than faking a connection.
    private func toggle(_ tunnel: TunnelDraft) {
        console.append(
            "\(Self.stamp())  the in-app tunnel engine is not available on Linux yet — "
                + "run this instead: \(tunnel.command)"
        )
        showingConsole = true
        AdwaitaApp.copy(tunnel.command)
        onStatus("Copied the ssh command — the in-app engine is not available yet")
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

/// A forward as the configuration declares it.
struct HostForward: Identifiable, Equatable {
    enum Kind: String {
        case local = "LocalForward"
        case remote = "RemoteForward"
        case dynamic = "DynamicForward"

        var label: String {
            switch self {
            case .local: "Local forward"
            case .remote: "Remote forward"
            case .dynamic: "Dynamic forward"
            }
        }
    }

    let id: String
    let kind: Kind
    let value: String
    let hostTitle: String

    var title: String { "\(kind.label) · \(value)" }
    var detail: String { "\(kind.rawValue) in \(hostTitle)" }

    static func all(in block: HostBlock) -> [HostForward] {
        [Kind.local, .remote, .dynamic].flatMap { kind in
            block.values(for: kind.rawValue).enumerated().map { index, value in
                HostForward(
                    id: "\(block.id.uuidString)-\(kind.rawValue)-\(index)",
                    kind: kind,
                    value: value,
                    hostTitle: block.title
                )
            }
        }
    }
}
