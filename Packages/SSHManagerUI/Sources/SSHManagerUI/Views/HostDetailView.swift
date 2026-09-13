import Adwaita
import Foundation
import SSHConfigCore

/// L01 · Host detail. Every edit writes ssh_config through the lossless
/// serializer, so untouched lines keep their comments, spacing and quoting.
struct HostDetailView: View {
    @Binding var store: ConfigStore
    @Binding var metadata: HostMetadata
    var alias: String
    var onStatus: (String) -> Void

    /// Text fields hold their value here until the user confirms it. An
    /// AdwEntryRow reports every keystroke, and writing on each one would rewrite
    /// ssh_config — and add a version to the history — once per character.
    /// Keyed by alias so switching hosts cannot show another host's draft.
    @State private var drafts: [String: String] = [:]
    @State private var addingSetting = false
    @State private var confirmingDelete = false
    @State private var showingEffective = false
    @State private var showingJumpHosts = false
    @State private var showingRawEditor = false
    @State private var showingIdentityPicker = false
    @State private var showingMoveToFile = false
    @State private var reachability = ""
    @State private var newTag = ""
    /// Wide enough for the two-column body. The narrow window keeps one column,
    /// the way the split view already collapses its sidebar.
    @State private var isWide = false

    private var block: HostBlock? { store.block(alias: alias) }

    var view: Body {
        if let block {
            main(block)
                .topToolbar { toolbar(block) }
                .dialog(visible: $addingSetting, title: "Add Setting", width: 560, height: 620) {
                    AddSettingCatalogView(
                        present: Set(block.body.compactMap { $0.directive?.canonicalKeyword }),
                        onAdd: { keyword in
                            edit { $0.addDirective(keyword: keyword, value: "") }
                            addingSetting = false
                        },
                        onClose: { addingSetting = false }
                    )
                }
                .dialog(
                    visible: $showingEffective,
                    title: "Effective Configuration",
                    width: 640,
                    height: 520
                ) {
                    EffectiveConfigView(
                        target: block.primaryAlias ?? block.title,
                        settings: store.effectiveSettings(for: block),
                        onClose: { showingEffective = false }
                    )
                }
                .dialog(visible: $showingJumpHosts, title: "Jump Hosts", width: 640, height: 620) {
                    JumpHostWizardView(
                        block: block,
                        knownAliases: store.hosts.map(\.sidebarKey),
                        onApply: { value in
                            write(keyword: "ProxyJump", value: value.isEmpty ? nil : value)
                            showingJumpHosts = false
                        },
                        onCancel: { showingJumpHosts = false }
                    )
                }
                .dialog(
                    visible: $showingRawEditor,
                    title: "Edit as Raw Text",
                    width: 720,
                    height: 620
                ) {
                    RawBlockEditorView(
                        block: block,
                        onApply: { text in applyRaw(text, to: block) },
                        onCancel: { showingRawEditor = false }
                    )
                }
                .dialog(
                    visible: $showingIdentityPicker,
                    title: "Add Identity Key",
                    width: 480,
                    height: 520
                ) {
                    AddIdentityKeyView(
                        keys: store.keys,
                        onPick: { path in
                            edit { $0.addDirective(keyword: "IdentityFile", value: path) }
                            showingIdentityPicker = false
                        },
                        onClose: { showingIdentityPicker = false }
                    )
                }
                .dialog(
                    visible: $showingMoveToFile,
                    title: "Move to File",
                    width: 520,
                    height: 420
                ) {
                    MoveToFileView(
                        documents: store.graph.documents,
                        current: block.sourceURL,
                        onMove: { url in move(block, to: url) },
                        onCancel: { showingMoveToFile = false }
                    )
                }
                .alertDialog(
                    visible: $confirmingDelete,
                    heading: "Delete \(block.title)?",
                    body: "This removes the entry from your SSH config."
                )
                .response("Cancel", role: .close) {}
                .response("Delete", appearance: .destructive, role: .default) { delete(block) }
        } else {
            StatusPage(
                "Host not found",
                icon: .default(icon: .dialogWarning),
                description: "It may have been removed from the file outside the app."
            )
            .topToolbar {
                HeaderBar.empty()
                    .headerBarTitle {
                        WindowTitle(subtitle: "", title: "Host")
                    }
            }
            .navigationTitle("Host")
        }
    }

