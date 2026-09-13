import Adwaita
import Foundation
import SSHConfigCore
import SSHConfigServices

/// L04 · Known Hosts. A host list beside the keys stored for the selected host.
struct KnownHostsView: View {
    @Binding var store: ConfigStore
    var onStatus: (String) -> Void

    @State private var search = ""
    @State private var selection = ""
    @State private var showingReview = false
    @State private var showingAdd = false
    @State private var confirmingDeleteHost = false

    private var groups: [KnownHostGroup] {
        let all = KnownHostsReader.groups(store.knownHosts, configAliasesByHost: aliasesByHost)
        let query = search.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.matches(query) }
    }

    private var selected: KnownHostGroup? {
        groups.first { $0.id == selection } ?? groups.first
    }

    /// Lets a known_hosts row say which Host block connects to it.
    private var aliasesByHost: [String: [String]] {
        var result: [String: [String]] = [:]
        for block in store.hosts {
            guard let target = block.connectionTarget else { continue }
            result[target.host, default: []].append(block.title)
        }
        return result
    }

    private var findingCount: Int {
        store.knownHosts.filter { $0.finding != nil }.count
    }

    var view: Body {
        content
            .dialog(visible: $showingReview, title: "Review Known Hosts", width: 620, height: 620) {
                ReviewKnownHostsView(
                    rows: store.knownHosts,
                    onRemove: { row in remove(row.entry) },
                    onClose: { showingReview = false }
                )
            }
            .dialog(visible: $showingAdd, title: "Add Known Host", width: 560, height: 420) {
                AddKnownHostView(
                    onAdd: { line in add(line) },
                    onCancel: { showingAdd = false }
                )
            }
            .alertDialog(
                visible: $confirmingDeleteHost,
                heading: "Delete all keys for this host?",
                body:
                    "Every stored key for this host is removed. ssh treats it as a brand-new host "
                    + "the next time you connect."
            )
            .response("Cancel", role: .close) {}
            .response("Delete All", appearance: .destructive, role: .default) { deleteHost() }
    }

    @ViewBuilder private var content: Body {
        if store.knownHosts.isEmpty {
            StatusPage(
                "No known hosts",
                icon: .default(icon: .securityHigh),
                description: "Your known_hosts file is empty or missing. It fills as you connect."
            ) {
                Button("Add Entry…") { showingAdd = true }
                    .suggested()
                    .pill()
                    .halign(.center)
            }
            .topToolbar {
                HeaderBar.end {
                    Button(icon: .default(icon: .listAdd)) { showingAdd = true }
                        .flat()
                        .tooltip("Add a known_hosts entry")
                }
                .headerBarTitle {
                    WindowTitle(subtitle: "", title: "Known Hosts")
                }
            }
        } else {
            NavigationSplitView {
                list
            } content: {
                detail
                    .navigationTitle(detailTitle)
            }
        }
    }

    @ViewBuilder private var list: Body {
        VStack(spacing: 6) {
            SearchEntry()
                .text($search)
                .placeholderText("Filter hosts")
                .padding(6)
            ScrollView {
                List(groups, id: \.id, selection: $selection) { group in
                    HStack(spacing: 12) {
                        Symbol(icon: kindIcon(group.kind))
                            .style("area-tile")
                            .style("tile-known-hosts")
                        VStack {
                            Text(group.displayName)
                                .ellipsize()
                                .halign(.start)
                            Text(group.rowDetail)
                                .ellipsize()
                                .caption()
                                .dimLabel()
                                .halign(.start)
                        }
                        .hexpand()
                    }
                    .padding(6)
                }
                .sidebarStyle()
            }
            .vexpand()
        }
        .topToolbar {
            HeaderBar.end {
                Button(icon: .default(icon: .dialogWarning)) { showingReview = true }
                    .flat()
                    .tooltip(
                        findingCount == 0
                            ? "Review known_hosts for issues"
                            : "\(findingCount) issues to review"
                    )
                Button(icon: .default(icon: .listAdd)) { showingAdd = true }
                    .flat()
                    .tooltip("Add a known_hosts entry")
                Button(icon: .default(icon: .viewRefresh)) {
                    store.reload()
                    onStatus("Re-read known_hosts")
                }
                .flat()
                .tooltip("Re-read known_hosts")
            }
            .headerBarTitle {
                WindowTitle(subtitle: "\(store.knownHosts.count) entries", title: "Known Hosts")
            }
        }
        .navigationTitle("Known Hosts")
    }

    /// One view, not a `Body`: a `@ViewBuilder` branch produces a wrapper whose
    /// storage carries no fields, and the navigation title would be lost.
    private var detail: any AnyView {
        if let group = selected {
            VStack {
                screenHeader(
                    icon: kindIcon(group.kind),
                    tile: "tile-known-hosts",
                    title: group.displayName,
                    subtitle: group.rowDetail,
                    pills: { detailPills(group) }
                )
                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        cardSection("Host") {
                            ActionRow("Name")
                                .useMarkup(false)
                                .subtitle(group.displayName)
                                .subtitleSelectable()
                            ActionRow("Keys")
                                .subtitle("\(group.entries.count)")
                            if group.isConnectable {
                                ActionRow("Port")
                                    .subtitle("\(group.connectPort)")
                            }
                        }
                        if !group.configAliases.isEmpty {
                            cardSection("Configured As") {
                                ForEach(ValueBox.boxes(group.configAliases)) { box in
                                    ActionRow(box.value)
                                        .useMarkup(false)
                                        .subtitle("A host block connects here.")
                                }
                            }
                        }
                        if group.aliases.count > 1 {
                            cardSection("Also Known As") {
                                ForEach(ValueBox.boxes(group.aliases)) { box in
                                    ActionRow(box.value)
                                        .useMarkup(false)
                                }
                            }
                        }
                        cardSection("Host Keys") {
                            ForEach(group.entries) { entry in
                                entryRow(entry)
                            }
                        }
                        cardSection("Actions") {
                            ActionRow("Copy Fingerprints")
                                .activated {
                                    AdwaitaApp.copy(
                                        group.entries.compactMap { $0.fingerprint }
                                            .joined(separator: "\n")
                                    )
                                    onStatus("Copied the fingerprints")
                                }
                            ActionRow("Verify Host Key")
                                .subtitle("Ask the server for its key and compare.")
                                .activated { onStatus("Host key verification is not wired up yet") }
                            ActionRow("Delete All Keys for Host")
                                .activated { confirmingDeleteHost = true }
                                .style("error")
                        }
                        if group.kind == .hashed {
                            cardSection("Hashed entries") {
                                ActionRow("Names cannot be recovered")
                                    .subtitle(
                                        "These entries were written with HashKnownHosts, so the "
                                            + "original host name is not stored. You can still inspect "
                                            + "and delete them."
                                    )
                                    .subtitleLines(0)
                            }
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
                        WindowTitle(subtitle: group.rowDetail, title: group.displayName)
                    }
            }
        } else {
            StatusPage(
                "Select a host",
                icon: .default(icon: .securityHigh),
                description: "Pick a host on the left to see its keys."
            )
            .topToolbar {
                HeaderBar.empty()
                    .headerBarTitle {
                        WindowTitle(subtitle: "", title: "Host")
                    }
            }
        }
    }

    private var detailTitle: String {
        selected?.displayName ?? "Host"
    }

    /// What kind of record this is, and whether anything is wrong with it —
    /// the two things worth knowing before reading the key list.
    @ViewBuilder private func detailPills(_ group: KnownHostGroup) -> Body {
        switch group.kind {
        case .hashed: tagPill(text: "Hashed", icon: .default(icon: .changesPrevent))
        case .ipAddress: tagPill(text: "IP address", icon: .default(icon: .networkWired))
        case .hostname: tagPill(text: "Host name", icon: .default(icon: .networkServer))
        }
        if group.entries.contains(where: { $0.resolvedMarker == .revoked }) {
            statusPill(kind: .error, text: "Revoked key")
        }
        if group.entries.contains(where: { $0.resolvedMarker == .certAuthority }) {
            tagPill(text: "Certificate authority", accented: true)
        }
        let problems = group.entries.compactMap { entry in
            store.knownHosts.first { $0.id == entry.id }?.finding
        }
        if !problems.isEmpty {
            statusPill(kind: .warn, text: "\(problems.count) to review")
        }
    }

    private func entryRow(_ entry: KnownHostEntry) -> AnyView {
        let row = store.knownHosts.first { $0.id == entry.id }
        return ActionRow(entry.keyType)
            .useMarkup(false)
            .subtitle(entry.fingerprint ?? entry.raw)
            .subtitleSelectable()
            .prefix {
                Symbol(icon: markerIcon(entry.resolvedMarker))
                    .valign(.center)
            }
            .suffix {
                HStack(spacing: 6) {
                    if let label = row?.findingLabel {
                        Text(label)
                            .caption()
                            .dimLabel()
                            .valign(.center)
                    }
                    trustPicker(entry)
                    Button(icon: .default(icon: .editCopy)) {
                        AdwaitaApp.copy(entry.fingerprint ?? entry.raw)
                        onStatus("Copied the fingerprint")
                    }
                    .flat()
                    .tooltip("Copy fingerprint")
                    .valign(.center)
                    Button(icon: .default(icon: .userTrash)) { remove(entry) }
                        .flat()
                        .destructive()
                        .tooltip("Delete this key")
                        .valign(.center)
                }
            }
    }

    /// Normal, certificate authority, or revoked — the three markers OpenSSH
    /// understands in a known_hosts line.
    private func trustPicker(_ entry: KnownHostEntry) -> AnyView {
        DropDown(
            selection: .init {
                entry.resolvedMarker.displayName
            } set: { name in
                guard
                    let marker = KnownHostMarker.allCases.first(where: { $0.displayName == name })
                else { return }
                setMarker(marker, on: entry)
            },
            values: KnownHostMarker.allCases.map { $0.displayName },
            id: \.self,
            description: \.self
        )
        .valign(.center)
    }

    private func kindIcon(_ kind: KnownHostGroup.Kind) -> Icon {
        switch kind {
        case .hostname: .default(icon: .networkServer)
        case .ipAddress: .default(icon: .networkWired)
        case .hashed: .default(icon: .changesPrevent)
        }
    }

    private func markerIcon(_ marker: KnownHostMarker) -> Icon {
        switch marker {
        case .none: .default(icon: .securityHigh)
        case .certAuthority: .default(icon: .applicationCertificate)
        case .revoked: .default(icon: .dialogError)
        }
    }

    // MARK: - Writes

    private func remove(_ entry: KnownHostEntry) {
        do {
            try KnownHostsReader.remove(lineIndex: entry.lineIndex)
            store.reload()
            onStatus("Forgot a key for \(entry.hostsDisplay)")
        } catch {
            onStatus("Could not update known_hosts: \(error.localizedDescription)")
        }
    }

    private func setMarker(_ marker: KnownHostMarker, on entry: KnownHostEntry) {
        do {
            try KnownHostsReader.setMarker(marker, lineIndex: entry.lineIndex)
            store.reload()
            onStatus("Set \(marker.displayName)")
        } catch {
            onStatus("Could not update known_hosts: \(error.localizedDescription)")
        }
    }

    /// Deletes from the bottom up, because removing a line renumbers everything
    /// after it.
    private func deleteHost() {
        guard let group = selected else { return }
        let indices = group.entries.map { $0.lineIndex }.sorted(by: >)
        do {
            for index in indices {
                try KnownHostsReader.remove(lineIndex: index)
            }
            store.reload()
            onStatus("Deleted every key for \(group.displayName)")
        } catch {
            onStatus("Could not update known_hosts: \(error.localizedDescription)")
        }
    }

    private func add(_ line: String) {
        do {
            try KnownHostsReader.append(line: line)
            store.reload()
            showingAdd = false
            onStatus("Added a known_hosts entry")
        } catch {
            onStatus("Could not update known_hosts: \(error.localizedDescription)")
        }
    }
}

