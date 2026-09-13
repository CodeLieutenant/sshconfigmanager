import Adwaita
import Foundation
import SSHConfigCore

/// The window: sidebar on the left, the selected area on the right.
///
/// `AdwNavigationSplitView` collapses to a back stack on a narrow window on its
/// own, which is the free win Linux gives that macOS does not need.
public struct RootView: View {
    @State private var store = ConfigStore.load()
    /// A host is keyed by its alias, never by `HostBlock.ID`, because IDs change
    /// on every parse. Do not give this an identifier: `@State("id")` binds the
    /// property to a slot shared across the application, and the app then opens
    /// on whatever wrote that slot last instead of on this default.
    @State private var selection = SidebarItem.keys.id
    @State private var settings = AppSettings.load()
    @State private var metadata = HostMetadata.load()
    @State private var toast = Signal()
    @State private var toastMessage = ""
    @State private var showingSettings = false
    @State private var showingAbout = false
    @State private var showingPalette = false
    @State private var storedVersions = 0
    @State private var showingLogs = false
    @State private var showingHelp = false
    @State private var showingNotifications = false
    @State private var search = ""
    @State private var tagFilter = ""
    @State private var showingImport = false
    /// One prompt at a time, because one view can carry only one alert dialog.
    /// Every `alertDialog` modifier on a view shares that view's storage and
    /// keys its dialog by the same name, so a second one closes the first as
    /// soon as it is presented.
    @State private var prompt = Prompt.none
    @State private var promptName = ""
    @State private var renameTarget = ""
    @State private var pendingGroupMember = ""
    @State private var pendingMoveAlias = ""
    @State private var pendingDeleteAlias = ""

    /// The prompts the window can raise. They share one alert dialog, so the
    /// text and the confirm button come from the case rather than from five
    /// separate modifiers.
    enum Prompt {
        case none
        case newGroup
        case renameGroup
        case extractGroup
        case newFile
        case deleteHost

        var wantsName: Bool {
            switch self {
            case .none, .deleteHost: false
            default: true
            }
        }

        var fieldLabel: String {
            switch self {
            case .extractGroup, .newFile: "File name"
            default: "Name"
            }
        }

        var confirmTitle: String {
            switch self {
            case .none, .newGroup: "Create"
            case .renameGroup: "Rename"
            case .extractGroup: "Extract"
            case .newFile: "Move"
            case .deleteHost: "Delete"
            }
        }

        var appearance: AlertDialog.ResponseAppearance {
            self == .deleteHost ? .destructive : .suggested
        }

        var body: String {
            switch self {
            case .none, .newGroup:
                "Groups are the app's own way to organise hosts. "
                    + "They are not written to ssh_config."
            case .renameGroup:
                "Hosts keep their membership."
            case .extractGroup:
                "The hosts in this group move into their own file, wired into your "
                    + "configuration with an Include line."
            case .newFile:
                "The file is created under ~/.ssh/ssh-config-manager.d and included."
            case .deleteHost:
                "This removes the entry from your SSH config."
            }
        }

        func heading(_ view: RootView) -> String {
            switch self {
            case .none, .newGroup: "New Group"
            case .renameGroup: "Rename group"
            case .extractGroup: "Extract “\(view.renameTarget)” to a file"
            case .newFile: "Move to a new file"
            case .deleteHost: "Delete “\(view.pendingDeleteAlias)”?"
            }
        }
    }

    public init() {}

    private var promptVisible: Binding<Bool> {
        .init {
            prompt != .none
        } set: { newValue in
            if !newValue { prompt = .none }
        }
    }

    private var promptText: Binding<String> {
        .init {
            promptName
        } set: {
            promptName = $0
        }
    }

    private func ask(_ prompt: Prompt, name: String = "") {
        promptName = name
        self.prompt = prompt
    }

    private func confirmPrompt() {
        let current = prompt
        prompt = .none
        let name = promptName.trimmingCharacters(in: .whitespaces)
        switch current {
        case .none: break
        case .newGroup: createGroup(named: name)
        case .renameGroup: renameGroup(to: name)
        case .extractGroup: extractGroup(fileNamed: name)
        case .newFile: moveToNewFile(named: name)
        case .deleteHost: deletePendingHost()
        }
    }

