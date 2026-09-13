import Adwaita
import SSHConfigCore

/// L10 · Command palette. One search field over every host and every area, with
/// the same fuzzy match the macOS build uses.
struct CommandPaletteView: View {
    @Binding var store: ConfigStore
    var onSelect: (String) -> Void
    var onStatus: (String) -> Void

    @State private var query = ""

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: Icon
        let tileClass: String
    }

    private var entries: [Entry] {
        let areas: [SidebarItem] = [.keys, .agent, .knownHosts, .tunnels, .issues, .history]
        let areaEntries = areas.map { item in
            Entry(
                id: item.id,
                title: item.title,
                subtitle: "Go to",
                icon: item.icon ?? .default(icon: .goNext),
                tileClass: item.tileClass ?? "tile-host"
            )
        }
        let hostEntries = store.hosts.map { block in
            Entry(
                id: SidebarItem.host(block.sidebarKey).id,
                title: block.title,
                subtitle: block.connectionTarget?.host ?? "Host",
                icon: .default(icon: .networkServer),
                tileClass: "tile-host"
            )
        }
        let all = areaEntries + hostEntries
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return
            all
            .compactMap { entry -> (Entry, Int)? in
                guard
                    let score = FuzzyMatch.score(query: trimmed, candidate: entry.title)
                        ?? FuzzyMatch.score(query: trimmed, candidate: entry.subtitle)
                else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var view: Body {
        VStack(spacing: 12) {
            SearchEntry()
                .text($query)
                .placeholderText("Search hosts and areas")
            ScrollView {
                if entries.isEmpty {
                    StatusPage(
                        "No matches",
                        icon: .default(icon: .systemSearch),
                        description: "Nothing here matches “\(query.markupEscaped)”."
                    )
                } else {
                    PreferencesGroup("") {
                        ForEach(entries) { entry in
                            ActionRow(entry.title)
                                .useMarkup(false)
                                .subtitle(entry.subtitle)
                                .prefix {
                                    Symbol(icon: entry.icon)
                                        .style("area-tile")
                                        .style(entry.tileClass)
                                        .valign(.center)
                                }
                                .activated { onSelect(entry.id) }
                        }
                    }
                }
            }
            .vexpand()
        }
        .padding(18)
    }
}
