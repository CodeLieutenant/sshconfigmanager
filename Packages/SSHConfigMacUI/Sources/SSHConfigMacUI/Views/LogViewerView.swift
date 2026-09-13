//
//  LogViewerView.swift
//  SSHConfigMacUI
//
//  The in-app log window (View ▸ Open Logs, ⇧⌘L). Reads the app's own unified-log
//  entries back through `LogCollector` and presents them Console-style: a filter
//  bar, a table, and a detail pane for the selected line.
//
//  Scope caveat, inherited from `LogCollector`: `OSLogStore(scope:
//  .currentProcessIdentifier)` returns entries from *this* process only, so the
//  window starts empty-ish after launch and can never show a previous session. The
//  header says so, otherwise a user hunting a crash from the last run reads the
//  empty window as "logging is broken".
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LogViewerView: View {
    @State private var model = LogViewerModel()

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            table
            if let selected = model.selectedEntry {
                Divider()
                detail(selected)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 720, minHeight: 420)
        .accessibilityIdentifier("log-viewer-root")
        .task { await model.startLiveTail() }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: Spacing.md) {
            Picker("Range", selection: $model.range) {
                ForEach(LogViewerModel.Range.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Picker("Level", selection: $model.minimumLevel) {
                ForEach(LogViewerModel.LevelFilter.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Picker("Category", selection: $model.category) {
                Text("All categories").tag(String?.none)
                Divider()
                ForEach(model.availableCategories, id: \.self) { category in
                    Text(category).tag(String?.some(category))
                }
            }
            .labelsHidden()
            .frame(width: 150)

            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)

            Spacer(minLength: Spacing.md)

            Toggle(isOn: $model.isLive) {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
            }
            .toggleStyle(.button)
            .help("Refresh automatically every two seconds")

            Button {
                model.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload entries now")

            Menu {
                Button("Copy Visible Entries") { model.copyVisible() }
                Button("Save Visible Entries…") { model.saveVisible() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 44)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Table

    private var table: some View {
        Table(model.visibleEntries, selection: $model.selection) {
            TableColumn("Time") { entry in
                Text(entry.timeText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100, max: 130)

            TableColumn("Level") { entry in
                Text(entry.level)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(entry.levelColor)
            }
            .width(min: 60, ideal: 70, max: 90)

            TableColumn("Category") { entry in
                Text(entry.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110, max: 160)

            TableColumn("Message") { entry in
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .overlay {
            if model.visibleEntries.isEmpty {
                ContentUnavailableView(
                    model.entries.isEmpty ? "No log entries yet" : "No matching entries",
                    systemImage: "text.alignleft",
                    description: Text(
                        model.entries.isEmpty
                            ? "The log window shows entries from the current run of the app only."
                            : "Change the filters or the search text."))
            }
        }
    }

    // MARK: - Detail + status

    private func detail(_ entry: LogViewerModel.Row) -> some View {
        ScrollView {
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.lg)
        }
        .frame(height: 120)
        .background(.quaternary.opacity(0.25))
    }

    private var statusBar: some View {
        HStack(spacing: Spacing.md) {
            Text("\(model.visibleEntries.count) of \(model.entries.count) entries")
            Text("Current run only — earlier sessions are not kept.")
                .foregroundStyle(.tertiary)
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }
}

// MARK: - Model

@Observable
final class LogViewerModel {
    struct Row: Identifiable, Sendable {
        let id: Int
        let date: Date
        let level: String
        let category: String
        let message: String

        var timeText: String { Row.timeFormatter.string(from: date) }

        var levelColor: Color {
            switch level {
            case "error", "fault": return .red
            case "notice": return .primary
            case "debug": return Color(nsColor: .tertiaryLabelColor)
            default: return .secondary
            }
        }

        var lineText: String {
            "\(Row.isoFormatter.string(from: date)) [\(level)] \(category): \(message)"
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()

        private static let isoFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    }

    enum Range: String, CaseIterable, Identifiable {
        case fifteenMinutes, oneHour, session

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fifteenMinutes: return "Last 15 min"
            case .oneHour: return "Last hour"
            case .session: return "Whole session"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .fifteenMinutes: return 900
            case .oneHour: return 3600
            // The process-scoped store cannot outlive the launch, so an
            // intentionally over-long window means "everything there is".
            case .session: return 60 * 60 * 24 * 7
            }
        }
    }

    enum LevelFilter: String, CaseIterable, Identifiable {
        case all, noticeAndAbove, errorsOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All levels"
            case .noticeAndAbove: return "Notice & above"
            case .errorsOnly: return "Errors only"
            }
        }

        var minimumRank: Int {
            switch self {
            case .all: return 0
            case .noticeAndAbove: return 2
            case .errorsOnly: return 3
            }
        }
    }

    var entries: [Row] = []
    var selection: Row.ID?
    var searchText = ""
    var category: String?
    var minimumLevel: LevelFilter = .all
    var range: Range = .oneHour {
        didSet { reload() }
    }
    var isLive = true
    var isLoading = false

    var selectedEntry: Row? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    var availableCategories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    var visibleEntries: [Row] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let floor = minimumLevel.minimumRank
        return entries.filter { entry in
            if let category, entry.category != category { return false }
            if Self.rank(of: entry.level) < floor { return false }
            if needle.isEmpty { return true }
            return entry.message.lowercased().contains(needle)
                || entry.category.lowercased().contains(needle)
        }
    }

    /// Loads once, then re-loads every two seconds for as long as the window lives
    /// and "Live" is on. Cancellation comes from the `.task` modifier that owns it.
    func startLiveTail() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if isLive { await load() }
        }
    }

    func reload() {
        Task { await load() }
    }

    private func load() async {
        isLoading = true
        let seconds = range.seconds
        // `collect` walks the whole log store synchronously; keep it off the main
        // actor so a busy log does not stutter the window.
        let collected = await Task.detached(priority: .utility) {
            LogCollector.collect(since: seconds)
        }.value
        entries = collected.enumerated().map { index, entry in
            Row(
                id: index, date: entry.date, level: entry.level,
                category: entry.category, message: entry.message)
        }
        if let selection, !entries.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        isLoading = false
    }

    func copyVisible() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleText(), forType: .string)
    }

    func saveVisible() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "sshconfigmanager-\(Self.fileStamp()).log"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try visibleText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.diagnostics.error("log export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func visibleText() -> String {
        visibleEntries.map(\.lineText).joined(separator: "\n") + "\n"
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func rank(of level: String) -> Int {
        switch level {
        case "debug": return 0
        case "info": return 1
        case "notice": return 2
        case "error": return 3
        case "fault": return 4
        default: return 2
        }
    }
}