    private func createGroup(named name: String) {
        guard !name.isEmpty else { return }
        metadata.addGroup(named: name)
        metadata.groupingMode = "byTag"
        if !pendingGroupMember.isEmpty,
            let group = metadata.groups.first(where: { $0.name == name })
        {
            metadata.setGroup(group, for: pendingGroupMember)
            pendingGroupMember = ""
        }
        metadata.save()
        show("Created \(name)")
    }

    private func renameGroup(to name: String) {
        guard !name.isEmpty, name != renameTarget else { return }
        metadata.renameGroup(from: renameTarget, to: name)
        show("Renamed to \(name)")
    }

    public var view: Body {
        content
            .css { AreaTileStyle.css }
            .toast(toastMessage, signal: $toast)
            .preferencesDialog(visible: $showingSettings)
            .sshManagerPages(
                settings: $settings,
                storedVersions: storedVersions,
                onClearHistory: {
                    HistoryStore.clear()
                    storedVersions = 0
                    show("Cleared the version history")
                },
                onReportBug: { openIssueTracker() },
                onOpenLogs: { showingLogs = true }
            )
            .dialog(visible: $showingLogs, title: "Logs", id: "logs", width: 900, height: 560) {
                LogView(onClose: { showingLogs = false })
            }
            .dialog(visible: $showingHelp, title: "Help", id: "help", width: 900, height: 620) {
                HelpView(onClose: { showingHelp = false })
            }
            .dialog(visible: $showingImport, title: "Import Hosts", id: "import", width: 620, height: 560) {
                ImportHostsView(
                    onImport: { text in importHosts(text) },
                    onCancel: { showingImport = false }
                )
            }
            .dialog(
                visible: $showingPalette,
                title: "Go to",
                id: "palette",
                width: 560,
                height: 520
            ) {
                CommandPaletteView(
                    store: $store,
                    onSelect: { id in
                        selection = id
                        showingPalette = false
                    },
                    onStatus: show
                )
            }
            .alertDialog(visible: promptVisible, heading: prompt.heading(self), body: prompt.body) {
                if prompt.wantsName {
                    EntryRow(prompt.fieldLabel, text: promptText)
                }
            }
            .response("Cancel", role: .close) {}
            .response(prompt.confirmTitle, appearance: prompt.appearance, role: .default) {
                confirmPrompt()
            }
            .aboutDialog(
                visible: $showingAbout,
                app: "SSH Config Manager",
                developer: "Dusan Malusev",
                version: AppVersion.current,
                icon: .custom(name: "app.sshmanager.SSHConfigManager"),
                website: .init(string: AppLinks.repository),
                issues: .init(string: AppLinks.issues)
            )
    }

