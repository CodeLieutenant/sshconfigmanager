import Adwaita
import Foundation

/// The log window. Same filters as the macOS one.
struct LogView: View {
    var onClose: () -> Void

    @State private var search = ""
    @State private var level = "All levels"
    @State private var range = "Whole session"

    private var entries: [AppLog.Entry] {
        AppLog.entries(search: search, level: level)
    }

    var view: Body {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                SearchEntry()
                    .text($search)
                    .placeholderText("Search")
                    .hexpand()
                DropDown(
                    selection: .init {
                        range
                    } set: {
                        range = $0
                    },
                    values: ["Last 15 min", "Last hour", "Whole session"],
                    id: \.self,
                    description: \.self
                )
                DropDown(
                    selection: .init {
                        level
                    } set: {
                        level = $0
                    },
                    values: ["All levels", "Notice & above", "Errors only"],
                    id: \.self,
                    description: \.self
                )
                Button(icon: .default(icon: .editCopy)) {
                    AdwaitaApp.copy(entries.map(\.line).joined(separator: "\n"))
                }
                .flat()
                .tooltip("Copy visible entries")
            }
            ScrollView {
                if entries.isEmpty {
                    StatusPage(
                        "No log entries yet",
                        icon: .default(icon: .accessoriesTextEditor),
                        description: "The log window shows entries from this run of the app only."
                    )
                } else {
                    PreferencesGroup("") {
                        ForEach(entries) { entry in
                            ActionRow(entry.message)
                                .useMarkup(false)
                                .subtitle("\(entry.time) · \(entry.level) · \(entry.category)")
                                .subtitleSelectable()
                        }
                    }
                }
            }
            .vexpand()
            HStack(spacing: 12) {
                Text("\(entries.count) entries")
                    .dimLabel()
                    .hexpand()
                    .halign(.start)
                Text("Current run only — earlier sessions are not kept.")
                    .caption()
                    .dimLabel()
                Button("Close") { onClose() }
            }
        }
        .padding(18)
    }
}

/// The in-app log. A ring buffer in memory, which is all the log window shows on
/// macOS too — earlier sessions are not kept.
public enum AppLog {
    public struct Entry: Identifiable, Equatable {
        public let id: Int
        public let time: String
        public let level: String
        public let category: String
        public let message: String

        var line: String { "\(time) \(level) [\(category)] \(message)" }
    }

    nonisolated(unsafe) private static var buffer: [Entry] = []
    private static let limit = 2000

    public static func record(_ message: String, level: String = "Info", category: String = "app") {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        buffer.append(
            Entry(
                id: buffer.count,
                time: formatter.string(from: Date()),
                level: level,
                category: category,
                message: message
            )
        )
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
    }

    static func entries(search: String, level: String) -> [Entry] {
        let query = search.lowercased().trimmingCharacters(in: .whitespaces)
        return buffer.filter { entry in
            let levelMatches: Bool
            switch level {
            case "Errors only": levelMatches = entry.level == "Error"
            case "Notice & above": levelMatches = entry.level != "Debug"
            default: levelMatches = true
            }
            guard levelMatches else { return false }
            guard !query.isEmpty else { return true }
            return entry.message.lowercased().contains(query)
                || entry.category.lowercased().contains(query)
        }
    }

    static func recentText() -> String {
        let recent = buffer.suffix(40)
        return recent.isEmpty ? "No log entries yet." : recent.map(\.line).joined(separator: "\n")
    }
}
