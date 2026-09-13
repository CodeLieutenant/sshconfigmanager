//
//  HostDetailView.swift
//  sshconfigmanager
//
//  The structured editor for a single Host or Match block — restyled to the Liquid Glass
//  redesign: a frosted header (colour tile · title · favourite · status/tag pills · the
//  primary actions) over a two-column body of lifted cards. The left column carries the
//  patterns/connection/security fields and per-category add-chips; the right column the
//  identity keys, tunnels, and actions.
//
//  Only the *presentation* changed: the data-driven field engine (structured keyword
//  rows, generic directives, suggestion chips, identity-file repeatables) and all the
//  bindings are the same as the former grouped-`Form` version.
//

import SSHConfigCore
import SSHConfigServices
import SwiftUI
import UniformTypeIdentifiers

struct HostDetailView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelStore.self) private var tunnels
    @State private var settings = AppSettings.shared
    let blockID: HostBlock.ID

    // Fetch-host-key (ssh-keyscan into known_hosts) state.
    @State private var isFetchingKey = false
    @State private var fetchKeyStatus: String?

    // Honors the "open hosts in the raw editor by default" preference. The view is
    // rebuilt per host (ContentView keys it by id), so each selection picks up the
    // current setting; the "Edit as Raw Text" toggle still flips it per host.
    @State private var showRaw = AppSettings.shared.defaultToRawEditor
    @State private var confirmDelete = false
    @State private var showAddSetting = false
    @State private var showAddIdentity = false
    @State private var showEffective = false
    @State private var showJumpWizard = false
    @State private var connectionResult: ConnectionResult?
    @State private var isTesting = false
    @State private var dropTargeted = false
    /// Known keywords the user explicitly added as fields (shown even while empty).
    @State private var pinnedExtra: Set<String> = []
    /// Header-field focus + the primary alias captured when editing began, so a
    /// rename can migrate tunnel presets on the commit boundary (blur / submit)
    /// rather than per keystroke.
    @FocusState private var headerFocused: Bool
    @State private var aliasAtFocus: String?
    /// The text currently being typed in the tags chip-input field.
    @State private var newTagText = ""

    private var block: HostBlock? { store.block(id: blockID) }
    private let essentials: Set<String> = ["hostname", "user", "port"]
    private let categoryOrder: [KeywordCategory] = [.connection, .identity, .forwarding, .security, .advanced]

    var body: some View {
        Group {
            if let block {
                if showRaw {
                    RawBlockEditor(blockID: blockID, showRaw: $showRaw)
                } else {
                    detail(for: block)
                }
            } else {
                ContentUnavailableView("Host not found", systemImage: "questionmark.folder")
            }
        }
        .confirmationDialog("Delete “\(block?.title ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.deleteBlock(id: blockID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the entry from your SSH config. You can undo with ⌘Z.")
        }
        .sheet(isPresented: $showEffective) {
            EffectiveConfigView(target: effectiveTarget).environment(store)
        }
        .sheet(isPresented: $showJumpWizard) {
            JumpHostWizard(blockID: blockID).environment(store)
        }
        .sheet(isPresented: $showAddSetting) {
            AddSettingCatalogView(
                present: { store.block(id: blockID).map { presentKeys($0) } ?? [] },
                onAdd: addKnownSetting,
                onAddCustom: addCustomSetting
            )
        }
        // Safety net for the field-commit seam: switching hosts or closing the detail
        // may not always fire a field's focus-loss, so commit any open free-text edit
        // here too. commitFieldEdit() is a no-op when nothing is pending.
        .onChange(of: blockID) { _, _ in store.commitFieldEdit() }
        .onDisappear { store.commitFieldEdit() }
    }

    // MARK: - Layout

    private func detail(for block: HostBlock) -> some View {
        VStack(spacing: 0) {
            header(for: block)
                .glassChrome()
                .overlay(alignment: .bottom) { Rectangle().fill(.appSeparator).frame(height: 1) }
            ScrollView {
                HStack(alignment: .top, spacing: Spacing.xxxl) {
                    leftColumn(block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    rightColumn(block)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
                }
                .padding(Spacing.xxxl)
            }
        }
        .background(WindowWash())
    }

    // MARK: - Header

    private func header(for block: HostBlock) -> some View {
        HStack(spacing: Spacing.lg) {
            IconTile(systemImage: headerIcon(block), color: TilePalette.accent, size: 40)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Text(block.title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    Button {
                        store.toggleFavorite(block)
                    } label: {
                        Image(systemName: store.isFavorite(block) ? "star.fill" : "star")
                            .font(.system(size: 13))
                            .foregroundStyle(store.isFavorite(block) ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(store.isFavorite(block) ? "Remove from favorites" : "Add to favorites")
                }
                headerPills(block)
            }

            Spacer(minLength: Spacing.lg)
            headerActions(block)
        }
        .padding(.horizontal, Spacing.xxxl)
        .padding(.vertical, Spacing.xl)
        .frame(minHeight: 84)
    }

    @ViewBuilder
    private func headerPills(_ block: HostBlock) -> some View {
        let allTags = store.tags(for: block)
        let groupName =
            allTags
            .first(where: { $0.hasPrefix(GroupResolver.groupTagPrefix) })
            .map { String($0.dropFirst(GroupResolver.groupTagPrefix.count)) }
        let regularTags = allTags.filter { !$0.hasPrefix(GroupResolver.groupTagPrefix) }
        let multiFile = store.documents.count > 1
        if connectionResult != nil || block.kind == .match || groupName != nil
            || !regularTags.isEmpty || multiFile
        {
            HStack(spacing: Spacing.sm) {
                if let connectionResult {
                    StatusPill(
                        kind: connectionResult.isReachable ? .ok : .warn,
                        text: connectionResult.summary)
                } else if block.kind == .match {
                    TagPill(text: "Match block")
                }
                if let groupName { GroupPill(name: groupName) }
                ForEach(regularTags, id: \.self) { TagPill(text: $0) }
                if multiFile { FilePill(name: block.sourceURL.lastPathComponent) }
            }
        }
    }

    @ViewBuilder
    private func headerActions(_ block: HostBlock) -> some View {
        ChromeButton(title: "Add Setting", systemImage: "plus", kind: .secondary) { showAddSetting = true }
            .accessibilityIdentifier("add-setting")

        if block.kind == .host, block.connectionTarget != nil {
            ChromeButton(title: "Connect", systemImage: "bolt.fill", kind: .prominent) { store.connect(block) }
        }
        if block.kind == .host {
            ChromeButton(icon: "antenna.radiowaves.left.and.right", help: "Test reachability of HostName:Port") {
                runConnectionTest()
            }
            .disabled(isTesting)
            ChromeButton(icon: "function", help: "Show the settings ssh will actually use") {
                showEffective = true
            }
        }

        Menu {
            Button("Duplicate") { store.duplicateBlock(id: blockID) }
            Toggle("Edit as Raw Text", isOn: $showRaw)
            if block.kind == .host {
                Divider()
                Button("Jump Hosts…") { showJumpWizard = true }
            }
            let moveTargets = store.documents.filter { $0.sourceURL != block.sourceURL }
            if !moveTargets.isEmpty {
                Divider()
                Menu("Move to File") {
                    ForEach(moveTargets, id: \.sourceURL) { doc in
                        Button(doc.displayName) {
                            store.moveBlockToDocument(
                                id: blockID,
                                targetDocumentURL: doc.sourceURL)
                        }
                    }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) {
                if settings.confirmBeforeDelete { confirmDelete = true } else { store.deleteBlock(id: blockID) }
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

    private func headerIcon(_ block: HostBlock) -> String {
        if block.kind == .match { return "arrow.triangle.branch" }
        return block.isWildcard ? "asterisk" : "server.rack"
    }

    // MARK: - Left column

    @ViewBuilder
    private func leftColumn(_ block: HostBlock) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            generalCard(block)
            ForEach(categoryOrder, id: \.self) { category in
                categoryBlock(category, block: block)
            }
        }
    }

    private func generalCard(_ block: HostBlock) -> some View {
        CardSection(block.kind == .host ? "General" : "Match") {
            CardRow {
                RowLabel(block.kind == .host ? "Host patterns" : "Match criteria")
                TextField(
                    block.kind == .host ? "alias  *.example.com" : "host foo user bar",
                    text: headerBinding
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.trailing)
                .focused($headerFocused)
                .onSubmit { commitAliasRename() }
                .onChange(of: headerFocused) { _, focused in
                    guard store.block(id: blockID)?.kind == .host else { return }
                    if focused {
                        aliasAtFocus = store.block(id: blockID)?.patterns.first
                    } else {
                        // Commit the coalesced pattern typing as one undo step, then
                        // migrate any tunnel presets keyed on the old alias.
                        store.commitFieldEdit()
                        commitAliasRename()
                    }
                }
            }
            if block.kind == .host {
                CardRow {
                    RowLabel("Group")
                    Spacer(minLength: Spacing.sm)
                    groupPickerMenu(for: block)
                }
                CardRow(minHeight: 44) {
                    RowLabel("Tags")
                    tagChipsRow(block: block)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryBlock(_ category: KeywordCategory, block: HostBlock) -> some View {
        let infos = structuredInfos(in: category, block: block)
        let generics = genericDirectives(in: category, block: block)
        let suggestions = availableSettings(in: category, block: block)

        if !infos.isEmpty || !generics.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.md) {
                CardSection(category.rawValue) {
                    ForEach(infos, id: \.canonical) { info in
                        CardRow {
                            KeywordFieldRow(
                                info: info,
                                value: valueBinding(for: info.canonical, coalescing: !isDiscrete(info.field)),
                                boolValue: boolBinding(for: info.canonical),
                                showsHelp: false,
                                onDelete: essentials.contains(info.key)
                                    ? nil
                                    : {
                                        store.updateBlock(
                                            id: blockID,
                                            actionName: EditAction.removeSetting(info.canonical).name
                                        ) {
                                            $0.setValue(nil, for: info.canonical)
                                        }
                                        pinnedExtra.remove(info.key)
                                    },
                                onCommit: { commitFieldChange() })
                        }
                    }
                    ForEach(generics) { directive in
                        CardRow { genericRow(directive) }
                    }
                }
                if !suggestions.isEmpty { chipWrap(category, suggestions) }
            }
        } else if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionLabel(category.rawValue)
                chipWrap(category, suggestions)
            }
        }
    }

    /// The wrapping "add a setting to this category" chip group.
    private func chipWrap(_ category: KeywordCategory, _ suggestions: [KeywordInfo]) -> some View {
        FlowLayout {
            ForEach(suggestions.prefix(8), id: \.canonical) { info in
                Chip(title: info.canonical) { addKnownSetting(info) }
            }
            if suggestions.count > 8 {
                Chip(title: "More…", systemImage: nil, prominent: true) { showAddSetting = true }
            }
        }
    }

    private func genericRow(_ directive: Directive) -> some View {
        Group {
            TextField("Keyword", text: directiveKeywordBinding(id: directive.id))
                .font(.system(size: 12).monospaced())
                .textFieldStyle(.plain)
                .frame(width: 150, alignment: .leading)
                .commitsOnBlur { commitFieldChange() }
            TextField("value", text: directiveValueBinding(id: directive.id))
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .commitsOnBlur { commitFieldChange() }
            Spacer(minLength: Spacing.sm)
            Button(role: .destructive) {
                store.updateBlock(id: blockID, actionName: EditAction.removeSetting(directive.keyword).name) {
                    $0.removeLine(id: directive.id)
                }
            } label: {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Right column

    @ViewBuilder
    private func rightColumn(_ block: HostBlock) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            identityCard(block)
            if block.kind == .host {
                TunnelsSection(hostAlias: block.patterns.first ?? "")
            }
            actionsCard(block)
        }
    }

    private func identityCard(_ block: HostBlock) -> some View {
        let files = block.values(for: "IdentityFile")
        return CardSection("Identity Keys") {
            if files.isEmpty {
                CardRow {
                    Text("No identity keys. Drag a key here, or add one.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(files.enumerated()), id: \.offset) { index, _ in
                CardRow {
                    IconTile(systemImage: "key.fill", color: TilePalette.keys)
                    TextField("~/.ssh/id_ed25519", text: identityFileBinding(at: index))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12).monospaced())
                        .commitsOnBlur { commitFieldChange() }
                    Spacer(minLength: Spacing.sm)
                    Button(role: .destructive) {
                        removeIdentityFile(at: index)
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            AccentRow(title: "Add Identity Key", systemImage: "plus") { showAddIdentity = true }
                .popover(isPresented: $showAddIdentity, arrowEdge: .bottom) {
                    AddIdentityKeyPopover(
                        keys: store.publicKeys,
                        onPick: { addIdentityFile($0) },
                        onBrowse: { if let path = store.browseForKeyFile() { addIdentityFile(path) } }
                    )
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4]))
                .opacity(dropTargeted ? 1 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleKeyDrop($0) }
    }

    @ViewBuilder
    private func actionsCard(_ block: HostBlock) -> some View {
        CardSection("Actions") {
            if block.kind == .host {
                ActionRow(icon: "doc.on.doc", label: "Copy ssh Command") { store.copySSHCommand(for: block) }
                ActionRow(icon: "arrow.triangle.branch", label: "Jump Hosts…") { showJumpWizard = true }
            }
            if block.kind == .host, block.connectionTarget != nil {
                ActionRow(
                    icon: "lock.shield",
                    label: isFetchingKey ? "Fetching Host Key…" : "Fetch Host Key",
                    trailing: {
                        if isFetchingKey {
                            ProgressView().controlSize(.small)
                        } else if let fetchKeyStatus {
                            Text(fetchKeyStatus)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        } else {
                            CardChevron()
                        }
                    },
                    action: { fetchHostKey(block) }
                )
                .disabled(isFetchingKey)
            }
            ActionRow(icon: "plus.square.on.square", label: "Duplicate Host") { store.duplicateBlock(id: blockID) }
            ActionRow(icon: "curlybraces", label: "Edit as Raw Text") { showRaw = true }
                .accessibilityIdentifier("edit-raw")
        }
    }

    private func fetchHostKey(_ block: HostBlock) {
        guard !isFetchingKey else { return }
        isFetchingKey = true
        fetchKeyStatus = nil
        Task {
            let result = await store.fetchHostKey(for: block)
            isFetchingKey = false
            switch result {
            case .added(let keyType, _): fetchKeyStatus = "Trusted \(keyType)"
            case .alreadyTrusted: fetchKeyStatus = "Already trusted"
            case .noTarget: fetchKeyStatus = "No HostName"
            case .failed(let why): fetchKeyStatus = why
            }
        }
    }

    // MARK: - Add setting

    private func addKnownSetting(_ info: KeywordInfo) {
        if KeywordRegistry.isRepeatable(info.key) {
            store.updateBlock(id: blockID, actionName: EditAction.addSetting(info.canonical).name) {
                $0.addDirective(keyword: info.canonical, value: "")
            }
        } else {
            pinnedExtra.insert(info.key)
        }
    }

    private func addCustomSetting(_ keyword: String) {
        store.updateBlock(id: blockID, actionName: EditAction.addSetting(keyword).name) {
            $0.addDirective(keyword: keyword, value: "")
        }
    }

    /// Known settings for a category not present yet (for the inline add-chips).
    private func availableSettings(in category: KeywordCategory, block: HostBlock) -> [KeywordInfo] {
        KeywordRegistry.keywords(in: category).filter { info in
            let key = info.key
            if key == "identityfile" { return false }
            if essentials.contains(key) || pinnedExtra.contains(key) { return false }
            if KeywordRegistry.isRepeatable(key) { return true }
            return block.firstValue(for: info.canonical) == nil
        }
    }

    /// Keys already represented (so the picker doesn't offer duplicates).
    private func presentKeys(_ block: HostBlock) -> Set<String> {
        var keys = essentials
        keys.insert("identityfile")
        keys.formUnion(pinnedExtra)
        for directive in block.body.compactMap(\.directive)
        where !KeywordRegistry.isRepeatable(directive.canonicalKeyword) {
            keys.insert(directive.canonicalKeyword)
        }
        return keys
    }

    // MARK: - Structured / generic field selection

    /// Known structured fields shown for a category: essentials, user-added (pinned),
    /// and any already present. Repeatables and IdentityFile are shown elsewhere.
    private func structuredInfos(in category: KeywordCategory, block: HostBlock) -> [KeywordInfo] {
        KeywordRegistry.keywords(in: category).filter { info in
            let key = info.key
            if key == "identityfile" { return false }
            if KeywordRegistry.isRepeatable(key) { return false }
            return essentials.contains(key) || pinnedExtra.contains(key)
                || block.firstValue(for: info.canonical) != nil
        }
    }

    /// Every keyword currently rendered as a structured field (to avoid duplicates).
    private func shownStructuredKeys(_ block: HostBlock) -> Set<String> {
        var keys: Set<String> = []
        for category in categoryOrder {
            for info in structuredInfos(in: category, block: block) { keys.insert(info.key) }
        }
        return keys
    }

    /// Present directives shown as plain keyword/value rows in a category: unknown
    /// keywords and repeatables, placed by `KeywordRegistry.category(for:)`.
    private func genericDirectives(in category: KeywordCategory, block: HostBlock) -> [Directive] {
        let shown = shownStructuredKeys(block)
        return block.body.compactMap(\.directive).filter { directive in
            let key = directive.canonicalKeyword
            if key == "identityfile" || key == "host" || key == "match" { return false }
            if shown.contains(key) { return false }
            return KeywordRegistry.category(for: key) == category
        }
    }

    // MARK: - Misc

    /// The alias used for the effective-config / connection target.
    private var effectiveTarget: String {
        block?.primaryAlias ?? block?.title ?? ""
    }

    private func isDiscrete(_ field: FieldKind) -> Bool {
        if case .enumeration = field { return true }
        if case .yesNo = field { return true }
        return false
    }

    // MARK: - Bindings

    private var headerBinding: Binding<String> {
        Binding(
            get: { store.block(id: blockID)?.header.value ?? "" },
            set: { newValue in
                store.updateBlock(id: blockID, actionName: EditAction.editPatterns.name, coalescing: true) { block in
                    block.header.value = newValue
                    block.header.isDirty = true
                }
            }
        )
    }

    /// Migrates tunnel presets when the primary alias changed during this edit
    /// session. No-op unless the field was focused on a Host block and the alias
    /// actually changed; `renameHostAlias` itself ignores empty/unchanged values.
    private func commitAliasRename() {
        guard let old = aliasAtFocus,
            let new = store.block(id: blockID)?.patterns.first
        else { return }
        tunnels.renameHostAlias(from: old, to: new)
        aliasAtFocus = new
    }

    /// Commits a coalesced field edit (HostName, Port, ProxyJump, …) and restarts
    /// any tunnel currently running against this block's alias, so it reconnects
    /// with the change instead of continuing to talk to the address it dialled
    /// before the edit.
    private func commitFieldChange() {
        store.commitFieldEdit()
        restartRunningTunnels()
    }

    private func restartRunningTunnels() {
        guard let alias = store.block(id: blockID)?.patterns.first else { return }
        tunnels.restartRunningTunnels(for: alias)
    }

    /// `coalescing` for free-text fields (typing folds into one undo step committed on
    /// blur); discrete pickers/toggles pass `coalescing: false` and register at once.
    private func valueBinding(for keyword: String, coalescing: Bool) -> Binding<String> {
        Binding(
            get: { store.block(id: blockID)?.firstValue(for: keyword) ?? "" },
            set: { newValue in
                // Free-text fields coalesce by focus; discrete pickers opt into
                // time-window coalescing keyed on this block+keyword so rapid re-picks
                // collapse to one undo step.
                store.updateBlock(
                    id: blockID,
                    actionName: EditAction.editField(keyword).name,
                    coalescing: coalescing,
                    coalesceTarget: "\(blockID.uuidString):\(keyword)"
                ) {
                    $0.setValue(newValue.isEmpty ? nil : newValue, for: keyword)
                }
            }
        )
    }

    private func boolBinding(for keyword: String) -> Binding<Bool> {
        Binding(
            get: { (store.block(id: blockID)?.firstValue(for: keyword) ?? "").lowercased() == "yes" },
            set: { newValue in
                store.updateBlock(
                    id: blockID,
                    actionName: EditAction.toggleField(keyword).name,
                    coalesceTarget: "\(blockID.uuidString):\(keyword)"
                ) {
                    $0.setValue(newValue ? "yes" : "no", for: keyword)
                }
                restartRunningTunnels()
            }
        )
    }

    private func directiveKeywordBinding(id: UUID) -> Binding<String> {
        Binding(
            get: { store.block(id: blockID)?.body.first { $0.id == id }?.directive?.keyword ?? "" },
            set: { newValue in
                store.updateBlock(id: blockID, actionName: EditAction.editDirective.name, coalescing: true) { block in
                    if let index = block.body.firstIndex(where: { $0.id == id }),
                        var directive = block.body[index].directive
                    {
                        directive.keyword = newValue
                        directive.isDirty = true
                        block.body[index] = .directive(directive)
                    }
                }
            }
        )
    }

    private func directiveValueBinding(id: UUID) -> Binding<String> {
        Binding(
            get: { store.block(id: blockID)?.body.first { $0.id == id }?.directive?.value ?? "" },
            set: { newValue in
                store.updateBlock(id: blockID, actionName: EditAction.editDirective.name, coalescing: true) { block in
                    if let index = block.body.firstIndex(where: { $0.id == id }),
                        var directive = block.body[index].directive
                    {
                        directive.value = newValue
                        directive.isDirty = true
                        block.body[index] = .directive(directive)
                    }
                }
            }
        )
    }

    private func identityFileBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                let files = store.block(id: blockID)?.values(for: "IdentityFile") ?? []
                return files.indices.contains(index) ? files[index] : ""
            },
            set: { newValue in setIdentityFile(at: index, to: newValue) }
        )
    }

    /// The group-assignment picker that sits in the General card.
    @ViewBuilder
    private func groupPickerMenu(for block: HostBlock) -> some View {
        let currentGroup = GroupResolver.currentGroup(for: block, groups: store.groups, tags: store.tags(for: block))
        Menu {
            if let current = currentGroup {
                Button("Remove from \"\(current.name)\"") { store.removeFromGroup(blockID: block.id) }
                Divider()
            }
            let others = store.groups.filter { $0.id != currentGroup?.id }
            if !others.isEmpty {
                ForEach(others) { group in
                    Button(group.name) { store.assignToGroup(blockID: block.id, group: group) }
                }
                Divider()
            }
            Button("New Group…") { store.moveToNewGroup(blockID: block.id) }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(currentGroup?.name ?? "No Group")
                    .font(.system(size: 13, weight: currentGroup != nil ? .medium : .regular))
                    .foregroundStyle(
                        currentGroup != nil
                            ? AnyShapeStyle(Color.primary)
                            : AnyShapeStyle(Color.secondary))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Tag chip input

    /// Inline chip row: existing tags as removable pills + a small text field to add new ones.
    @ViewBuilder
    private func tagChipsRow(block: HostBlock) -> some View {
        let tags = userTags(for: block)
        HStack(spacing: Spacing.sm) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text("#\(tag)").font(.system(size: 11, weight: .medium))
                    Button {
                        removeTag(tag)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.controlWash, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.cardBorder, lineWidth: 1))
            }
            TextField(tags.isEmpty ? "add tag…" : "", text: $newTagText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(minWidth: 32, maxWidth: 100)
                .onSubmit { commitNewTag() }
                .onChange(of: newTagText) { _, text in
                    if text.hasSuffix(",") || text.hasSuffix(" ") {
                        commitNewTag()
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func userTags(for block: HostBlock) -> [String] {
        store.tags(for: block).filter { !$0.hasPrefix(GroupResolver.groupTagPrefix) }
    }

    private func commitNewTag() {
        let trimmed = newTagText.trimmingCharacters(in: .init(charactersIn: " ,"))
        newTagText = ""
        guard !trimmed.isEmpty, let block = store.block(id: blockID) else { return }
        let groupTags = store.tags(for: block).filter { $0.hasPrefix(GroupResolver.groupTagPrefix) }
        var current = userTags(for: block)
        guard !current.contains(trimmed) else { return }
        current.append(trimmed)
        store.setTags(groupTags + current, for: block)
    }

    private func removeTag(_ tag: String) {
        guard let block = store.block(id: blockID) else { return }
        let groupTags = store.tags(for: block).filter { $0.hasPrefix(GroupResolver.groupTagPrefix) }
        let newTags = userTags(for: block).filter { $0 != tag }
        store.setTags(groupTags + newTags, for: block)
    }

    // MARK: - Connection test & key drop

    private func runConnectionTest() {
        guard let target = store.block(id: blockID)?.connectionTarget else {
            connectionResult = .failed("No HostName to test")
            return
        }
        isTesting = true
        connectionResult = nil
        Task {
            let result = await ConnectionTester.probe(host: target.host, port: target.port)
            connectionResult = result
            isTesting = false
        }
    }

    private func handleKeyDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            // Real home, not the sandbox container path — see SSHFileAccess.realHomeDirectory.
            let home = SSHFileAccess.realHomeDirectory.path
            let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
            // Drop a .pub by mapping it to the private key path.
            let identity = path.hasSuffix(".pub") ? String(path.dropLast(4)) : path
            Task { @MainActor in addIdentityFile(identity) }
        }
        return true
    }

    // MARK: - IdentityFile mutation (repeatable directive)

    private func addIdentityFile(_ path: String) {
        // Re-quote a space-bearing path so the written line stays valid ssh_config —
        // `firstValue`/`values` will strip the quotes again for display.
        let value = SSHValueQuoting.quotedIfNeeded(path)
        store.updateBlock(id: blockID, actionName: EditAction.addIdentityKey.name) {
            $0.addDirective(keyword: "IdentityFile", value: value)
        }
    }

    private func removeIdentityFile(at index: Int) {
        store.updateBlock(id: blockID, actionName: EditAction.removeIdentityKey.name) { block in
            let ids = identityLineIDs(in: block)
            if ids.indices.contains(index) { block.removeLine(id: ids[index]) }
        }
    }

    private func setIdentityFile(at index: Int, to value: String) {
        store.updateBlock(id: blockID, actionName: EditAction.editIdentityKey.name, coalescing: true) { block in
            let ids = identityLineIDs(in: block)
            guard ids.indices.contains(index),
                let bodyIndex = block.body.firstIndex(where: { $0.id == ids[index] }),
                var directive = block.body[bodyIndex].directive
            else { return }
            // Re-quote a space-bearing path (the field shows the unquoted value).
            directive.value = SSHValueQuoting.quotedIfNeeded(value)
            directive.isDirty = true
            block.body[bodyIndex] = .directive(directive)
        }
    }

    private func identityLineIDs(in block: HostBlock) -> [UUID] {
        block.body.compactMap { line in
            guard let directive = line.directive,
                directive.canonicalKeyword == "identityfile"
            else { return nil }
            return line.id
        }
    }
}