    @ViewBuilder private func toolbar(_ block: HostBlock) -> Body {
        HeaderBar {
            Button("Add Setting", icon: .default(icon: .listAdd)) { addingSetting = true }
                .flat()
            if block.connectionTarget != nil {
                Button("Connect", icon: .default(icon: .utilitiesTerminal)) { connect(block) }
                    .suggested()
            }
        } end: {
            Menu(icon: .default(icon: .openMenu)) {
                MenuButton("Test Reachability") { test(block) }
                MenuButton("Effective Configuration…") { showingEffective = true }
                MenuSection {
                    MenuButton("Jump Hosts…") { showingJumpHosts = true }
                    MenuButton("Edit as Raw Text") { showingRawEditor = true }
                    MenuButton("Move to File…") { showingMoveToFile = true }
                }
                MenuSection {
                    MenuButton("Copy ssh Command") { copyCommand(block) }
                    MenuButton("Duplicate Host") { duplicate(block) }
                }
                MenuSection {
                    MenuButton("Delete Host…") { confirmingDelete = true }
                }
            }
            .primary()
            Button(icon: .default(icon: metadata.isFavorite(alias) ? .starred : .nonStarred)) {
                metadata.toggleFavorite(alias)
            }
            .flat()
            .tooltip(metadata.isFavorite(alias) ? "Remove from favorites" : "Add to favorites")
        }
        .headerBarTitle {
            WindowTitle(subtitle: block.connectionTarget?.host ?? "", title: block.title)
        }
    }

    private func main(_ block: HostBlock) -> AnyView {
        VStack {
            header(block)
            ScrollView {
                columns(block)
                    .padding(Spacing.xxl)
                    .frame(maxWidth: isWide ? 1100 : 820)
            }
            .vexpand()
        }
        .breakpoint(minWidth: 1000, matches: $isWide)
    }

    /// The page header: identity tile, the host's name, what it resolves to, and
    /// the pills that say what kind of host this is.
    private func header(_ block: HostBlock) -> AnyView {
        screenHeader(
            icon: headerIcon(block),
            tile: "tile-accent",
            title: block.title,
            subtitle: block.connectionTarget.map { "\($0.host):\($0.port)" } ?? "No HostName set",
            pills: { headerPills(block) }
        )
    }

    private func headerIcon(_ block: HostBlock) -> Icon {
        if block.kind == .match { return .default(icon: .viewSortDescending) }
        return block.isWildcard ? .default(icon: .emblemSystem) : .default(icon: .networkServer)
    }

    /// Status first, then what the host belongs to. Mirrors the macOS header:
    /// the reachability verdict replaces the "Match block" marker once a probe
    /// has run, because only one of them is the interesting fact at a time.
    @ViewBuilder private func headerPills(_ block: HostBlock) -> Body {
        if !reachability.isEmpty {
            statusPill(kind: .idle, text: reachability)
        } else if block.kind == .match {
            tagPill(text: "Match block")
        }
        if let group = metadata.group(for: alias) {
            tagPill(text: group.name, icon: .default(icon: .folder), accented: true)
        }
        ForEach(ValueBox.boxes(metadata.tags(for: alias))) { box in
            tagPill(text: "#\(box.value)")
        }
        if store.graph.documents.count > 1 {
            tagPill(
                text: block.sourceURL.lastPathComponent,
                icon: .default(icon: .textXGeneric)
            )
        }
    }

    /// Two columns when there is room: the fields on the left, the things
    /// attached to the host on the right. This is the macOS layout — a single
    /// column of cards reads as a settings page, not as a host.
    @ViewBuilder private func columns(_ block: HostBlock) -> Body {
        if isWide {
            HStack(spacing: Spacing.xxl) {
                VStack(spacing: Spacing.xl) {
                    leftColumn(block)
                }
                .hexpand()
                .valign(.start)
                VStack(spacing: Spacing.xl) {
                    rightColumn(block)
                }
                .frame(maxWidth: 360)
                .valign(.start)
            }
        } else {
            VStack(spacing: Spacing.xl) {
                leftColumn(block)
                rightColumn(block)
            }
        }
    }

    @ViewBuilder private func leftColumn(_ block: HostBlock) -> Body {
        general(block)
        ForEach(KeywordCategoryBox.all) { box in
            category(box.category, block)
        }
    }

    @ViewBuilder private func rightColumn(_ block: HostBlock) -> Body {
        identityKeys(block)
        tunnels(block)
        actions(block)
        findings(block)
    }

    // MARK: - General

