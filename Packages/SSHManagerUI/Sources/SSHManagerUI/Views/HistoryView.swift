import Adwaita
import Foundation
import SSHConfigCore

/// L07 · Version History. Every save takes a copy first, so this screen can show
/// what changed and put any of them back.
struct HistoryView: View {
    @Binding var store: ConfigStore

    @State private var selection = ""
    @State private var snapshots: [ConfigSnapshot] = []
    @State private var loaded = false
    @State private var message = ""
    /// One prompt at a time: a view can carry only one alert dialog, and a
    /// second one closes the first as soon as it is presented.
    @State private var prompt = Prompt.none
    @State private var versionName = ""
    @State private var comparison = "This change"

    private var selected: ConfigSnapshot? {
        snapshots.first { $0.id == selection }
    }

    enum Prompt {
        case none
        case restore
        case snapshot
        case rename

        var heading: String {
            switch self {
            case .none, .restore: "Restore this version?"
            case .snapshot: "Snapshot current state"
            case .rename: "Name this version"
            }
        }

        var body: String {
            switch self {
            case .none, .restore: "The current file is copied first, so this can be undone."
            case .snapshot: "Records your configuration as a point you can come back to."
            case .rename: "A name makes a version easier to find later."
            }
        }

        var confirmTitle: String {
            switch self {
            case .none, .restore: "Restore"
            case .snapshot: "Snapshot"
            case .rename: "Save"
            }
        }

        var wantsName: Bool { self == .snapshot || self == .rename }
    }

    var view: Body {
        content
            .onAppear { if !loaded { refresh() } }
            .alertDialog(visible: promptVisible, heading: prompt.heading, body: prompt.body) {
                if prompt.wantsName {
                    EntryRow("Name", text: $versionName)
                }
            }
            .response("Cancel", role: .close) {}
            .response(prompt.confirmTitle, appearance: .suggested, role: .default) {
                confirmPrompt()
            }
    }

    private var promptVisible: Binding<Bool> {
        .init {
            prompt != .none
        } set: { newValue in
            if !newValue { prompt = .none }
        }
    }

    private func confirmPrompt() {
        let current = prompt
        prompt = .none
        switch current {
        case .none: break
        case .restore: restore()
        case .snapshot: snapshot()
        case .rename: rename()
        }
    }

    private var subtitle: String {
        snapshots.isEmpty ? "" : "\(snapshots.count) versions"
    }

    @ViewBuilder private var content: Body {
        if snapshots.isEmpty {
            StatusPage(
                "No history yet",
                icon: .default(icon: .documentOpenRecent),
                description: "A version is kept every time the app writes your configuration."
            )
            .topToolbar {
                HeaderBar.end {
                    Button(icon: .default(icon: .viewRefresh)) { refresh() }
                        .flat()
                        .tooltip("Refresh")
                }
                .headerBarTitle {
                    WindowTitle(subtitle: "", title: "Version History")
                }
            }
        } else {
            NavigationSplitView {
                list
            } content: {
                detail
                    .navigationTitle("Version")
            }
        }
    }

    @ViewBuilder private var list: Body {
        ScrollView {
            List(snapshots, id: \.id, selection: $selection) { snapshot in
                VStack {
                    Text(snapshot.name ?? Self.formatter.string(from: snapshot.takenAt))
                        .halign(.start)
                    Text("\(snapshot.fileName) · \(snapshot.byteCount) bytes")
                        .ellipsize()
                        .caption()
                        .dimLabel()
                        .halign(.start)
                }
                .padding(6)
            }
            .sidebarStyle()
        }
        .topToolbar {
            HeaderBar.end {
                Button("Snapshot Now…", icon: .default(icon: .documentSave)) {
                    versionName = ""
                    prompt = .snapshot
                }
                .flat()
                Button(icon: .default(icon: .viewRefresh)) { refresh() }
                    .flat()
                    .tooltip("Refresh")
            }
            .headerBarTitle {
                WindowTitle(subtitle: subtitle, title: "Version History")
            }
        }
        .navigationTitle("Version History")
    }

