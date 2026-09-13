//
//  VersionHistoryView.swift
//  sshconfigmanager
//
//  Time-machine-style version history. A real commit graph on the left (lanes +
//  dots + branch lines, newest at top) acts as the time scrubber; the right pane
//  is an immersive view of the selected snapshot — its metadata and a diff against
//  the parent or the live config. Backed by `ConfigHistoryStore` (SQLite); the
//  store/DB are unchanged — this is purely presentation.
//

import SSHConfigCore
import SwiftUI

struct VersionHistoryView: View {
    @Environment(ConfigStore.self) private var store

    @State private var selectedID: String?
    @State private var selectedFile: String? // nil = combined diff across every tracked file
    @State private var fileChanges: [ConfigHistoryStore.FileChange] = []
    @State private var diffMode: DiffMode = .change
    @State private var diffLines: [TextDiff.Line] = []
    @State private var confirmRestore = false
    @State private var renameTarget: ConfigVersion?
    @State private var renameText = ""
    @State private var confirmClear = false
    @State private var showSnapshotSheet = false
    @State private var snapshotName = ""
    @State private var toastMessage: String?

    /// What the diff pane compares the selected version against.
    enum DiffMode: String, CaseIterable, Identifiable {
        case change = "This change"
        case current = "Compared to now"
        var id: String { rawValue }
    }