    private func general(_ block: HostBlock) -> AnyView {
        cardSection(block.kind == .match ? "Match" : "General") {
            patternsRow(block)
            groupRow()
            tagsRow()
            ActionRow("Defined in")
                .subtitle(HomePath.abbreviating(block.sourceURL.path, home: SSHDirectory.home))
                .subtitleSelectable()
            if !reachability.isEmpty {
                ActionRow("Reachability")
                    .useMarkup(false)
                    .subtitle(reachability)
            }
        }
    }

    private func patternsRow(_ block: HostBlock) -> AnyView {
        let current = block.header.value
        let key = draftKey("__patterns__")
        let commit = {
            let value = (drafts[key] ?? current).trimmingCharacters(in: .whitespaces)
            drafts[key] = nil
            guard !value.isEmpty, value != current else { return }
            edit { $0.header = $0.header.settingValue(value) }
        }
        return ActionRow(block.kind == .match ? "Match criteria" : "Host patterns")
            .useMarkup(false)
            .suffix {
                Entry(
                    block.kind == .match ? "host foo user bar" : "alias  *.example.com",
                    text: .init {
                        drafts[key] ?? current
                    } set: {
                        drafts[key] = $0
                    }
                )
                .xalign(1)
                .widthChars(18)
                .maxWidthChars(28)
                .activate(commit)
                .style("value-entry")
                .valign(.center)
            }
    }

    private func groupRow() -> AnyView {
        let none = "No Group"
        let names = [none] + metadata.groups.map(\.name)
        return ComboRow(
            "Group",
            selection: .init {
                metadata.group(for: alias)?.name ?? none
            } set: { name in
                metadata.setGroup(
                    name == none ? nil : metadata.groups.first { $0.name == name },
                    for: alias
                )
            },
            values: names,
            id: \.self,
            description: \.self
        )
    }

    private func tagsRow() -> AnyView {
        let current = metadata.tags(for: alias)
        return EntryRow(
            "Tags",
            text: .init {
                newTag.isEmpty ? current.joined(separator: ", ") : newTag
            } set: {
                newTag = $0
            }
        )
        .onSubmit {
            let tags =
                newTag
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            metadata.setTags(tags, for: alias)
            newTag = ""
        }
    }

    // MARK: - Keyword categories

    /// One card per keyword category, in the order the macOS build uses. Every
    /// directive the file holds appears in exactly one of them, plus the essential
    /// keywords whether or not they are set, so the common fields are never hidden.
    private func category(_ category: KeywordCategory, _ block: HostBlock) -> AnyView {
        let essentials = KeywordCategoryBox.essentials(in: category)
        let present =
            block.body
            .compactMap { $0.directive }
            .filter { KeywordRegistry.category(for: $0.keyword) == category }
        let presentKeys = Set(present.map { $0.canonicalKeyword })
        let missingEssentials = essentials.filter { !presentKeys.contains($0.lowercased()) }
        let suggestions = KeywordCategoryBox.suggestions(in: category, excluding: presentKeys)

        return VStack(spacing: Spacing.md) {
            // A `Text` does not parse markup, so a category named "Security &
            // Host Keys" survives here without escaping — which an
            // AdwPreferencesGroup title would not.
            sectionLabel(category.rawValue)
            PreferencesGroup("") {
                ForEach(DirectiveBox.boxes(present)) { box in
                    row(box.directive, block)
                }
                ForEach(KeywordBox.boxes(missingEssentials)) { box in
                    emptyRow(box.keyword, block)
                }
            }
            if !suggestions.isEmpty {
                suggestionChips(suggestions)
            }
        }
    }

    /// The settings this category still offers, as chips under the card. A row
    /// of names joined by a middle dot reads as prose; a chip reads as something
    /// to press, which is what it is.
    private func suggestionChips(_ suggestions: [String]) -> AnyView {
        let shown = Array(suggestions.prefix(8))
        return FlowBox(KeywordBox.boxes(shown), selection: nil) { box in
            chip(title: box.keyword) {
                edit { $0.addDirective(keyword: box.keyword, value: "") }
            }
        }
        .columnSpacing(UInt(Spacing.md))
        .rowSpacing(UInt(Spacing.md))
        .homogeneous(false)
        .maxChildrenPerLine(20)
        .halign(.start)
    }

    /// A row typed by what the keyword accepts, so a yes/no option is a switch and
    /// a fixed set of values is a list — never a free text box the user can get
    /// wrong.
    private func row(_ directive: Directive, _ block: HostBlock) -> AnyView {
        let field = KeywordRegistry.info(for: directive.keyword)?.field ?? .string
        switch field {
        case .yesNo:
            return SwitchRow(
                directive.keyword,
                isOn: yesNoBinding(block, keyword: directive.keyword)
            )
            .useMarkup(false)
            .tooltip(help(directive.keyword).markupEscaped)
        case .enumeration(let options):
            return comboRow(directive.keyword, block, options: options)
        default:
            return valueRow(directive.keyword, block, removable: true)
        }
    }