    /// One view, not a `Body`: a `@ViewBuilder` branch produces a wrapper whose
    /// storage carries no fields, and the navigation title would be lost.
    private var detail: any AnyView {
        if let snapshot = selected {
            VStack {
                screenHeader(
                    icon: .default(icon: .documentOpenRecent),
                    tile: "tile-history",
                    title: snapshot.name ?? Self.formatter.string(from: snapshot.takenAt),
                    subtitle: "\(snapshot.fileName) · \(snapshot.byteCount) bytes",
                    pills: { detailPills(snapshot) }
                )
                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        cardSection("Version") {
                            ActionRow("Taken")
                                .subtitle(Self.formatter.string(from: snapshot.takenAt))
                            ActionRow("File")
                                .subtitle(HomePath.abbreviating(snapshot.originalPath, home: SSHDirectory.home))
                                .subtitleSelectable()
                        }
                        cardSection("Compare") {
                            ComboRow(
                                "Show",
                                selection: .init {
                                    comparison
                                } set: {
                                    comparison = $0
                                },
                                values: ["This change", "Compared to now"],
                                id: \.self,
                                description: \.self
                            )
                        }
                        diffGroup(snapshot)
                        HStack(spacing: Spacing.lg) {
                            Button("Name…") {
                                versionName = HistoryStore.name(of: snapshot) ?? ""
                                prompt = .rename
                            }
                            .pill()
                            Button("Restore This Version") { prompt = .restore }
                                .suggested()
                                .pill()
                        }
                        .halign(.center)
                        if !message.isEmpty {
                            Text(message)
                                .dimLabel()
                                .halign(.center)
                        }
                    }
                    .padding(Spacing.xxl)
                    .frame(maxWidth: 820)
                }
                .vexpand()
            }
            .topToolbar {
                HeaderBar.empty()
                    .headerBarTitle {
                        WindowTitle(subtitle: "", title: "Version")
                    }
            }
        } else {
            StatusPage(
                "Select a version",
                icon: .default(icon: .documentOpenRecent),
                description: "Pick a version on the left to see what changed."
            )
            .topToolbar {
                HeaderBar.empty()
                    .headerBarTitle {
                        WindowTitle(subtitle: "", title: "Version")
                    }
            }
        }
    }

    /// The pills say what this version is before the diff is read: whether it
    /// still matches disk, and how far it has drifted.
    @ViewBuilder private func detailPills(_ snapshot: ConfigSnapshot) -> Body {
        let lines = HistoryStore.diff(snapshot)
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        if added == 0 && removed == 0 {
            statusPill(kind: .ok, text: "Matches the file on disk")
        } else {
            if added > 0 { statusPill(kind: .ok, text: "+\(added)") }
            if removed > 0 { statusPill(kind: .error, text: "−\(removed)") }
        }
        if HistoryStore.name(of: snapshot) != nil {
            tagPill(text: "Named", icon: .default(icon: .starred))
        }
    }

    private func diffGroup(_ snapshot: ConfigSnapshot) -> AnyView {
        let lines = HistoryStore.diff(snapshot)
        let changed = lines.filter { $0.kind != .context }
        return cardSection("Changes Since", describedBy: summary(lines)) {
            if changed.isEmpty {
                ActionRow("No differences")
                    .subtitle("This version matches the file on disk.")
            } else {
                Text(changed.map(render).joined(separator: "\n"))
                    .monospace()
                    .style("code-surface")
                    .halign(.start)
            }
        }
    }

    private func render(_ line: TextDiff.Line) -> String {
        switch line.kind {
        case .added: "+ \(line.text)"
        case .removed: "- \(line.text)"
        case .context: "  \(line.text)"
        }
    }

    private func summary(_ lines: [TextDiff.Line]) -> String {
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        guard added + removed > 0 else { return "" }
        return "\(added) added, \(removed) removed"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private func refresh() {
        loaded = true
        snapshots = HistoryStore.all()
        if selection.isEmpty { selection = snapshots.first?.id ?? "" }
    }

    private func snapshot() {
        HistoryStore.snapshot(path: ConfigStore.configPath, name: versionName)
        refresh()
        message = "Snapshot created."
    }

    private func rename() {
        guard let snapshot = selected else { return }
        HistoryStore.setName(versionName, for: snapshot)
        refresh()
        message = versionName.isEmpty ? "Name removed." : "Name updated."
    }

    private func restore() {
        guard let snapshot = selected else { return }
        do {
            try HistoryStore.restore(snapshot)
            store.reload()
            refresh()
            message = "Restored."
        } catch {
            message = "Could not restore: \(error.localizedDescription)"
        }
    }
}