    /// Every toggle writes the file, so a preference survives a crash as well as
    /// a clean quit.
    private func setting<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        .init {
            settings[keyPath: path]
        } set: { newValue in
            settings[keyPath: path] = newValue
            settings.save()
        }
    }

    /// The window menu. GNOME puts these in the header bar, not in a menu bar.
    private var primaryMenu: AnyView {
        Menu(icon: .default(icon: .openMenu)) {
            MenuButton("New Host…") { newHost() }
            MenuButton("Go to…") { showingPalette = true }
            MenuSection {
                MenuButton("Reload from Disk") {
                    store.reload()
                    show("Reloaded")
                }
            }
            MenuSection {
                MenuButton("SSH Config Manager Help") { showingHelp = true }
                MenuButton("Report a Bug…") { openIssueTracker() }
                MenuButton("Open Logs") { showingLogs = true }
            }
            MenuSection {
                MenuButton("Preferences") {
                    storedVersions = HistoryStore.all().count
                    showingSettings = true
                }
                MenuButton("About SSH Config Manager") { showingAbout = true }
            }
        }
        .primary()
        .tooltip("Main Menu")
    }

    /// Adds an empty host block and selects it, so the detail screen is where the
    /// user names it.
    private func newHost() {
        guard var document = store.document else { return }
        let existing = Set(store.hosts.map(\.sidebarKey))
        let alias = HostNaming.duplicateName(for: "new-host", existing: existing)
        document.appendBlocks([
            HostBlock(
                kind: .host,
                header: .init(keyword: "Host", value: alias, isDirty: true),
                sourceURL: document.sourceURL
            )
        ])
        do {
            try store.save(document)
            selection = SidebarItem.host(alias).id
            show("Added \(alias)")
        } catch {
            show("Could not add a host: \(error.localizedDescription)")
        }
    }

    /// Adds a host seeded from a template. `HostTemplate` in the core carries the
    /// directives, so the two front ends offer the same starting points.
    private func newHost(from template: HostTemplate) {
        guard var document = store.document else { return }
        let existing = Set(store.hosts.map { $0.sidebarKey })
        let alias = HostNaming.duplicateName(for: template.alias, existing: existing)
        var block = HostBlock(
            kind: .host,
            header: .init(keyword: "Host", value: alias, isDirty: true),
            sourceURL: document.sourceURL
        )
        for (keyword, value) in template.directives {
            block.addDirective(keyword: keyword, value: value)
        }
        if !settings.defaultUser.isEmpty, block.firstValue(for: "User") == nil {
            block.setValue(settings.defaultUser, for: "User")
        }
        if settings.defaultPort > 0, block.firstValue(for: "Port") == nil {
            block.setValue("\(settings.defaultPort)", for: "Port")
        }
        document.appendBlocks([block])
        do {
            try store.save(document)
            selection = SidebarItem.host(alias).id
            show("Added \(alias)")
        } catch {
            show("Could not add a host: \(error.localizedDescription)")
        }
    }

    /// Appends whatever host blocks the pasted text contains.
    private func importHosts(_ text: String) {
        guard var document = store.document else { return }
        let parsed = SSHConfigParser.parse(text, sourceURL: document.sourceURL)
        let blocks = parsed.blocks.filter { $0.kind == .host }
        guard !blocks.isEmpty else {
            show("No Host blocks found in that text")
            return
        }
        document.appendBlocks(blocks)
        do {
            try store.save(document)
            showingImport = false
            show("Imported \(blocks.count) host(s)")
        } catch {
            show("Could not import: \(error.localizedDescription)")
        }
    }

    private func duplicate(_ block: HostBlock) {
        guard
            var document = store.graph.documents.first(where: { document in
                document.blocks.contains { $0.id == block.id }
            })
        else { return }
        var copy = block.deepCopyWithFreshIDs()
        let existing = Set(store.hosts.map { $0.sidebarKey })
        let name = HostNaming.duplicateName(for: block.sidebarKey, existing: existing)
        copy.header = copy.header.settingValue(
            HostNaming.renamingFirstAlias(in: copy.header.value, to: name)
        )
        document.appendBlocks([copy])
        do {
            try store.save(document)
            show("Duplicated as \(name)")
        } catch {
            show("Could not duplicate: \(error.localizedDescription)")
        }
    }

    private func moveHost(_ block: HostBlock, to url: URL) {
        guard url != block.sourceURL else { return }
        do {
            try store.move(blockIDs: [block.id], to: url)
            show("Moved to \(url.lastPathComponent)")
        } catch {
            show("Could not move: \(error.localizedDescription)")
        }
    }

    private func moveToNewFile(named name: String) {
        guard let block = store.block(alias: pendingMoveAlias) else { return }
        guard !name.isEmpty, !name.contains("/") else {
            show("Use a single file name with no “/”.")
            return
        }
        do {
            let url = try store.createIncludedFile(named: name)
            guard let moved = store.block(alias: pendingMoveAlias) ?? Optional(block) else { return }
            try store.move(blockIDs: [moved.id], to: url)
            show("Moved to \(url.lastPathComponent)")
        } catch {
            show("Could not move: \(error.localizedDescription)")
        }
    }

    /// Turns a virtual group into a file-backed one: every member moves into a new
    /// included file, which is what makes the group shareable.
    private func extractGroup(fileNamed name: String) {
        guard !name.isEmpty, !name.contains("/") else {
            show("Use a single file name with no “/”.")
            return
        }
        let members = store.hosts.filter {
            metadata.group(for: $0.sidebarKey)?.name == renameTarget
        }
        guard !members.isEmpty else {
            show("That group has no hosts yet")
            return
        }
        do {
            let url = try store.createIncludedFile(named: name)
            let ids = store.hosts
                .filter { metadata.group(for: $0.sidebarKey)?.name == renameTarget }
                .map { $0.id }
            try store.move(blockIDs: ids, to: url)
            if let index = metadata.groups.firstIndex(where: { $0.name == renameTarget }) {
                metadata.groups[index].filePath = url.path
                metadata.save()
            }
            show("Extracted \(renameTarget) to \(url.lastPathComponent)")
        } catch {
            show("Could not extract: \(error.localizedDescription)")
        }
    }

    private func deletePendingHost() {
        guard let block = store.block(alias: pendingDeleteAlias),
            var document = store.graph.documents.first(where: { document in
                document.blocks.contains { $0.id == block.id }
            })
        else { return }
        document.blocks.removeAll { $0.id == block.id }
        do {
            try store.save(document)
            show("Deleted \(block.title)")
        } catch {
            show("Could not delete: \(error.localizedDescription)")
        }
    }

    @ViewBuilder private var content: Body {
        switch store.directory {
        case .ready:
            NavigationSplitView {
                sidebar
            } content: {
                // `.id(selection)` is what makes the detail actually change.
                // Updating a view never replaces its storage: the new view is
                // handed the widget tree the old one built, and its `update`
                // runs against that. Two different screens share no structure,
                // so the update is a no-op and the previous screen stays on
                // display. A changed identifier rebuilds the subtree.
                detail
                    .id(selection)
                    .navigationTitle(detailTitle)
            }
        default:
            GrantAccessView(state: $store.directory) { store.reload() }
        }
    }

    /// The hosts the sidebar shows: the search text and the tag filter both
    /// narrow it. `#tag` in the search box filters by tag, the way the macOS
    /// build does.
    private var visibleHosts: [HostBlock] {
        var query = search.lowercased().trimmingCharacters(in: .whitespaces)
        var tag = tagFilter
        if query.hasPrefix("#") {
            tag = String(query.dropFirst())
            query = ""
        }
        return store.hosts.filter { block in
            let alias = block.sidebarKey
            if !tag.isEmpty,
                !metadata.tags(for: alias).contains(where: { $0.lowercased() == tag.lowercased() })
            {
                return false
            }
            guard !query.isEmpty else { return true }
            return block.title.lowercased().contains(query)
                || (block.connectionTarget?.host.lowercased().contains(query) ?? false)
        }
    }

    private var favouriteHosts: [HostBlock] {
        visibleHosts.filter { metadata.isFavorite($0.sidebarKey) }
    }

    private var items: [SidebarItem] {
        var items: [SidebarItem] = [
            .header("Library"), .keys, .agent, .knownHosts, .globalDefaults,
            .header("Activity"), .tunnels, .issues, .history, .background,
        ]
        let favourites = favouriteHosts
        if !favourites.isEmpty {
            items.append(.header("Favorites"))
            items.append(contentsOf: favourites.map { .host($0.sidebarKey) })
        }
        let hosts = visibleHosts
        guard !hosts.isEmpty else {
            if !search.isEmpty || !tagFilter.isEmpty { items.append(.header("No matches")) }
            return items
        }
        if metadata.mode == .byTag {
            // Grouped: the app's own groups, then whatever is in none of them.
            for group in metadata.groups {
                let members = hosts.filter {
                    metadata.group(for: $0.sidebarKey)?.name == group.name
                }
                items.append(.groupHeader(group.name))
                if !metadata.collapsedGroups.contains(group.name) {
                    items.append(contentsOf: members.map { .host($0.sidebarKey) })
                }
            }
            let ungrouped = hosts.filter { metadata.group(for: $0.sidebarKey) == nil }
            if !ungrouped.isEmpty {
                items.append(.header("Ungrouped"))
                items.append(contentsOf: ungrouped.map { .host($0.sidebarKey) })
            }
        } else {
            // Flat: one section per configuration file, the way ssh reads them.
            // A host in an included file belongs under that file, not in one heap.
            for document in store.graph.documents {
                let members = hosts.filter { $0.sourceURL == document.sourceURL }
                guard !members.isEmpty else { continue }
                let isRoot = document.sourceURL == store.document?.sourceURL
                items.append(.header(isRoot ? "Hosts" : "Included · \(document.displayName)"))
                items.append(contentsOf: members.map { .host($0.sidebarKey) })
            }
        }
        return items
    }

    private var selected: SidebarItem {
        items.first { $0.id == selection } ?? .keys
    }

    /// Clicking a section header selects the first row under it, so a header can
    /// never become the visible selection.
    private var selectionBinding: Binding<String> {
        .init {
            selection
        } set: { newValue in
            guard let index = items.firstIndex(where: { $0.id == newValue }) else {
                selection = newValue
                return
            }
            if items[index].isHeader {
                selection = items[(index + 1)...].first { !$0.isHeader }?.id ?? selection
            } else {
                selection = newValue
            }
        }
    }

    @ViewBuilder private var sidebar: Body {
        VStack(spacing: 6) {
            SearchEntry()
                .text($search)
                .placeholderText("Search hosts · #tag")
                .padding(6)
            ScrollView {
                List(items, id: \.id, selection: selectionBinding) { item in
                    row(item)
                }
                .sidebarStyle()
            }
            .vexpand()
            statusFooter
        }
        .topToolbar {
            HeaderBar {
                addMenu
                groupingMenu
                tagFilterMenu
            } end: {
                primaryMenu
            }
            .headerBarTitle {
                WindowTitle(subtitle: "", title: "SSH Config")
            }
        }
        .navigationTitle("SSH Config")
    }

    /// The plus menu: an empty host, a template, an import, or a group.
    private var addMenu: AnyView {
        Menu(icon: .default(icon: .listAdd)) {
            MenuButton("New Empty Host") { newHost() }
            MenuSection {
                ForEach(HostTemplateBox.all) { box in
                    MenuButton(box.template.name) { newHost(from: box.template) }
                }
            }
            MenuSection {
                MenuButton("Import from Clipboard…") { showingImport = true }
            }
            MenuSection {
                MenuButton("New Group…") {
                    ask(.newGroup)
                }
            }
        }
        .tooltip("Add a host, use a template, or import")
    }

    private var groupingMenu: AnyView {
        Menu(icon: .default(icon: .folder)) {
            MenuButton("No Groups") {
                metadata.groupingMode = "flat"
                metadata.save()
            }
            MenuButton("Group by Tag") {
                metadata.groupingMode = "byTag"
                metadata.save()
            }
            MenuSection {
                MenuButton("New Group…") {
                    ask(.newGroup)
                }
            }
        }
        .tooltip(metadata.mode == .byTag ? "Grouped by tag" : "Group hosts by tag")
    }

    @ViewBuilder private var tagFilterMenu: Body {
        if !metadata.allTags.isEmpty {
            Menu(icon: .default(icon: .viewSortDescending)) {
                MenuButton("All Tags") { tagFilter = "" }
                MenuSection {
                    ForEach(ValueBox.boxes(metadata.allTags)) { box in
                        MenuButton(box.value.mnemonicEscaped) { tagFilter = box.value }
                    }
                }
            }
            .tooltip("Filter hosts by tag")
        }
    }

    /// The saved/unsaved indicator. Every edit is written immediately, so this
    /// reports the last write rather than a pending one.
    private var statusFooter: AnyView {
        VStack {
            Separator()
            HStack(spacing: Spacing.md) {
                Symbol(icon: .default(icon: .emblemOk))
                    .style("success")
                    .valign(.center)
                Text(store.status ?? "All changes saved")
                    .ellipsize()
                    .caption()
                    .dimLabel()
                    .halign(.start)
                    .hexpand()
            }
            .padding(Spacing.lg)
        }
    }

    @ViewBuilder private func row(_ item: SidebarItem) -> Body {
        if case .groupHeader(let name) = item {
            groupHeaderRow(name)
        } else if case .header(let title) = item {
            sectionLabel(title)
                .padding(Spacing.md)
        } else if case .host(let alias) = item, let block = store.block(alias: alias) {
            hostRow(block)
        } else {
            HStack(spacing: Spacing.lg) {
                tile(item)
                Text(item.title)
                    .halign(.start)
                    .hexpand()
                if let badge = badge(for: item) {
                    countBadge(count: badge)
                }
            }
            .padding(Spacing.md)
        }
    }

    /// A group header carries its own actions: collapse, rename and delete. A
    /// plain section label has none, which is why groups are their own case.
    @ViewBuilder private func groupHeaderRow(_ name: String) -> Body {
        let collapsed = metadata.collapsedGroups.contains(name)
        let count = store.hosts.filter { metadata.group(for: $0.sidebarKey)?.name == name }.count
        HStack(spacing: 6) {
            Button(icon: .default(icon: collapsed ? .goNext : .goDown)) {
                if collapsed {
                    metadata.collapsedGroups.remove(name)
                } else {
                    metadata.collapsedGroups.insert(name)
                }
                metadata.save()
            }
            .flat()
            .tooltip(collapsed ? "Expand" : "Collapse")
            Symbol(icon: .default(icon: .folder))
                .valign(.center)
            Text(name.uppercased())
                .ellipsize()
                .captionHeading()
                .dimLabel()
                .halign(.start)
                .hexpand()
            countBadge(count: count)
            Menu(icon: .default(icon: .openMenu)) {
                MenuButton("Rename Group…") {
                    renameTarget = name
                    ask(.renameGroup, name: name)
                }
                MenuButton("Extract to File…") {
                    renameTarget = name
                    ask(
                        .extractGroup,
                        name: "\(name.lowercased().replacingOccurrences(of: " ", with: "-")).conf"
                    )
                }
                MenuSection {
                    MenuButton("Delete Group") {
                        metadata.removeGroup(named: name)
                        show("Deleted \(name)")
                    }
                }
            }
            .flat()
        }
        .padding(6)
    }

    @ViewBuilder private func hostRow(_ block: HostBlock) -> Body {
        HStack(spacing: Spacing.lg) {
            Symbol(icon: hostIcon(block))
                .style("area-tile")
                .style("tile-host")
            VStack {
                Text(block.title)
                    .ellipsize()
                    .halign(.start)
                if let target = block.connectionTarget {
                    Text(target.host)
                        .ellipsize()
                        .caption()
                        .dimLabel()
                        .halign(.start)
                }
                tagLine(block)
            }
            .hexpand()
            if metadata.isFavorite(block.sidebarKey) {
                Symbol(icon: .default(icon: .starred))
                    .style("warning")
                    .tooltip("Favorite")
                    .valign(.center)
            }
            hostMenu(block)
        }
        .padding(Spacing.md)
    }

    /// A Match block and a catch-all are not the same kind of thing as a host,
    /// and the row says so before the name is read.
    private func hostIcon(_ block: HostBlock) -> Icon {
        if block.kind == .match { return .default(icon: .viewSortDescending) }
        return block.isWildcard ? .default(icon: .emblemSystem) : .default(icon: .networkServer)
    }

    /// Tags get their own line rather than being appended to the host name, so
    /// a long name and a long tag list stop competing for one ellipsis.
    @ViewBuilder private func tagLine(_ block: HostBlock) -> Body {
        let tags = metadata.tags(for: block.sidebarKey)
        if !tags.isEmpty {
            Text(tags.map { "#\($0)" }.joined(separator: " "))
                .ellipsize()
                .caption()
                .dimLabel()
                .halign(.start)
                .style("tag-line")
        }
    }

    /// Everything the macOS row's context menu offers. GTK has no context-menu
    /// API in this binding, so the actions live behind a visible button instead
    /// of a hidden right-click.
    private func hostMenu(_ block: HostBlock) -> AnyView {
        let alias = block.sidebarKey
        return Menu(icon: .default(icon: .openMenu)) {
            MenuButton(
                metadata.isFavorite(alias) ? "Remove from Favorites" : "Add to Favorites"
            ) {
                metadata.toggleFavorite(alias)
            }
            MenuSection {
                MenuButton("Connect") {
                    AdwaitaApp.copy(SSHCommandBuilder.aliasCommand(for: block).shellString)
                    show("Copied — opening a terminal is not wired up yet")
                }
                MenuButton("Copy ssh Command") {
                    AdwaitaApp.copy(SSHCommandBuilder.aliasCommand(for: block).shellString)
                    show("Copied ssh command")
                }
                MenuButton("Duplicate") { duplicate(block) }
            }
            MenuSection {
                Submenu("Add to Group") {
                    ForEach(GroupBox.boxes(metadata.groups)) { box in
                        MenuButton(box.group.name.mnemonicEscaped) {
                            metadata.setGroup(box.group, for: alias)
                            metadata.groupingMode = "byTag"
                            metadata.save()
                        }
                    }
                    MenuSection {
                        MenuButton("New Group…") {
                            pendingGroupMember = alias
                            ask(.newGroup)
                        }
                    }
                }
                if metadata.group(for: alias) != nil {
                    MenuButton("Remove from Group") {
                        metadata.setGroup(nil, for: alias)
                    }
                }
            }
            MenuSection {
                Submenu("Move to File") {
                    ForEach(DocumentBox.boxes(store.graph.documents)) { box in
                        MenuButton(box.document.displayName.mnemonicEscaped) {
                            moveHost(block, to: box.document.sourceURL)
                        }
                    }
                    MenuSection {
                        MenuButton("New File…") {
                            pendingMoveAlias = alias
                            ask(.newFile, name: "\(alias).conf")
                        }
                    }
                }
            }
            MenuSection {
                MenuButton("Delete…") {
                    pendingDeleteAlias = alias
                    ask(.deleteHost)
                }
            }
        }
        .flat()
        .tooltip("Actions")
    }

    private func subtitleText(_ block: HostBlock, target: String) -> String {
        let tags = metadata.tags(for: block.sidebarKey)
        guard !tags.isEmpty else { return target }
        return "\(target)  ·  " + tags.map { "#\($0)" }.joined(separator: " ")
    }

    @ViewBuilder private func tile(_ item: SidebarItem) -> Body {
        if let icon = item.icon, let tileClass = item.tileClass {
            Symbol(icon: icon)
                .style("area-tile")
                .style(tileClass)
        }
    }

    private func badge(for item: SidebarItem) -> Int? {
        switch item {
        case .keys: store.keys.isEmpty ? nil : store.keys.count
        case .knownHosts: store.knownHosts.isEmpty ? nil : store.knownHosts.count
        case .issues: store.findings.isEmpty ? nil : store.findings.count
        default: nil
        }
    }

    /// Returns one view rather than a `Body`, so the caller can put the
    /// navigation title on it. A `@ViewBuilder` switch produces a wrapper whose
    /// storage carries no fields, and the title would never reach the split view.
    private var detail: any AnyView {
        switch selected {
        case .keys:
            KeysView(store: $store, defaultAlgorithm: settings.defaultKeyAlgorithm, onStatus: show)
        case .agent:
            AgentView(store: $store, onStatus: show)
        case .knownHosts:
            KnownHostsView(store: $store, onStatus: show)
        case .tunnels:
            TunnelsView(store: $store, onStatus: show)
        case .issues:
            IssuesView(store: $store, onStatus: show)
        case .history:
            HistoryView(store: $store)
        case .globalDefaults:
            GlobalDefaultsView(store: $store, metadata: $metadata, onStatus: show)
        case .background:
            NotificationsView(settings: $settings, onStatus: show)
        case .host(let alias):
            HostDetailView(store: $store, metadata: $metadata, alias: alias, onStatus: show)
        case .header, .groupHeader:
            StatusPage("Select an item", icon: .default(icon: .networkServer))
                .topToolbar {
                    HeaderBar.empty()
                        .headerBarTitle {
                            WindowTitle(subtitle: "", title: "SSH Config Manager")
                        }
                }
        }
    }

    /// The title of the page the split view builds around `detail`. libadwaita
    /// warns about a page without one, and the collapsed layout shows it in the
    /// back button.
    private var detailTitle: String {
        switch selected {
        case .keys: "SSH Keys"
        case .agent: "SSH Agent"
        case .knownHosts: "Known Hosts"
        case .tunnels: "Tunnels"
        case .issues: "Issues"
        case .history: "Version History"
        case .globalDefaults: "Global Defaults"
        case .background: "Notifications"
        case .host(let alias): store.block(alias: alias)?.title ?? alias
        case .header, .groupHeader: "SSH Config Manager"
        }
    }

    /// `AdwToast` parses Pango markup and offers no way to turn it off through
    /// this binding, so a host name or an error message that holds an ampersand
    /// would blank the toast. Every message in the app arrives here.
    private func openIssueTracker() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [AppLinks.newIssue]
        do {
            try process.run()
        } catch {
            show("Open \(AppLinks.newIssue) to report a bug")
        }
    }

    private func show(_ message: String) {
        toastMessage = message.markupEscaped
        toast.signal()
    }
}