    private func emptyRow(_ keyword: String, _ block: HostBlock) -> AnyView {
        let field = KeywordRegistry.info(for: keyword)?.field ?? .string
        if case .enumeration(let options) = field {
            return comboRow(keyword, block, options: options)
        }
        if case .yesNo = field {
            return SwitchRow(keyword, isOn: yesNoBinding(block, keyword: keyword))
                .useMarkup(false)
                .tooltip(help(keyword).markupEscaped)
        }
        return valueRow(keyword, block, removable: false)
    }

    /// The keyword on the left, the value on the right, and nothing else.
    ///
    /// `EntryRow` floats the keyword *inside* the field and gives the field the
    /// full width of the row, which is the shape of a sign-up form. The macOS
    /// build reads as a property list: a quiet label, the value right-aligned
    /// where the eye can scan a column of them, and the box only appearing on
    /// focus. That is what this builds — an `ActionRow` whose suffix is a
    /// borderless entry.
    private func valueRow(_ keyword: String, _ block: HostBlock, removable: Bool) -> AnyView {
        let current = block.firstValue(for: keyword) ?? ""
        let key = draftKey(keyword)
        let commit = {
            let value = (drafts[key] ?? current).trimmingCharacters(in: .whitespaces)
            drafts[key] = nil
            guard value != current else { return }
            write(keyword: keyword, value: value.isEmpty ? nil : value)
        }
        return ActionRow(keyword)
            .useMarkup(false)
            .suffix {
                HStack(spacing: Spacing.sm) {
                    Entry(
                        placeholder(for: keyword),
                        text: .init {
                            drafts[key] ?? current
                        } set: {
                            drafts[key] = $0
                        }
                    )
                    .xalign(1)
                    .widthChars(18)
                    .maxWidthChars(28)
                    .activate(commit)
                    .style("value-entry")
                    .style(isPathLike(keyword) ? "monospace" : "value-entry")
                    .valign(.center)
                    if removable {
                        Button(icon: .default(icon: .listRemove)) {
                            write(keyword: keyword, value: nil)
                        }
                        .flat()
                        .circular()
                        .tooltip("Remove \(keyword.markupEscaped)")
                        .valign(.center)
                    }
                }
            }
            .tooltip(help(keyword).markupEscaped)
    }

    /// A hint of the shape the value takes, shown only while the field is empty.
    /// It replaces the help subtitle that used to sit under every row.
    private func placeholder(for keyword: String) -> String {
        switch keyword.lowercased() {
        case "hostname": "example.com"
        case "user": "root"
        case "port": "22"
        case "identityfile": "~/.ssh/id_ed25519"
        case "proxyjump": "bastion"
        default: "not set"
        }
    }

    /// A path or a command reads better in the monospaced face, the way the
    /// macOS identity-file rows do.
    private func isPathLike(_ keyword: String) -> Bool {
        let key = keyword.lowercased()
        return key.contains("file") || key.contains("command") || key.contains("path")
            || key == "identityagent" || key == "controlpath"
    }

    private func comboRow(_ keyword: String, _ block: HostBlock, options: [String]) -> AnyView {
        let notSet = "(not set)"
        let values = [notSet] + options
        return ComboRow(
            keyword,
            selection: .init {
                let current = block.firstValue(for: keyword) ?? ""
                return current.isEmpty ? notSet : current
            } set: { newValue in
                write(keyword: keyword, value: newValue == notSet ? nil : newValue)
            },
            values: values,
            id: \.self,
            description: \.self
        )
        .useMarkup(false)
        .tooltip(help(keyword).markupEscaped)
    }

    private func help(_ keyword: String) -> String {
        KeywordRegistry.info(for: keyword)?.help ?? ""
    }

    // MARK: - Identity keys, tunnels, actions