    private var versions: [ConfigVersion] { store.history.versions }
    private var headID: String? { store.history.headID }
    private var selected: ConfigVersion? { versions.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                tile: (icon: "clock.arrow.circlepath", color: TilePalette.history),
                title: "Version History",
                subtitle: versions.isEmpty ? "" : "\(versions.count) version\(versions.count == 1 ? "" : "s")"
            ) {
                ChromeButton(title: "Snapshot Now…", systemImage: "bookmark", kind: .secondary) {
                    snapshotName = ""
                    showSnapshotSheet = true
                }
                if !versions.isEmpty {
                    ChromeButton(title: "Clear History…", systemImage: "trash", kind: .secondary, tint: .red) {
                        confirmClear = true
                    }
                }
            }
            if versions.isEmpty {
                ContentUnavailableView(
                    "No history yet", systemImage: "clock.arrow.circlepath",
                    description: Text("A version is recorded automatically each time you edit your SSH config.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    graphRail
                    detailPane
                }
            }
        }
        .background(WindowWash())
        .task {
            await store.history.refresh()
            ensureSelection()
        }
        .onChange(of: versions.map(\.id)) { _, _ in ensureSelection() }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore, presenting: selected) { version in
            Button("Restore", role: .destructive) {
                store.restoreVersion(version.id)
                toastMessage = "Version restored"
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                "Your files will be set to this version. Nothing is deleted — every other version stays in the timeline, and editing now starts a new branch from here."
            )
        }
        .confirmationDialog("Clear the entire history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                store.clearHistory()
                toastMessage = "History cleared"
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every recorded version. Your current config files on disk are not changed.")
        }
        .sheet(item: $renameTarget) { renameSheet($0) }
        .sheet(isPresented: $showSnapshotSheet) { snapshotSheet }
        .toast($toastMessage)
    }

    private func ensureSelection() {
        guard selectedID == nil || !versions.contains(where: { $0.id == selectedID }) else { return }
        selectedID = headID ?? versions.first?.id
    }

    // MARK: - Commit graph rail

    private var graphRail: some View {
        let layout = GraphLayout(versions: versions)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(layout.rows) { row in
                    graphRow(row, columns: layout.columns)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 332)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.appSeparator).frame(width: 1) }
    }

    private func graphRow(_ row: GraphLayout.Row, columns: Int) -> some View {
        let version = row.version
        let isSelected = version.id == selectedID
        let graphWidth = CGFloat(columns) * GraphLayout.laneWidth + 12
        return HStack(spacing: 8) {
            GraphCell(row: row, columns: columns)
                .frame(width: graphWidth, height: GraphLayout.rowHeight)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(for: version))
                        .fontWeight(version.name == nil ? .regular : .semibold)
                        .lineLimit(1)
                    if version.id == headID {
                        Text("NOW").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: icon(for: version.source))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(sourceLabel(version.source)).font(.system(size: 10)).foregroundStyle(.secondary)
                    if version.addedLines > 0 {
                        Text("+\(version.addedLines)").font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundStyle(.green)
                    }
                    if version.removedLines > 0 {
                        Text("−\(version.removedLines)").font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundStyle(.red)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 10)
        .frame(height: GraphLayout.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = version.id }
        .contextMenu {
            Button("Restore This Version") {
                selectedID = version.id
                confirmRestore = true
            }
            Button(version.name == nil ? "Name…" : "Rename…") { beginRename(version) }
            if version.name != nil {
                Button("Remove Name", role: .destructive) {
                    store.renameVersion(version.id, to: nil)
                    toastMessage = "Name removed"
                }
            }
        }
    }

    private func title(for version: ConfigVersion) -> String {
        if let name = version.name, !name.isEmpty { return name }
        return version.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(selected)
                Divider().opacity(0.4)
                HStack {
                    Picker("", selection: $diffMode) {
                        ForEach(DiffMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                if !fileChanges.isEmpty {
                    fileChangeChips
                        .padding(.horizontal, 18).padding(.bottom, 10)
                }
                diffScroll(for: selected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: selected.id) {
                selectedFile = nil
                fileChanges = await store.history.fileChanges(for: selected.id)
            }
        } else {
            ContentUnavailableView(
                "Select a version", systemImage: "clock",
                description: Text("Pick a point on the timeline to see what changed.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Which tracked file the diff pane shows — "All files" (the flattened combined
    /// view) plus one chip per file this version actually touched, so a change to an
    /// `Include`d group file is visible on its own instead of buried in the blob.
    private var fileChangeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                fileChip(title: "All files", isSelected: selectedFile == nil) { selectedFile = nil }
                ForEach(fileChanges) { change in
                    fileChip(
                        title: fileDisplayName(change.relPath), kind: change.kind,
                        isSelected: selectedFile == change.relPath
                    ) {
                        selectedFile = change.relPath
                    }
                }
            }
        }
    }

    private func fileChip(
        title: String, kind: ConfigHistoryStore.FileChangeKind? = nil, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let kind {
                    Image(systemName: fileChangeIcon(kind))
                        .font(.system(size: 9))
                        .foregroundStyle(fileChangeColor(kind))
                }
                Text(title).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.controlWash, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func fileDisplayName(_ relPath: String) -> String {
        if store.isMainConfigRelPath(relPath) { return "Main Config" }
        if let groupName = store.groupName(forRelPath: relPath) { return groupName }
        return (relPath as NSString).lastPathComponent
    }

    private func fileChangeIcon(_ kind: ConfigHistoryStore.FileChangeKind) -> String {
        switch kind {
        case .added: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .removed: return "minus.circle.fill"
        }
    }

    private func fileChangeColor(_ kind: ConfigHistoryStore.FileChangeKind) -> Color {
        switch kind {
        case .added: return .green
        case .modified: return .blue
        case .removed: return .red
        }
    }

    private func detailHeader(_ version: ConfigVersion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: version))
                        .font(.system(size: 22, weight: .semibold))
                    HStack(spacing: 8) {
                        Label(sourceLabel(version.source), systemImage: icon(for: version.source))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(version.createdAt.formatted(date: .complete, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if version.id == headID {
                    Label("Current", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            HStack(spacing: 10) {
                statChip("+\(version.addedLines)", .green)
                statChip("−\(version.removedLines)", .red)
                statChip("\(version.filesChanged) file\(version.filesChanged == 1 ? "" : "s")", .secondary)
                Spacer()
                ChromeButton(title: "Name", systemImage: "pencil", kind: .secondary) { beginRename(version) }
                ChromeButton(title: "Restore", systemImage: "arrow.uturn.backward", kind: .prominent) {
                    confirmRestore = true
                }
                .disabled(version.id == headID)
            }
        }
        .padding(Spacing.xxxl)
    }

    private func statChip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(color == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.controlWash, in: Capsule())
    }

    private func diffScroll(for version: ConfigVersion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if diffLines.isEmpty {
                    Text(
                        diffMode == .change && version.parentID == nil && selectedFile == nil
                            ? "This is the baseline — nothing came before it."
                            : "No differences."
                    )
                    .font(.callout).foregroundStyle(.secondary).padding(16)
                } else {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        Text(prefix(line.kind) + line.text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 1)
                            .background(background(line.kind))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.appCode)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 1)
        )
        .padding([.horizontal, .bottom], Spacing.xxxl)
        .task(id: "\(version.id)|\(diffMode.rawValue)|\(selectedFile ?? "*")") { await loadDiff(for: version) }
    }

    private func loadDiff(for version: ConfigVersion) async {
        guard let selectedFile else {
            let newText = await store.history.displayText(for: version.id)
            let oldText: String
            switch diffMode {
            case .change:
                oldText = version.parentID == nil ? "" : await store.history.displayText(for: version.parentID!)
            case .current:
                oldText = store.workingTreeDisplayText
            }
            diffLines = TextDiff.diff(old: oldText, new: newText)
            return
        }
        // Same shape as the "All files" branch above, but scoped to one tracked file
        // via `ConfigHistoryStore.fileText(_:at:)` instead of the flattened blob.
        let newText = await store.history.fileText(selectedFile, at: version.id)
        let oldText: String
        switch diffMode {
        case .change:
            oldText = version.parentID == nil ? "" : await store.history.fileText(selectedFile, at: version.parentID!)
        case .current:
            oldText = store.currentText(forRelPath: selectedFile) ?? ""
        }
        diffLines = TextDiff.diff(old: oldText, new: newText)
    }

    // MARK: - Rename

    private func beginRename(_ version: ConfigVersion) {
        renameText = version.name ?? ""
        renameTarget = version
    }

    private func renameSheet(_ version: ConfigVersion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this version").font(.headline)
            TextField("e.g. Before VPN changes", text: $renameText)
                .textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                Button("Save") {
                    store.renameVersion(version.id, to: renameText)
                    renameTarget = nil
                    toastMessage = "Name updated"
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    /// "Before I make a risky change" checkpoint — records every tracked file (main
    /// config + every `Include`d group file) right now, named or not.
    private var snapshotSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snapshot current state").font(.headline)
            Text(
                "Records every tracked file — the main config and any group files —"
                    + " as a named point you can come back to."
            )
            .font(.caption).foregroundStyle(.secondary).frame(width: 320, alignment: .leading)
            TextField("e.g. Before VPN changes", text: $snapshotName)
                .textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { showSnapshotSheet = false }
                Button("Snapshot") {
                    let trimmed = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.snapshotNow(name: trimmed.isEmpty ? nil : trimmed)
                    showSnapshotSheet = false
                    toastMessage = "Snapshot created"
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: - Styling helpers

    private func sourceLabel(_ source: String) -> String {
        switch ConfigVersionSource(rawValue: source) {
        case .initial: return "Baseline"
        case .autosave: return "Edit"
        case .manual: return "Snapshot"
        case .restore: return "Restore"
        case .external: return "Changed on disk"
        case .imported: return "Imported backup"
        case .remote: return "Synced from GitHub"
        case .none: return source
        }
    }
    private func icon(for source: String) -> String {
        switch ConfigVersionSource(rawValue: source) {
        case .initial: return "flag.fill"
        case .autosave: return "square.and.pencil"
        case .manual: return "bookmark.fill"
        case .restore: return "arrow.uturn.backward"
        case .external: return "externaldrive.fill"
        case .imported: return "tray.and.arrow.down.fill"
        case .remote: return "arrow.triangle.2.circlepath"
        case .none: return "clock"
        }
    }
    private func prefix(_ kind: TextDiff.Kind) -> String {
        switch kind {
        case .added: return "+ "
        case .removed: return "− "
        case .context: return "  "
        }
    }
    private func color(_ kind: TextDiff.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .primary
        }
    }
    private func background(_ kind: TextDiff.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context: return .clear
        }
    }
}

// MARK: - Commit graph layout

/// Computes a git-style lane layout for the version tree (newest at the top). Each
/// row knows its node column plus the lane state entering from the top and leaving
/// to the bottom, which is enough to draw connecting/branch lines per row.
private struct GraphLayout {
    static let rowHeight: CGFloat = 46
    static let laneWidth: CGFloat = 16

    struct Row: Identifiable {
        let version: ConfigVersion
        let column: Int
        let lanesAbove: [String?] // lane → commit id it routes toward, entering the top edge
        let lanesBelow: [String?] // … leaving the bottom edge
        var id: String { version.id }
    }

    let rows: [Row]
    let columns: Int

    init(versions: [ConfigVersion]) {
        // `versions` is newest-first; a child sits above its parent. Walking top→down,
        // a lane reserved for a commit is created by its (already-seen) child; a fork
        // shows up as several lanes converging on the parent.
        let known = Set(versions.map(\.id))
        var lanes: [String?] = []
        var built: [Row] = []
        var maxColumns = 0

        for version in versions {
            let above = lanes // state entering this row's top edge (previous row's bottom)

            var column = lanes.firstIndex(of: version.id)
            if column == nil {
                if let free = lanes.firstIndex(where: { $0 == nil }) {
                    lanes[free] = version.id
                    column = free
                } else {
                    lanes.append(version.id)
                    column = lanes.count - 1
                }
            }
            let myColumn = column!

            // Other lanes also targeting this commit (extra fork children) converge here.
            let merging = lanes.indices.filter { $0 != myColumn && lanes[$0] == version.id }

            if let parent = version.parentID, known.contains(parent) {
                lanes[myColumn] = parent
            } else {
                lanes[myColumn] = nil
            }
            for c in merging { lanes[c] = nil }
            // Trim trailing free lanes so the graph doesn't keep widening forever.
            while let last = lanes.last, last == nil { lanes.removeLast() }

            built.append(Row(version: version, column: myColumn, lanesAbove: above, lanesBelow: lanes))
            maxColumns = max(maxColumns, max(above.count, lanes.count))
        }

        rows = built
        columns = max(1, maxColumns)
    }
}

/// Draws one row of the commit graph: pass-through lanes, the lines from this node
/// up to the children that branch off it, the line down to its parent, and the dot.
private struct GraphCell: View {
    let row: GraphLayout.Row
    let columns: Int

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .mint]
    private func laneColor(_ column: Int) -> Color { Self.palette[column % Self.palette.count] }

    var body: some View {
        Canvas { context, size in
            let w = GraphLayout.laneWidth
            let midY = size.height / 2
            func x(_ c: Int) -> CGFloat { CGFloat(c) * w + w / 2 + 2 }

            // Pass-through lanes (other branches running alongside this row).
            for (c, target) in row.lanesAbove.enumerated() where target != nil && target != row.version.id {
                var p = Path()
                p.move(to: CGPoint(x: x(c), y: 0))
                p.addLine(to: CGPoint(x: x(c), y: size.height))
                context.stroke(p, with: .color(laneColor(c).opacity(0.85)), lineWidth: 2)
            }

            // Lines coming down from this node's children (incoming lanes that target it).
            for (c, target) in row.lanesAbove.enumerated() where target == row.version.id {
                var p = Path()
                p.move(to: CGPoint(x: x(c), y: 0))
                if c == row.column {
                    p.addLine(to: CGPoint(x: x(c), y: midY))
                } else {
                    // Curve a fork child into the node.
                    p.addCurve(
                        to: CGPoint(x: x(row.column), y: midY),
                        control1: CGPoint(x: x(c), y: midY * 0.6),
                        control2: CGPoint(x: x(row.column), y: midY * 0.4))
                }
                context.stroke(p, with: .color(laneColor(c).opacity(0.85)), lineWidth: 2)
            }

            // Line down to this node's parent.
            if row.column < row.lanesBelow.count, row.lanesBelow[row.column] != nil {
                var p = Path()
                p.move(to: CGPoint(x: x(row.column), y: midY))
                p.addLine(to: CGPoint(x: x(row.column), y: size.height))
                context.stroke(p, with: .color(laneColor(row.column).opacity(0.85)), lineWidth: 2)
            }

            // The node dot.
            let r: CGFloat = 5
            let dot = CGRect(x: x(row.column) - r, y: midY - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: dot), with: .color(laneColor(row.column)))
            context.stroke(
                Path(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5)),
                with: .color(.black.opacity(0.5)), lineWidth: 1)
        }
    }
}
