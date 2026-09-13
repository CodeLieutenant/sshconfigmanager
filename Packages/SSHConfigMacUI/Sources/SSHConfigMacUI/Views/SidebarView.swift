//
//  SidebarView.swift
//  sshconfigmanager
//
//  The left column: a custom Liquid Glass panel (not a stock `List`) carrying the
//  searchable destinations and the draggable host list. The chrome is a frosted material
//  (`glassChrome`); destinations and hosts are System-Settings-style colour tiles. The
//  IA is the approved one: LIBRARY + ACTIVITY pinned on top, then FAVORITES, then the
//  scrolling HOSTS list.
//
//  Building it custom (rather than restyling `List`) means we own selection, drag-
//  reorder, and context menus directly — see `HostDropDelegate` for the reorder. Keyboard
//  arrow-key navigation of the list is the one stock-`List` affordance not yet
//  re-implemented here; tracked as a follow-up.
//

import AppKit
import SSHConfigCore
import SSHConfigServices
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelStore.self) private var tunnels
    @State private var settings = AppSettings.shared
    @Binding var selection: SidebarSelection?
    @State private var pendingDelete: HostBlock?
    @State private var draggingHost: HostBlock.ID?
    @State private var groupDropTargetID: HostBlock.ID?
    @State private var searchFocused = false
    @State private var suggestionsHovering = false
    @State private var newlyCreatedGroup: PersistedGroup.ID?
    @State private var groupFileSheet: GroupFileSheetContext?
    @State private var moveToNewFileSheet: MoveToNewFileContext?

    /// Reorder is only meaningful on the unfiltered, unsearched main list — matching the
    /// previous `List`-based guard.
    private var canReorder: Bool { store.searchText.isEmpty && store.tagFilter == nil }
    private var showsFavorites: Bool {
        !store.favoriteBlocks.isEmpty && store.searchText.isEmpty && store.tagFilter == nil
    }

    /// Every selectable row in top-to-bottom display order — what ↑/↓ walk through.
    private var orderedSelectables: [SidebarSelection] {
        var ids: [SidebarSelection] = [
            .keys, .agent, .knownHosts, .globalDefaults, .tunnels, .issues, .history, .gistSync,
        ]
        if showsFavorites { ids += store.favoriteBlocks.map { SidebarSelection.host($0.id) } }
        for group in store.filteredGroups { ids += group.blocks.map { SidebarSelection.host($0.id) } }
        return ids
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            searchRow
            if showSuggestions { suggestionsDropdown }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                    librarySection
                    activitySection
                    if showsFavorites { favoritesSection }
                    hostsSections
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xl)
                .animation(
                    .spring(response: 0.3, dampingFraction: 0.85),
                    value: store.allHostBlocks.map(\.id))
            }
            .arrowKeyNavigation(items: orderedSelectables, selection: $selection)
            .contextMenu { sidebarContextMenu }
            statusFooter
        }
        .glassChrome()
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { block in
            Button("Delete", role: .destructive) { store.deleteBlock(id: block.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the entry from your SSH config. You can undo with ⌘Z.")
        }
        .sheet(item: $groupFileSheet) { context in
            GroupFileSheet(context: context) { newlyCreatedGroup = $0 }
                .environment(store)
        }
        .sheet(item: $moveToNewFileSheet) { context in
            MoveToNewFileSheet(context: context)
                .environment(store)
        }
    }

    // MARK: - Search + add/filter

    private var searchRow: some View {
        @Bindable var store = store
        return HStack(spacing: Spacing.md) {
            SearchField(
                text: $store.searchText, prompt: "Search hosts · #tag",
                onFocusChange: { focused in withAnimation(.easeInOut(duration: 0.15)) { searchFocused = focused } },
                identifier: "sidebar-search")
            addMenu
            groupingModeButton
            if !store.allTags.isEmpty { tagFilterMenu }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Tag-autocomplete dropdown

    /// Shown while the user types a `#tag` token (or has the field focused on a `#`),
    /// listing matching tags. Kept visible while hovering so a click registers.
    private var showSuggestions: Bool {
        (searchFocused || suggestionsHovering) && !store.searchSuggestions.isEmpty
    }

    private var suggestionsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.searchSuggestions.prefix(7), id: \.self) { tag in
                Button {
                    store.applyTagSuggestion(tag)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "number")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(tag).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: Spacing.sm)
                        CountBadge(count: hostCount(taggedWith: tag))
                    }
                    .padding(.horizontal, Spacing.md)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.sm)
        .onHover { hov in withAnimation(.easeInOut(duration: 0.15)) { suggestionsHovering = hov } }
        .transition(.opacity)
    }

    private func hostCount(taggedWith tag: String) -> Int {
        store.allHostBlocks.filter { store.tags(for: $0).contains(tag) }.count
    }

    private var addMenu: some View {
        Menu {
            Button("New Empty Host") { select(store.addHost()) }
            Menu("New from Template") {
                ForEach(HostTemplate.all) { template in
                    Button {
                        select(store.addHost(template: template))
                    } label: {
                        Label(template.name, systemImage: template.systemImage)
                    }
                }
            }
            Divider()
            Button("Import from Clipboard") { importFromClipboard() }
            Divider()
            Button("New Group") { newlyCreatedGroup = store.createGroup() }
            Button("New Group with File…") { groupFileSheet = GroupFileSheetContext(mode: .newGroup) }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
        .help("Add a host, use a template, or import")
    }

    private var groupingModeButton: some View {
        Menu {
            Button {
                store.groupingMode = .flat
            } label: {
                Label("No Groups", systemImage: store.groupingMode == .flat ? "checkmark" : "rectangle.grid.1x2")
            }
            Button {
                store.groupingMode = .byTag
            } label: {
                Label("Group by Tag", systemImage: store.groupingMode == .byTag ? "checkmark" : "folder")
            }
        } label: {
            Image(systemName: store.groupingMode == .flat ? "folder.fill" : "folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
        .accessibilityIdentifier("grouping-mode")
        .help(store.groupingMode == .flat ? "Group hosts by tag" : "Grouped by tag · click to change")
    }

    private var tagFilterMenu: some View {
        @Bindable var store = store
        return Menu {
            Button("All Tags") { store.tagFilter = nil }
            Divider()
            ForEach(store.allTags, id: \.self) { tag in
                Button {
                    store.tagFilter = (store.tagFilter == tag) ? nil : tag
                } label: {
                    Label(tag, systemImage: store.tagFilter == tag ? "checkmark" : "tag")
                }
            }
        } label: {
            Image(
                systemName: store.tagFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
        .help("Filter hosts by tag")
    }

    // MARK: - Destination sections

    private var librarySection: some View {
        SidebarGroup(title: "Library") {
            DestinationRow(
                .keys, tile: TilePalette.keys, icon: "key.fill",
                label: "SSH Keys", count: store.publicKeys.count, selection: $selection
            )
            .accessibilityIdentifier("sidebar-keys")
            DestinationRow(
                .agent, tile: TilePalette.agent, icon: "person.badge.key.fill",
                label: "SSH Agent", selection: $selection
            )
            .accessibilityIdentifier("sidebar-agent")
            DestinationRow(
                .knownHosts, tile: TilePalette.knownHosts, icon: "checkmark.shield.fill",
                label: "Known Hosts", count: store.knownHosts.count, selection: $selection
            )
            .accessibilityIdentifier("sidebar-known-hosts")
            // Pinned so "Host *" always has a place to be configured, even before
            // one exists in the file — kept out of the regular host list (see
            // `ConfigStore.filteredGroups`) so it isn't duplicated there.
            DestinationRow(
                .globalDefaults, tile: TilePalette.host, icon: "asterisk",
                label: "Global Defaults", selection: $selection
            )
            .accessibilityIdentifier("sidebar-global-defaults")
        }
    }

    private var activitySection: some View {
        SidebarGroup(title: "Activity") {
            DestinationRow(
                .tunnels, tile: TilePalette.tunnels, icon: "point.3.connected.trianglepath.dotted",
                label: "Tunnels", count: tunnels.runningPresets.count, selection: $selection
            )
            .accessibilityIdentifier("sidebar-tunnels")
            DestinationRow(
                .issues, tile: TilePalette.issues, icon: "exclamationmark.triangle.fill",
                label: "Issues", count: store.allFindings.count, selection: $selection
            )
            .accessibilityIdentifier("sidebar-issues")
            DestinationRow(
                .history, tile: TilePalette.history, icon: "clock.arrow.circlepath",
                label: "Version History", selection: $selection
            )
            .accessibilityIdentifier("sidebar-history")
            DestinationRow(
                .gistSync, tile: TilePalette.gistSync, icon: "arrow.triangle.2.circlepath",
                label: "Sync", selection: $selection
            )
            .accessibilityIdentifier("sidebar-gist-sync")
        }
    }

    // MARK: - Host sections

    private var favoritesSection: some View {
        SidebarGroup(title: "Favorites") {
            ForEach(store.favoriteBlocks) { block in
                hostRow(block, reorderGroup: nil)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                            removal: .opacity))
            }
        }
    }

    @ViewBuilder
    private var hostsSections: some View {
        if store.groupingMode == .flat {
            flatHostsSections
        } else {
            groupedHostsSections
        }
    }

    @ViewBuilder
    private var flatHostsSections: some View {
        let groups = store.filteredGroups
        if groups.allSatisfy({ $0.blocks.isEmpty }) {
            emptyHostsMessage
        } else {
            ForEach(groups) { group in
                if !group.blocks.isEmpty {
                    SidebarGroup(title: sectionTitle(for: group)) {
                        ForEach(group.blocks) { block in
                            hostRow(block, reorderGroup: canReorder ? group.id : nil)
                                .transition(
                                    .asymmetric(
                                        insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                                        removal: .opacity))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var groupedHostsSections: some View {
        let tree = store.sidebarTree
        if tree.isEmpty { emptyHostsMessage }
        ForEach(tree) { group in
            let isExpanded = Binding<Bool>(
                get: { !store.collapsedGroupNames.contains(group.id) },
                set: { expanded in
                    if expanded {
                        store.collapsedGroupNames.remove(group.id)
                    } else {
                        store.collapsedGroupNames.insert(group.id)
                    }
                }
            )
            CollapsibleSidebarGroup(
                name: group.name,
                isUngrouped: group.isUngrouped,
                count: group.blocks.count,
                fileName: group.filePath.map { ($0 as NSString).lastPathComponent },
                isExpanded: isExpanded,
                startEditing: !group.isUngrouped && group.groupID == newlyCreatedGroup,
                onRename: group.isUngrouped
                    ? nil
                    : { newName in
                        newlyCreatedGroup = nil
                        guard let id = group.groupID else { return }
                        store.renameGroup(id, to: newName)
                    },
                onDelete: group.isUngrouped
                    ? nil
                    : {
                        guard let id = group.groupID else { return }
                        store.deleteGroup(id)
                    },
                onExtractToFile: (group.isUngrouped || group.isFileBacked)
                    ? nil
                    : {
                        guard let id = group.groupID else { return }
                        groupFileSheet = GroupFileSheetContext(mode: .extractExisting(id), suggestedName: group.name)
                    },
                onRevealFile: group.filePath.map { path in
                    { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                },
                onGroupDrop: group.isUngrouped
                    ? nil
                    : {
                        guard let id = draggingHost, let groupID = group.groupID else { return }
                        draggingHost = nil
                        store.dropHost(draggedID: id, intoGroup: groupID)
                    }
            ) {
                ForEach(group.blocks) { block in
                    groupedHostRow(block)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                                removal: .opacity))
                }
            }
        }
        newGroupButton
    }

    private var newGroupButton: some View {
        Button {
            newlyCreatedGroup = store.createGroup()
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("New Group")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: newlyCreatedGroup) {
            guard newlyCreatedGroup != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            newlyCreatedGroup = nil
        }
    }

    private var emptyHostsMessage: some View {
        Text(store.searchText.isEmpty && store.tagFilter == nil ? "No hosts yet" : "No matches")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.sm)
    }

    private func hostRow(_ block: HostBlock, reorderGroup: ConfigStore.DocumentGroup.ID?) -> some View {
        HostRow(block: block, selection: $selection)
            .contextMenu { rowMenu(for: block) }
            .modifier(
                ReorderModifier(
                    block: block,
                    groupID: reorderGroup,
                    draggingHost: $draggingHost,
                    store: store
                ))
    }

    /// Host row used in the grouped sidebar. Draggable and accepts drops from other
    /// host rows to create or join a group.
    private func groupedHostRow(_ block: HostBlock) -> some View {
        let isTargeted = Binding<Bool>(
            get: { groupDropTargetID == block.id },
            set: { groupDropTargetID = $0 ? block.id : nil }
        )
        return HostRow(block: block, selection: $selection)
            .contextMenu { rowMenu(for: block) }
            .onDrag {
                draggingHost = block.id
                return NSItemProvider(object: block.id.uuidString as NSString)
            }
            .onDrop(of: [.text], isTargeted: isTargeted) { _ in
                guard let draggedID = draggingHost, draggedID != block.id else { return false }
                draggingHost = nil
                store.dropHost(draggedID: draggedID, onto: block.id)
                return true
            }
            .overlay {
                if groupDropTargetID == block.id {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
    }

    // MARK: - Context menus

    /// Background right-click menu for the sidebar panel — shown when the user
    /// right-clicks empty space (not on a specific row).
    @ViewBuilder
    private var sidebarContextMenu: some View {
        // Add hosts
        Button("New Empty Host") { select(store.addHost()) }
        Menu("New from Template") {
            ForEach(HostTemplate.all) { template in
                Button {
                    select(store.addHost(template: template))
                } label: {
                    Label(template.name, systemImage: template.systemImage)
                }
            }
        }
        Button {
            newlyCreatedGroup = store.createGroup()
        } label: {
            Label("New Group", systemImage: "folder.badge.plus")
        }
        Button {
            groupFileSheet = GroupFileSheetContext(mode: .newGroup)
        } label: {
            Label("New Group with File…", systemImage: "doc.badge.plus")
        }
        Divider()
        // Import
        Button("Import from Clipboard") { importFromClipboard() }
        Divider()
        // View mode
        if store.groupingMode == .flat {
            Button {
                store.groupingMode = .byTag
            } label: {
                Label("View as Groups", systemImage: "folder")
            }
        } else {
            Button {
                store.groupingMode = .flat
            } label: {
                Label("View as List", systemImage: "list.bullet")
            }
            // Group collapse / expand — only when there are named groups
            if !store.allGroupNames.isEmpty {
                Divider()
                Button("Expand All Groups") { store.expandAllGroups() }
                Button("Collapse All Groups") { store.collapseAllGroups() }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(for block: HostBlock) -> some View {
        Button(store.isFavorite(block) ? "Remove from Favorites" : "Add to Favorites") {
            store.toggleFavorite(block)
        }
        if block.kind == .host {
            if block.connectionTarget != nil {
                Button("Connect") { store.connect(block) }
            }
            Button("Copy ssh Command") { store.copySSHCommand(for: block) }
        }
        Button("Duplicate") { select(store.duplicateBlock(id: block.id)) }
        Divider()
        groupMenu(for: block)
        moveToFileMenu(for: block)
        Divider()
        Button("Delete…", role: .destructive) {
            if settings.confirmBeforeDelete { pendingDelete = block } else { store.deleteBlock(id: block.id) }
        }
    }

    @ViewBuilder
    private func moveToFileMenu(for block: HostBlock) -> some View {
        let targets = store.documents.filter { $0.sourceURL != block.sourceURL }
        Divider()
        Menu("Move to File") {
            ForEach(targets, id: \.sourceURL) { doc in
                Button(doc.displayName) {
                    store.moveBlockToDocument(
                        id: block.id,
                        targetDocumentURL: doc.sourceURL)
                }
            }
            if !targets.isEmpty { Divider() }
            Button("New File…") {
                moveToNewFileSheet = MoveToNewFileContext(
                    id: block.id,
                    suggestedName: suggestedFileName(for: block))
            }
        }
    }

    /// A sanitized `<alias>.conf` guess for the "New File…" move-to-file sheet,
    /// mirroring `GroupFileSheet`'s name→filename slug.
    private func suggestedFileName(for block: HostBlock) -> String {
        let alias = block.patterns.first ?? "host"
        let slug = alias.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return (slug.isEmpty ? "host" : slug) + ".conf"
    }

    @ViewBuilder
    private func groupMenu(for block: HostBlock) -> some View {
        let groups = store.groups
        if groups.isEmpty {
            Button("Create New Group") { store.moveToNewGroup(blockID: block.id) }
        } else {
            Menu("Add to Group") {
                ForEach(groups) { group in
                    Button(group.name) { store.assignToGroup(blockID: block.id, group: group) }
                }
                Divider()
                Button("New Group") { store.moveToNewGroup(blockID: block.id) }
            }
            if store.isInGroup(block) {
                Button("Remove from Group") { store.removeFromGroup(blockID: block.id) }
            }
        }
    }

    // MARK: - Status footer

    private var statusFooter: some View {
        HStack(spacing: Spacing.md) {
            switch store.saveStatus {
            case .saving:
                ProgressView().controlSize(.small)
                Text("Saving…")
            case .unsaved:
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
                Text("Unsaved changes")
                Spacer()
                Button("Save") { store.flushPendingSave() }.controlSize(.small)
            case .upToDate:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(savedLabel)
            }
            if store.saveStatus != .unsaved { Spacer() }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(.appSeparator).frame(height: 1) }
    }

    private var savedLabel: String {
        guard let date = store.lastSavedDate else { return "All changes saved" }
        return "Saved at \(date.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Helpers

    private func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let added = store.importHosts(fromText: text)
        if added == 0 { store.errorMessage = "No SSH host blocks were found on the clipboard." }
    }

    private func select(_ id: HostBlock.ID?) {
        if let id { selection = .host(id) }
    }

    private func sectionTitle(for group: ConfigStore.DocumentGroup) -> String {
        group.isMain ? "Hosts" : "Included · \(group.name)"
    }
}

// MARK: - Section header + group

/// An uppercase sidebar section header above its rows.
private struct SidebarGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xs)
            content
        }
    }
}

// MARK: - Collapsible folder group

/// A collapsible sidebar section for grouped host display. Supports:
/// - Expand/collapse via header click
/// - Inline rename: click the pencil button (always visible, not hover-gated) to edit in place
/// - Drop target: dragging a host row onto the header adds it to the group
///
/// Rename/delete used to live *inside* the header's own toggle `Button`, revealed
/// only `if isHovering` — nested buttons on macOS routinely swallow the inner
/// button's clicks in favor of the outer one, and a hover-only affordance is
/// invisible until the pointer happens to be over the row at all (worse over
/// trackpad/keyboard use). Both are now independent sibling controls, always
/// visible, with the toggle wired to a tap gesture on the label instead of a
/// wrapping `Button` — see `ui`'s "don't rely only on hover for important
/// actions" guidance.
private struct CollapsibleSidebarGroup<Content: View>: View {
    let name: String
    let isUngrouped: Bool
    let count: Int
    /// Set when this group is backed by a real `Include`d file — shows a filename
    /// subtitle and changes the delete confirmation's wording.
    let fileName: String?
    @Binding var isExpanded: Bool
    var onRename: ((String) -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onExtractToFile: (() -> Void)? = nil
    var onRevealFile: (() -> Void)? = nil
    var onGroupDrop: (() -> Void)? = nil
    var content: Content

    init(
        name: String,
        isUngrouped: Bool,
        count: Int,
        fileName: String? = nil,
        isExpanded: Binding<Bool>,
        startEditing: Bool = false,
        onRename: ((String) -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onExtractToFile: (() -> Void)? = nil,
        onRevealFile: (() -> Void)? = nil,
        onGroupDrop: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.name = name
        self.isUngrouped = isUngrouped
        self.count = count
        self.fileName = fileName
        self._isExpanded = isExpanded
        self.onRename = onRename
        self.onDelete = onDelete
        self.onExtractToFile = onExtractToFile
        self.onRevealFile = onRevealFile
        self.onGroupDrop = onGroupDrop
        self.content = content()
        self._isEditing = State(initialValue: startEditing)
        self._editingName = State(initialValue: startEditing ? name : "")
    }

    @State private var isEditing: Bool
    @State private var editingName: String
    @State private var isDropTargeted = false
    @State private var confirmingDelete = false

    private var isFileBacked: Bool { fileName != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerView
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .onDrop(of: [.text], isTargeted: $isDropTargeted) { _ in
                    guard let onGroupDrop else { return false }
                    onGroupDrop()
                    return true
                }
            if isExpanded { content }
        }
        .confirmationDialog(
            "Delete “\(name)”?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Group", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let fileName {
                Text(
                    count > 0
                        ? "This permanently deletes \(count) host\(count == 1 ? "" : "s") and the file “\(fileName)”. You can undo with ⌘Z."
                        : "This permanently deletes the file “\(fileName)”. You can undo with ⌘Z.")
            } else {
                Text(
                    count > 0
                        ? "\(count) host\(count == 1 ? "" : "s") will be removed from this group. The hosts themselves are kept."
                        : "This empty group will be removed.")
            }
        }
    }

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: Spacing.sm) {
            // Only THIS inner region (chevron/folder/label) toggles expand on tap —
            // scoped so the gesture never overlaps the TextField (which needs its
            // own clicks for caret placement/focus) or the trailing buttons below
            // (an outer, row-wide tap gesture competing with sibling `Button`s for
            // the same click was the likely cause of a reported bug: after a
            // rename, the pencil/trash buttons stopped responding and looked gone).
            HStack(spacing: Spacing.sm) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10, alignment: .center)
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        isUngrouped
                            ? AnyShapeStyle(Color.secondary.opacity(0.6))
                            : AnyShapeStyle(Color.secondary))
                if isEditing {
                    TextField("Group name", text: $editingName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelEditing() }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(isUngrouped ? Color.secondary.opacity(0.7) : .secondary)
                        if let fileName {
                            Label(fileName, systemImage: "doc.text")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isEditing else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
            Spacer()
            if !isUngrouped, !isEditing {
                if onRename != nil {
                    Button {
                        startEditing()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename Group")
                }
                // Only offered for virtual groups (file-backed ones already show a
                // Reveal-in-Finder affordance instead, in the context menu). This used
                // to be reachable only via right-click — easy to never discover at
                // all — so it's now an always-visible icon alongside rename/delete.
                if let onExtractToFile {
                    Button {
                        onExtractToFile()
                    } label: {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Extract to File…")
                }
                if onDelete != nil {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete Group")
                }
            }
            CountBadge(count: count)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu {
            if !isUngrouped {
                if onRename != nil {
                    Button("Rename Group") { startEditing() }
                }
                if let onExtractToFile {
                    Button("Extract to File…", systemImage: "doc.badge.plus") { onExtractToFile() }
                }
                if let onRevealFile {
                    Button("Reveal in Finder", systemImage: "folder") { onRevealFile() }
                }
                if onDelete != nil {
                    Divider()
                    Button("Delete Group", role: .destructive) { confirmingDelete = true }
                }
            }
        }
    }

    private func startEditing() {
        editingName = name
        isEditing = true
    }

    private func commitRename() {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != name { onRename?(trimmed) }
        isEditing = false
    }

    private func cancelEditing() { isEditing = false }
}

// MARK: - Rows

/// A tool/destination row: colour tile + label + optional count badge, accent-filled when
/// selected.
private struct DestinationRow: View {
    let target: SidebarSelection
    let tile: Color
    let icon: String
    let label: String
    var count: Int?
    @Binding var selection: SidebarSelection?

    init(
        _ target: SidebarSelection, tile: Color, icon: String, label: String,
        count: Int? = nil, selection: Binding<SidebarSelection?>
    ) {
        self.target = target
        self.tile = tile
        self.icon = icon
        self.label = label
        self.count = count
        self._selection = selection
    }

    private var isSelected: Bool { selection == target }

    var body: some View {
        Button {
            selection = target
        } label: {
            HStack(spacing: Spacing.md) {
                IconTile(systemImage: icon, color: isSelected ? .white.opacity(0.28) : tile)
                Text(label).font(.system(size: 13.5))
                Spacer(minLength: Spacing.sm)
                if let count, count > 0 {
                    if isSelected {
                        Text("\(count)").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    } else {
                        CountBadge(count: count)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: 34)
            .modifier(RowSelectionBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }
}

/// One row in the host list: tile + alias (+ favourite star) + hostname subtitle, with a
/// hover-revealed Duplicate button and an active-tunnel bolt. Accent-filled when selected.
private struct HostRow: View {
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelStore.self) private var tunnels
    let block: HostBlock
    @Binding var selection: SidebarSelection?
    @State private var hovering = false

    private var isSelected: Bool { selection == .host(block.id) }
    private var tileColor: Color { isSelected ? .white.opacity(0.28) : TilePalette.host }
    private var hasActiveTunnel: Bool {
        tunnels.presets(for: block.patterns.first ?? "")
            .contains { tunnels.status(for: $0.id).isRunning }
    }
    private var icon: String {
        if block.kind == .match { return "arrow.triangle.branch" }
        return block.isWildcard ? "asterisk" : "server.rack"
    }

    var body: some View {
        Button {
            selection = .host(block.id)
        } label: {
            HStack(spacing: Spacing.md) {
                IconTile(systemImage: icon, color: tileColor)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Spacing.sm) {
                        Text(block.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                        if store.isFavorite(block) {
                            Image(systemName: "star.fill").font(.system(size: 8))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .yellow)
                        }
                    }
                    if let hostName = block.firstValue(for: "HostName"), !hostName.isEmpty {
                        Text(hostName).font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                    }
                    // Hide the internal `group/` membership tag — it's an encoding,
                    // not a user label (HostDetailView filters it the same way).
                    let tags = store.tags(for: block).filter { !$0.hasPrefix(GroupResolver.groupTagPrefix) }
                    if !tags.isEmpty {
                        Text(tags.map { "#\($0)" }.joined(separator: " "))
                            .font(.system(size: 10)).lineLimit(1)
                            .foregroundStyle(
                                isSelected ? Color.white.opacity(0.75) : Color(nsColor: .tertiaryLabelColor))
                    }
                }
                Spacer(minLength: Spacing.sm)
                // Fixed-width slot: swap bolt → duplicate button on hover to avoid layout jitter.
                ZStack {
                    if hovering {
                        Button {
                            store.duplicateBlock(id: block.id)
                        } label: {
                            Image(systemName: "plus.square.on.square")
                                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Duplicate this host")
                    } else if hasActiveTunnel {
                        Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 10))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .green)
                            .help("A tunnel is active for this host")
                    }
                }
                .frame(width: 18)
            }
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: 42)
            .modifier(RowSelectionBackground(isSelected: isSelected, externalHovering: $hovering))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("host-row-\(block.patterns.first ?? block.title)")
        .foregroundStyle(isSelected ? Color.white : .primary)
        .onHover { hovering = $0 }
    }
}

/// The shared accent-fill / hover background for a selectable sidebar row.
private struct RowSelectionBackground: ViewModifier {
    let isSelected: Bool
    /// When provided the owner drives hover state; this modifier skips its own `.onHover`
    /// so there is exactly one hover region per row rather than two competing ones.
    var externalHovering: Binding<Bool>? = nil
    @State private var internalHovering = false

    private var isHovering: Bool { externalHovering?.wrappedValue ?? internalHovering }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isSelected ? Color.white : .primary)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(fill)
                    .shadow(color: isSelected ? .black.opacity(0.22) : .clear, radius: 3, y: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .onHover { if externalHovering == nil { internalHovering = $0 } }
    }
    private var fill: Color {
        if isSelected { return .accentColor }
        return isHovering ? .controlWash : .clear
    }
}

// MARK: - Drag reorder

/// Attaches drag-to-reorder to a host row when it sits in a reorderable group. A nil
/// `groupID` (favourites, search/filter results) makes the row non-draggable, matching
/// the previous `List`-based behaviour.
private struct ReorderModifier: ViewModifier {
    let block: HostBlock
    let groupID: ConfigStore.DocumentGroup.ID?
    @Binding var draggingHost: HostBlock.ID?
    let store: ConfigStore

    func body(content: Content) -> some View {
        if let groupID {
            content
                .onDrag {
                    draggingHost = block.id
                    return NSItemProvider(object: block.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: HostDropDelegate(
                        target: block, groupID: groupID, draggingHost: $draggingHost, store: store))
        } else {
            content
        }
    }
}

/// Reorders within a single document group as the dragged row passes over others, then
/// commits when the drop lands — delegating the actual move to `ConfigStore.moveBlocks`.
private struct HostDropDelegate: DropDelegate {
    let target: HostBlock
    let groupID: ConfigStore.DocumentGroup.ID
    @Binding var draggingHost: HostBlock.ID?
    let store: ConfigStore

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingHost, draggingID != target.id,
            let group = store.filteredGroups.first(where: { $0.id == groupID }),
            let from = group.blocks.firstIndex(where: { $0.id == draggingID }),
            let to = group.blocks.firstIndex(where: { $0.id == target.id })
        else { return }
        store.moveBlocks(
            in: groupID, fromOffsets: IndexSet(integer: from),
            toOffset: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingHost = nil
        return true
    }
}
