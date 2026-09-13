import Adwaita
import SSHConfigCore

/// One row in the sidebar. Section headers are rows too, so the whole sidebar is
/// a single `GtkListBox` — three lists side by side would each keep their own
/// selection highlight, and GTK offers no way to clear one from outside.
public enum SidebarItem: Identifiable, Equatable {
    case header(String)
    /// A header for one of the app's own groups. Separate from `header` because
    /// it carries rename and delete, and a plain section label does not.
    case groupHeader(String)
    case keys
    case agent
    case knownHosts
    case tunnels
    case issues
    case history
    case globalDefaults
    case background
    /// Keyed by the host's primary alias, not by `HostBlock.ID`. Every parse
    /// mints fresh UUIDs, so a UUID key would lose the selection on every save.
    case host(String)

    public var id: String {
        switch self {
        case .header(let title): "header:\(title)"
        case .groupHeader(let name): "group:\(name)"
        case .keys: "keys"
        case .agent: "agent"
        case .knownHosts: "known-hosts"
        case .tunnels: "tunnels"
        case .issues: "issues"
        case .history: "history"
        case .globalDefaults: "global-defaults"
        case .background: "background"
        case .host(let alias): "host:\(alias)"
        }
    }

    public var isHeader: Bool {
        switch self {
        case .header, .groupHeader: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .header(let title): title
        case .groupHeader(let name): name
        case .keys: "SSH Keys"
        case .agent: "SSH Agent"
        case .knownHosts: "Known Hosts"
        case .tunnels: "Tunnels"
        case .issues: "Issues"
        case .history: "Version History"
        case .globalDefaults: "Global Defaults"
        case .background: "Notifications"
        case .host: ""
        }
    }

    /// The per-area icon. GNOME Settings uses coloured tiles in its own sidebar,
    /// so the app does the same — see docs/design/linux-libadwaita.md §4b.
    public var icon: Icon? {
        switch self {
        case .keys: .default(icon: .dialogPassword)
        case .agent: .default(icon: .avatarDefault)
        case .knownHosts: .default(icon: .securityHigh)
        case .tunnels: .default(icon: .networkTransmitReceive)
        case .issues: .default(icon: .dialogWarning)
        case .history: .default(icon: .documentOpenRecent)
        case .globalDefaults: .default(icon: .emblemSystem)
        case .background: .default(icon: .preferencesSystemNotifications)
        case .host: .default(icon: .networkServer)
        case .header, .groupHeader: nil
        }
    }

    /// The CSS class that paints the tile. Defined in `AreaTileStyle`.
    public var tileClass: String? {
        switch self {
        case .keys: "tile-keys"
        case .agent: "tile-agent"
        case .knownHosts: "tile-known-hosts"
        case .tunnels: "tile-tunnels"
        case .issues: "tile-issues"
        case .history: "tile-history"
        case .globalDefaults: "tile-defaults"
        case .background: "tile-background"
        case .host: "tile-host"
        case .header, .groupHeader: nil
        }
    }
}

/// The tile colours now live with the rest of the visual vocabulary, in
/// `AppStyle`. This name is kept so nothing outside has to change at once.
public typealias AreaTileStyle = AppStyle
