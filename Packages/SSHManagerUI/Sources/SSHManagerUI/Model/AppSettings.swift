import Foundation
import SSHConfigCore

/// The preferences the app keeps. One field per control in the settings dialog.
///
/// The macOS build stores these in its SQLite database. Linux writes one JSON
/// file under the XDG config directory: there is no other persisted state here,
/// and a file a user can read and edit beats a database they cannot.
public struct AppSettings: Codable, Equatable {
    // General — Saving
    public var automaticallySave = true
    // General — Startup
    public var launchAtLogin = false
    // General — Editing
    public var confirmBeforeDeletingHost = true
    // General — New host defaults
    public var defaultUser = ""
    public var defaultPort = 0
    // General — Background app (the Linux answer to the menu-bar extras)
    public var runInBackground = false
    public var showTunnelNotifications = true
    // General — Host key monitoring
    public var monitorHostKeys = false
    public var hostKeyCheckInterval = "Hour"
    public var notifyOnHostKeyChange = true
    // General — Live file watching
    public var watchFiles = false
    public var notifyOnExternalChange = true

    // Appearance
    public var theme = "System"
    public var accent = "System"
    public var density = "Comfortable"
    public var codeFont = "System Monospaced"
    public var codeFontSize = 12

    // Editor
    public var openRawEditorByDefault = false
    public var showLineNumbers = true
    public var softWrap = true
    public var syntaxHighlighting = true
    public var codeCompletion = true
    public var showDocumentationPanel = true
    public var tabWidth = 4

    // Keys & Tunnels
    public var terminalCommand = "x-terminal-emulator"
    public var commandTemplate = ""
    public var defaultKeyAlgorithm = "Ed25519"
    public var notifyOnTunnelChange = true
    public var rearmAutostartTunnels = true
    public var maxReconnectBackoff = 60

    // History
    public var keepVersionHistory = true
    public var maximumVersionsKept = 100

    // Audit
    public var auditWeakAlgorithms = true
    public var auditLoosePermissions = true
    public var auditMissingPassphrase = false
    public var auditUnusedKeys = true
    public var auditWeakServerCrypto = true
    public var refuseWeakServer = false

    // Privacy
    public var shareCrashReports = false

    public init() {}

    /// The audit categories the Issues screen asks for, built from the toggles.
    public var enabledAuditCategories: Set<KeyAuditor.Category> {
        var categories: Set<KeyAuditor.Category> = []
        if auditWeakAlgorithms { categories.insert(.weakAlgorithm) }
        if auditLoosePermissions { categories.insert(.permissions) }
        if auditMissingPassphrase { categories.insert(.passphrase) }
        if auditUnusedKeys { categories.insert(.orphan) }
        return categories
    }

    public static let themes = ["System", "Light", "Dark"]
    public static let accents = [
        "System", "Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Teal", "Graphite",
    ]
    public static let densities = ["Comfortable", "Compact"]
    public static let codeFonts = [
        "System Monospaced", "Source Code Pro", "JetBrains Mono", "Fira Code", "DejaVu Sans Mono",
        "Liberation Mono", "Ubuntu Mono", "Cascadia Code",
    ]
    public static let hostKeyIntervals = ["15 minutes", "30 minutes", "Hour", "6 hours", "Day"]
    public static let keyAlgorithms = [
        "Ed25519", "ECDSA (P-256)", "ECDSA (P-384)", "ECDSA (P-521)",
    ]
    /// The terminals a Linux desktop is likely to have. `x-terminal-emulator` is
    /// the Debian alternatives entry, which resolves to whatever the user picked.
    public static let terminals = [
        "x-terminal-emulator", "gnome-terminal", "kgx", "ptyxis", "konsole", "alacritty",
        "kitty", "wezterm", "foot", "xterm",
    ]
}

extension AppSettings {
    public static var path: String {
        let base =
            ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? "\(SSHDirectory.home)/.config"
        return "\(base)/sshmanager/settings.json"
    }

    public static func load() -> AppSettings {
        guard let data = FileManager.default.contents(atPath: path),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return settings
    }

    public func save() {
        let directory = URL(fileURLWithPath: Self.path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
    }
}