    private func identityKeys(_ block: HostBlock) -> AnyView {
        let used = block.values(for: "IdentityFile")
        return cardSection("Identity Keys") {
            if used.isEmpty {
                ActionRow("No identity keys")
                    .subtitle("This host uses the keys ssh tries by default.")
            } else {
                ForEach(ValueBox.boxes(used)) { box in
                    ActionRow(URL(fileURLWithPath: box.value).lastPathComponent)
                        .useMarkup(false)
                        .subtitle(box.value)
                        .subtitleSelectable()
                        .prefix {
                            Symbol(icon: .default(icon: .dialogPassword))
                                .style("area-tile")
                                .style("tile-keys")
                                .valign(.center)
                        }
                        .suffix {
                            Button(icon: .default(icon: .listRemove)) {
                                removeIdentity(box.value)
                            }
                            .flat()
                            .tooltip("Remove")
                            .valign(.center)
                        }
                }
            }
            ActionRow("Add Identity Key")
                .prefix {
                    Symbol(icon: .default(icon: .listAdd))
                        .valign(.center)
                }
                .activated { showingIdentityPicker = true }
        }
    }

    private func tunnels(_ block: HostBlock) -> AnyView {
        let forwards = HostForward.all(in: block)
        return cardSection("Tunnels") {
            if forwards.isEmpty {
                ActionRow("No tunnels yet")
                    .subtitle("Add LocalForward, RemoteForward or DynamicForward.")
            } else {
                ForEach(forwards) { forward in
                    ActionRow(forward.title)
                        .useMarkup(false)
                        .subtitle(forward.kind.rawValue)
                        .prefix {
                            Symbol(icon: .default(icon: .networkTransmitReceive))
                                .style("area-tile")
                                .style("tile-tunnels")
                                .valign(.center)
                        }
                }
            }
        }
    }

    private func actions(_ block: HostBlock) -> AnyView {
        cardSection("Actions") {
            ActionRow("Copy ssh Command")
                .subtitle(SSHCommandBuilder.aliasCommand(for: block).shellString)
                .subtitleSelectable()
                .activated { copyCommand(block) }
            ActionRow("Jump Hosts…")
                .useMarkup(false)
                .subtitle(block.firstValue(for: "ProxyJump") ?? "No jump configured")
                .activated { showingJumpHosts = true }
            ActionRow("Test Reachability")
                .useMarkup(false)
                .subtitle(
                    reachability.isEmpty ? "Check the host answers on its port." : reachability
                )
                .activated { test(block) }
            ActionRow("Duplicate Host")
                .activated { duplicate(block) }
            ActionRow("Edit as Raw Text")
                .activated { showingRawEditor = true }
            ActionRow("Move to File…")
                .activated { showingMoveToFile = true }
            ActionRow("Delete Host…")
                .activated { confirmingDelete = true }
                .style("error")
        }
    }

    private func findings(_ block: HostBlock) -> AnyView {
        let items = store.findings(for: block.id)
        return cardSection("Issues") {
            if items.isEmpty {
                ActionRow("No issues")
                    .subtitle("This host passes every check.")
            } else {
                ForEach(items) { finding in
                    ActionRow(finding.title)
                        .useMarkup(false)
                        .subtitle(finding.detail)
                        .subtitleLines(0)
                        .prefix {
                            Symbol(icon: finding.severity.icon)
                                .style(finding.severity.styleClass)
                                .valign(.center)
                        }
                }
            }
        }
    }

    // MARK: - Bindings

    private func draftKey(_ keyword: String) -> String {
        "\(alias)::\(keyword)"
    }

    private func yesNoBinding(_ block: HostBlock, keyword: String) -> Binding<Bool> {
        .init {
            block.firstValue(for: keyword)?.lowercased() == "yes"
        } set: { isOn in
            write(keyword: keyword, value: isOn ? "yes" : nil)
        }
    }

    // MARK: - Writes

    private func write(keyword: String, value: String?) {
        edit { $0.setValue(value, for: keyword) }
    }

    private func removeIdentity(_ value: String) {
        edit { edited in
            for line in edited.body where line.directive?.canonicalKeyword == "identityfile" {
                guard line.directive?.value == value else { continue }
                edited.removeLine(id: line.id)
            }
        }
    }

    private func edit(_ change: (inout HostBlock) -> Void) {
        do {
            try store.update(alias: alias, change)
        } catch {
            onStatus("Could not save: \(error.localizedDescription)")
        }
    }

    private func applyRaw(_ text: String, to block: HostBlock) {
        let parsed = SSHConfigParser.parse(text, sourceURL: block.sourceURL)
        guard parsed.blocks.count == 1, let replacement = parsed.blocks.first else {
            onStatus("This must contain exactly one Host or Match block.")
            return
        }
        guard
            var document = store.graph.documents.first(where: { document in
                document.blocks.contains { $0.id == block.id }
            }),
            let index = document.blocks.firstIndex(where: { $0.id == block.id })
        else { return }
        document.blocks[index] = replacement
        do {
            try store.save(document)
            showingRawEditor = false
            onStatus("Applied")
        } catch {
            onStatus("Could not save: \(error.localizedDescription)")
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
            onStatus("Duplicated as \(name)")
        } catch {
            onStatus("Could not duplicate: \(error.localizedDescription)")
        }
    }