/// Malformed, duplicate and orphaned entries, with the fix for each.
struct ReviewKnownHostsView: View {
    var rows: [KnownHostRow]
    var onRemove: (KnownHostRow) -> Void
    var onClose: () -> Void

    private func matching(_ kind: String) -> [KnownHostRow] {
        rows.filter { row in
            switch row.finding {
            case .malformed: kind == "malformed"
            case .duplicate: kind == "duplicate"
            case .orphan: kind == "orphan"
            case nil: false
            }
        }
    }

    var view: Body {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 18) {
                    section(
                        "Malformed",
                        "This line cannot be parsed as a known_hosts entry, and ssh ignores it.",
                        matching("malformed")
                    )
                    section(
                        "Duplicates",
                        "Another entry already stores this key type for the host.",
                        matching("duplicate")
                    )
                    section(
                        "Orphans",
                        "No host block refers to this host. It may be a server you no longer use.",
                        matching("orphan")
                    )
                    if rows.allSatisfy({ $0.finding == nil }) {
                        StatusPage(
                            "No issues found",
                            icon: .default(icon: .emblemOk),
                            description: "Your known_hosts file looks clean."
                        )
                    }
                }
            }
            .vexpand()
            Text("Orphans are advisory — a host can be legitimate without being in your config.")
                .caption()
                .dimLabel()
            Button("Done") { onClose() }
                .suggested()
                .halign(.center)
        }
        .padding(18)
    }

    @ViewBuilder private func section(_ title: String, _ detail: String, _ items: [KnownHostRow])
        -> Body
    {
        if !items.isEmpty {
            PreferencesGroup(title.markupEscaped) {
                ForEach(items) { row in
                    ActionRow(row.host)
                        .useMarkup(false)
                        .subtitle(row.entry.raw)
                        .subtitleLines(0)
                        .suffix {
                            Button("Remove") { onRemove(row) }
                                .destructive()
                                .valign(.center)
                        }
                }
            }
            .description(detail)
        }
    }
}

/// Paste a known_hosts line.
struct AddKnownHostView: View {
    var onAdd: (String) -> Void
    var onCancel: () -> Void

    @State private var line = ""

    var view: Body {
        VStack(spacing: 12) {
            Text("The line is appended to your known_hosts file.")
                .dimLabel()
                .halign(.start)
            ScrollView {
                TextEditor(text: $line)
                    .monospace()
                    .vexpand()
            }
            .vexpand()
            Text("Example: github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA…")
                .caption()
                .dimLabel()
                .halign(.start)
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                Button("Add") { onAdd(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .suggested()
            }
            .halign(.center)
        }
        .padding(18)
    }
}