    private func move(_ block: HostBlock, to url: URL) {
        guard
            var source = store.graph.documents.first(where: { document in
                document.blocks.contains { $0.id == block.id }
            }),
            var target = store.graph.documents.first(where: { $0.sourceURL == url })
        else { return }
        source.blocks.removeAll { $0.id == block.id }
        target.appendBlocks([block])
        do {
            try store.save(source)
            try store.save(target)
            showingMoveToFile = false
            onStatus("Moved to \(url.lastPathComponent)")
        } catch {
            onStatus("Could not move: \(error.localizedDescription)")
        }
    }

    private func delete(_ block: HostBlock) {
        guard
            var document = store.graph.documents.first(where: { document in
                document.blocks.contains { $0.id == block.id }
            })
        else { return }
        document.blocks.removeAll { $0.id == block.id }
        do {
            try store.save(document)
            onStatus("Deleted \(block.title)")
        } catch {
            onStatus("Could not delete: \(error.localizedDescription)")
        }
    }

    private func copyCommand(_ block: HostBlock) {
        AdwaitaApp.copy(SSHCommandBuilder.aliasCommand(for: block).shellString)
        onStatus("Copied ssh command")
    }

    private func connect(_ block: HostBlock) {
        AdwaitaApp.copy(SSHCommandBuilder.aliasCommand(for: block).shellString)
        onStatus("Copied — opening a terminal is not wired up yet")
    }

    private func test(_ block: HostBlock) {
        guard let target = block.connectionTarget else {
            reachability = "No HostName"
            return
        }
        reachability = "\(target.host):\(target.port) — not checked yet"
        onStatus("Reachability testing is not wired up yet")
    }
}

/// `KeywordCategory` and `Directive` are not `Identifiable`, and `ForEach` needs
/// that. These boxes give them an identity without touching the shared core.
struct KeywordCategoryBox: Identifiable {
    let id: String
    let category: KeywordCategory

    static let all: [KeywordCategoryBox] = KeywordCategory.allCases.map {
        .init(id: $0.rawValue, category: $0)
    }

    /// Shown whether or not the file sets them, because a host almost always wants
    /// them and hiding them behind a menu is a step for nothing.
    static func essentials(in category: KeywordCategory) -> [String] {
        switch category {
        case .connection: ["HostName", "User", "Port"]
        default: []
        }
    }

    static func suggestions(in category: KeywordCategory, excluding present: Set<String>)
        -> [String]
    {
        KeywordRegistry.keywords(in: category)
            .filter { !present.contains($0.key) }
            .map { $0.canonical }
    }
}

struct DirectiveBox: Identifiable {
    let id: String
    let directive: Directive

    static func boxes(_ directives: [Directive]) -> [DirectiveBox] {
        directives.map { .init(id: $0.id.uuidString, directive: $0) }
    }
}

struct KeywordBox: Identifiable {
    let id: String
    let keyword: String

    static func boxes(_ keywords: [String]) -> [KeywordBox] {
        keywords.map { .init(id: $0, keyword: $0) }
    }
}

struct ValueBox: Identifiable {
    let id: String
    let value: String

    static func boxes(_ values: [String]) -> [ValueBox] {
        values.enumerated().map { .init(id: "\($0.offset)-\($0.element)", value: $0.element) }
    }
}

extension LintFinding.Severity {
    /// The macOS build names SF Symbols. GNOME has its own icon names, so the
    /// mapping happens here rather than in the shared core.
    var icon: Icon {
        switch self {
        case .info: .default(icon: .dialogInformation)
        case .warning: .default(icon: .dialogWarning)
        case .error: .default(icon: .dialogError)
        }
    }

    var styleClass: String {
        switch self {
        case .info: "dim-label"
        case .warning: "warning"
        case .error: "error"
        }
    }

    /// The tile a finding wears in a list. A coloured tile reads at a glance
    /// where a tinted glyph does not, which is what the macOS rows do.
    var tileClass: String {
        switch self {
        case .info: "tile-defaults"
        case .warning: "tile-issues"
        case .error: "tile-error"
        }
    }
}
