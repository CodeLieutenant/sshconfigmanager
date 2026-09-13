//
//  AppSettings.swift
//  sshconfigmanager
//
//  App preferences, persisted in the shared SQLite database (AppDatabase's
//  `settings` key/value table) instead of UserDefaults. Values start at their
//  defaults and are loaded asynchronously at launch (no blocking the main
//  thread); writes go to SQLite in the background. Existing UserDefaults values
//  are imported on first run. The settings here are read well after launch
//  (a save, a quit, a notification), so the brief default-until-loaded window
//  is invisible in practice.
//
//  This is a developer-tool surface, so the catalogue is deliberately broad:
//  appearance, the raw-config code editor, startup/new-host defaults, key and
//  tunnel defaults, version history, and the key-health audit. Each property is
//  one stored key; adding another is property + key + a line in `load()`.
//

import Crypto
import Foundation
import Observation
import SSHConfigCore
import SSHConfigServices

// MARK: - Preference enums

/// Window/app color scheme. `system` defers to the OS appearance (the default and
/// the value that honors the user's global Light/Dark/Auto choice).
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// An optional tint override. The design language uses the user's *system* accent by
/// default (`system` → no override); these let a developer pin the app to a fixed hue
/// without changing their system-wide accent. Status and diff colors are unaffected.
enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case system, blue, purple, pink, red, orange, yellow, green, teal, graphite
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        default: return rawValue.capitalized
        }
    }
}

/// Control density for the main window — maps onto SwiftUI's `ControlSize`. `compact`
/// trades a little air for more rows on screen, which power users tend to prefer.
enum UIDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable, compact
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    // MARK: Keys

    static let autosaveEnabledKey = "autosaveEnabled"
    static let showMenuBarExtraKey = "showMenuBarExtra"
    static let showTunnelMenuBarKey = "showTunnelMenuBar"
    static let tunnelNotificationsEnabledKey = "tunnelNotificationsEnabled"
    static let hostKeyMonitorEnabledKey = "hostKeyMonitorEnabled"
    static let hostKeyNotificationsEnabledKey = "hostKeyNotificationsEnabled"
    static let hostKeyCheckIntervalMinutesKey = "hostKeyCheckIntervalMinutes"
    static let liveFileWatchEnabledKey = "liveFileWatchEnabled"
    static let liveFileWatchNotificationsEnabledKey = "liveFileWatchNotificationsEnabled"
    static let preferredTerminalIDKey = "preferredTerminalID"
    static let terminalCommandTemplateKey = "terminalCommandTemplate"
    static let configHistoryEnabledKey = "configHistoryEnabled"
    static let maxConfigVersionsKey = "maxConfigVersions"
    static let auditWeakKeysKey = "auditWeakKeys"
    static let auditKeyPermissionsKey = "auditKeyPermissions"
    static let auditMissingPassphraseKey = "auditMissingPassphrase"
    static let auditOrphanedKeysKey = "auditOrphanedKeys"
    static let auditServerAlgorithmsKey = "auditServerAlgorithms"
    static let strictServerAlgorithmsKey = "strictServerAlgorithms"
    // Appearance
    static let appearanceModeKey = "appearanceMode"
    static let accentChoiceKey = "accentChoice"
    static let uiDensityKey = "uiDensity"
    static let editorFontNameKey = "editorFontName"
    static let editorFontSizeKey = "editorFontSize"
    // Editor
    static let editorShowLineNumbersKey = "editorShowLineNumbers"
    static let editorSoftWrapKey = "editorSoftWrap"
    static let editorTabWidthKey = "editorTabWidth"
    static let editorSyntaxHighlightingKey = "editorSyntaxHighlighting"
    static let editorIntelliSenseKey = "editorIntelliSense"
    static let editorShowDocsKey = "editorShowDocs"
    static let defaultToRawEditorKey = "defaultToRawEditor"
    // General / new-host defaults
    static let confirmBeforeDeleteKey = "confirmBeforeDelete"
    static let defaultHostUserKey = "defaultHostUser"
    static let defaultHostPortKey = "defaultHostPort"
    // Keys & tunnels defaults
    static let defaultKeyAlgorithmKey = "defaultKeyAlgorithm"
    static let restoreTunnelsOnLaunchKey = "restoreTunnelsOnLaunch"
    static let tunnelMaxBackoffSecondsKey = "tunnelMaxBackoffSeconds"
    static let gistSyncEnabledKey = "gistSyncEnabled"
    static let gistEncryptionEnabledKey = "gistEncryptionEnabled"
    static let gistIDKey = "gistID"
    static let gistLastSyncedVersionKey = "gistLastSyncedVersion"
    static let gistLastSyncedLocalHashKey = "gistLastSyncedLocalHash"
    static let gistPendingPushKey = "gistPendingPush"
    static let gistLastSyncedAtKey = "gistLastSyncedAt"

    // MARK: Saving

    var autosaveEnabled = true { didSet { persist(Self.autosaveEnabledKey, autosaveEnabled) } }

    // MARK: Menu bar

    var showMenuBarExtra = true { didSet { persist(Self.showMenuBarExtraKey, showMenuBarExtra) } }
    /// Show a dedicated menu-bar status item, listing each live tunnel, whenever at
    /// least one tunnel is running. Independent of `showMenuBarExtra`.
    var showTunnelMenuBar = true { didSet { persist(Self.showTunnelMenuBarKey, showTunnelMenuBar) } }
    /// Post a local notification when a tunnel's health changes (degraded/failed).
    /// Default off; matches the `default: false` used when loading the stored value.
    var tunnelNotificationsEnabled = false {
        didSet { persist(Self.tunnelNotificationsEnabledKey, tunnelNotificationsEnabled) }
    }

    // MARK: Known-hosts monitor

    var hostKeyMonitorEnabled = true { didSet { persist(Self.hostKeyMonitorEnabledKey, hostKeyMonitorEnabled) } }
    /// Post a local notification when the monitor detects a changed / new host key.
    var hostKeyNotificationsEnabled = true {
        didSet { persist(Self.hostKeyNotificationsEnabledKey, hostKeyNotificationsEnabled) }
    }
    /// How often the monitor sweeps, in minutes (clamped to a sane floor at use sites).
    var hostKeyCheckIntervalMinutes = 60 {
        didSet { persist(Self.hostKeyCheckIntervalMinutesKey, hostKeyCheckIntervalMinutes) }
    }

    // MARK: Live file watching

    var liveFileWatchEnabled = true { didSet { persist(Self.liveFileWatchEnabledKey, liveFileWatchEnabled) } }
    /// Post a local notification when a live watcher detects an external change.
    var liveFileWatchNotificationsEnabled = true {
        didSet { persist(Self.liveFileWatchNotificationsEnabledKey, liveFileWatchNotificationsEnabled) }
    }

    // MARK: Terminal

    /// Which terminal `Connect` opens. A `TerminalPreset.id`; defaults to Terminal.
    var preferredTerminalID = "terminal" { didSet { persist(Self.preferredTerminalIDKey, preferredTerminalID) } }
    /// Optional wrapper around the built command, with a `{ssh}` placeholder
    /// (e.g. `tmux new-window '{ssh}'`). Empty = run the command verbatim.
    var terminalCommandTemplate = "" { didSet { persist(Self.terminalCommandTemplateKey, terminalCommandTemplate) } }

    // MARK: Version history

    /// Whether the app records a version-history timeline of config edits (default on).
    var configHistoryEnabled = true { didSet { persist(Self.configHistoryEnabledKey, configHistoryEnabled) } }
    /// Hard cap on retained history versions; the oldest are pruned past this. Large
    /// by design — config snapshots are tiny and deduped.
    var maxConfigVersions = 100_000 { didSet { persist(Self.maxConfigVersionsKey, maxConfigVersions) } }

    // MARK: Key health audit
    // Each toggle silences one family of findings in the Issues view (see
    // `KeyAuditor.Category`). All default on; turning one off hides those findings
    // everywhere they surface.
    var auditWeakKeys = true { didSet { persist(Self.auditWeakKeysKey, auditWeakKeys) } }
    var auditKeyPermissions = true { didSet { persist(Self.auditKeyPermissionsKey, auditKeyPermissions) } }
    var auditMissingPassphrase = true { didSet { persist(Self.auditMissingPassphraseKey, auditMissingPassphrase) } }
    var auditOrphanedKeys = true { didSet { persist(Self.auditOrphanedKeysKey, auditOrphanedKeys) } }
    /// Weak cryptography on the *server* side — a short RSA host key, a DSA host key, a
    /// broken cipher or MAC. Sits with the key-health toggles because it lands in the same
    /// Issues list, but it judges the other end of the connection, not your own keys.
    var auditServerAlgorithms = true { didSet { persist(Self.auditServerAlgorithmsKey, auditServerAlgorithms) } }
    /// Refuse to open a tunnel whose server falls below the threshold, instead of only
    /// warning. Off by default: a weak host key is usually someone else's server that you
    /// cannot fix, and refusing would break a working setup with no recourse.
    var strictServerAlgorithms = false {
        didSet { persist(Self.strictServerAlgorithmsKey, strictServerAlgorithms) }
    }

    // MARK: Appearance

    var appearanceMode: AppearanceMode = .system { didSet { persist(Self.appearanceModeKey, appearanceMode.rawValue) } }
    var accentChoice: AccentChoice = .system { didSet { persist(Self.accentChoiceKey, accentChoice.rawValue) } }
    var uiDensity: UIDensity = .comfortable { didSet { persist(Self.uiDensityKey, uiDensity.rawValue) } }
    /// PostScript/family font name for code surfaces (raw editor, console). Empty =
    /// the system monospaced font.
    var editorFontName = "" { didSet { persist(Self.editorFontNameKey, editorFontName) } }
    var editorFontSize: Double = 12 { didSet { persist(Self.editorFontSizeKey, editorFontSize) } }

    // MARK: Code editor (raw config)

    var editorShowLineNumbers = true { didSet { persist(Self.editorShowLineNumbersKey, editorShowLineNumbers) } }
    var editorSoftWrap = false { didSet { persist(Self.editorSoftWrapKey, editorSoftWrap) } }
    var editorTabWidth = 4 { didSet { persist(Self.editorTabWidthKey, editorTabWidth) } }
    var editorSyntaxHighlighting = true {
        didSet { persist(Self.editorSyntaxHighlightingKey, editorSyntaxHighlighting) }
    }
    var editorIntelliSense = true { didSet { persist(Self.editorIntelliSenseKey, editorIntelliSense) } }
    /// Show the documentation panel beside the completion list (keyword/value help).
    var editorShowDocs = true { didSet { persist(Self.editorShowDocsKey, editorShowDocs) } }
    /// Open a host straight into the raw `ssh_config` text editor instead of the
    /// structured form. The form is reachable via the "Edit as Raw Text" toggle.
    var defaultToRawEditor = false { didSet { persist(Self.defaultToRawEditorKey, defaultToRawEditor) } }

    // MARK: General / new-host defaults

    /// When off, deleting a host happens immediately with no confirmation dialog.
    var confirmBeforeDelete = true { didSet { persist(Self.confirmBeforeDeleteKey, confirmBeforeDelete) } }
    /// Prefilled `User` for a brand-new host (empty = none).
    var defaultHostUser = "" { didSet { persist(Self.defaultHostUserKey, defaultHostUser) } }
    /// Prefilled `Port` for a brand-new host (0 = none, i.e. ssh's default 22).
    var defaultHostPort = 0 { didSet { persist(Self.defaultHostPortKey, defaultHostPort) } }

    // MARK: Keys & tunnels defaults

    /// The algorithm preselected in the Generate Key sheet.
    var defaultKeyAlgorithm: KeyAlgorithm = .ed25519 {
        didSet { persist(Self.defaultKeyAlgorithmKey, Self.algorithmID(defaultKeyAlgorithm)) }
    }
    /// Re-arm tunnels marked autostart when the app launches.
    var restoreTunnelsOnLaunch = true { didSet { persist(Self.restoreTunnelsOnLaunchKey, restoreTunnelsOnLaunch) } }
    /// Upper bound for the supervisor's exponential reconnect backoff, in seconds.
    var tunnelMaxBackoffSeconds = 60 { didSet { persist(Self.tunnelMaxBackoffSecondsKey, tunnelMaxBackoffSeconds) } }

    var gistSyncEnabled = false { didSet { persist(Self.gistSyncEnabledKey, gistSyncEnabled) } }
    var gistEncryptionEnabled = true { didSet { persist(Self.gistEncryptionEnabledKey, gistEncryptionEnabled) } }
    var gistID = "" { didSet { persist(Self.gistIDKey, gistID) } }
    var gistLastSyncedVersion = "" { didSet { persist(Self.gistLastSyncedVersionKey, gistLastSyncedVersion) } }
    var gistLastSyncedLocalHash = "" {
        didSet { persist(Self.gistLastSyncedLocalHashKey, gistLastSyncedLocalHash) }
    }
    var gistPendingPush = false { didSet { persist(Self.gistPendingPushKey, gistPendingPush) } }
    var gistLastSyncedAt: Double = 0 { didSet { persist(Self.gistLastSyncedAtKey, gistLastSyncedAt) } }

    // MARK: - Stable string ids for non-RawRepresentable enums

    /// `KeyAlgorithm` carries no raw value, so map it to a stable persisted id.
    static func algorithmID(_ algorithm: KeyAlgorithm) -> String {
        switch algorithm {
        case .ed25519: return "ed25519"
        case .ecdsaP256: return "ecdsaP256"
        case .ecdsaP384: return "ecdsaP384"
        case .ecdsaP521: return "ecdsaP521"
        }
    }

    static func algorithm(fromID id: String) -> KeyAlgorithm {
        switch id {
        case "ecdsaP256": return .ecdsaP256
        case "ecdsaP384": return .ecdsaP384
        case "ecdsaP521": return .ecdsaP521
        default: return .ed25519
        }
    }

    // MARK: - Persistence plumbing

    private let database: AppDatabase?
    private var loadTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    /// Gates writes so loading values in doesn't write them straight back.
    private var loaded = false
    /// True only while `load()` is assigning stored values into the properties, so
    /// those assignments' `didSet` writes are suppressed (they're not user edits).
    private var applyingLoad = false
    /// Settings the user changed *before* the async load finished, as serialized
    /// values keyed by setting key. `load()` must not clobber these, and they're
    /// flushed to SQLite once it's ready. (Without this, a pre-load edit was
    /// silently dropped and then overwritten by the stored/default value.)
    private var pendingPreloadWrites: [String: String] = [:]

    init(database: AppDatabase? = AppDatabase.shared) {
        self.database = database
        loadTask = Task { [weak self] in await self?.load() }
    }

    private func load() async {
        guard let database else {
            loaded = true
            return
        }
        let stored = (try? await database.loadSettings()) ?? [:]

        // Apply stored values, but never overwrite a setting the user changed
        // before load finished. `applyingLoad` suppresses these assignments'
        // write-backs; `loaded` stays false so any concurrent user edit is still
        // captured into `pendingPreloadWrites`.
        applyingLoad = true
        func keep(_ key: String) -> Bool { pendingPreloadWrites[key] == nil }
        if keep(Self.autosaveEnabledKey) { autosaveEnabled = bool(stored, Self.autosaveEnabledKey, default: true) }
        if keep(Self.showMenuBarExtraKey) { showMenuBarExtra = bool(stored, Self.showMenuBarExtraKey, default: true) }
        if keep(Self.showTunnelMenuBarKey) {
            showTunnelMenuBar = bool(stored, Self.showTunnelMenuBarKey, default: true)
        }
        if keep(Self.tunnelNotificationsEnabledKey) {
            tunnelNotificationsEnabled = bool(stored, Self.tunnelNotificationsEnabledKey, default: false)
        }
        if keep(Self.hostKeyMonitorEnabledKey) {
            hostKeyMonitorEnabled = bool(stored, Self.hostKeyMonitorEnabledKey, default: true)
        }
        if keep(Self.hostKeyNotificationsEnabledKey) {
            hostKeyNotificationsEnabled = bool(stored, Self.hostKeyNotificationsEnabledKey, default: true)
        }
        if keep(Self.hostKeyCheckIntervalMinutesKey) {
            hostKeyCheckIntervalMinutes = int(stored, Self.hostKeyCheckIntervalMinutesKey, default: 60)
        }
        if keep(Self.liveFileWatchEnabledKey) {
            liveFileWatchEnabled = bool(stored, Self.liveFileWatchEnabledKey, default: true)
        }
        if keep(Self.liveFileWatchNotificationsEnabledKey) {
            liveFileWatchNotificationsEnabled = bool(stored, Self.liveFileWatchNotificationsEnabledKey, default: true)
        }
        if keep(Self.preferredTerminalIDKey) {
            preferredTerminalID = string(stored, Self.preferredTerminalIDKey, default: "terminal")
        }
        if keep(Self.terminalCommandTemplateKey) {
            terminalCommandTemplate = string(stored, Self.terminalCommandTemplateKey, default: "")
        }
        if keep(Self.configHistoryEnabledKey) {
            configHistoryEnabled = bool(stored, Self.configHistoryEnabledKey, default: true)
        }
        if keep(Self.maxConfigVersionsKey) {
            maxConfigVersions = int(stored, Self.maxConfigVersionsKey, default: 100_000)
        }
        if keep(Self.auditWeakKeysKey) { auditWeakKeys = bool(stored, Self.auditWeakKeysKey, default: true) }
        if keep(Self.auditKeyPermissionsKey) {
            auditKeyPermissions = bool(stored, Self.auditKeyPermissionsKey, default: true)
        }
        if keep(Self.auditMissingPassphraseKey) {
            auditMissingPassphrase = bool(stored, Self.auditMissingPassphraseKey, default: true)
        }
        if keep(Self.auditOrphanedKeysKey) {
            auditOrphanedKeys = bool(stored, Self.auditOrphanedKeysKey, default: true)
        }
        if keep(Self.auditServerAlgorithmsKey) {
            auditServerAlgorithms = bool(stored, Self.auditServerAlgorithmsKey, default: true)
        }
        if keep(Self.strictServerAlgorithmsKey) {
            strictServerAlgorithms = bool(stored, Self.strictServerAlgorithmsKey, default: false)
        }
        if keep(Self.appearanceModeKey) {
            appearanceMode =
                AppearanceMode(rawValue: string(stored, Self.appearanceModeKey, default: "system")) ?? .system
        }
        if keep(Self.accentChoiceKey) {
            accentChoice = AccentChoice(rawValue: string(stored, Self.accentChoiceKey, default: "system")) ?? .system
        }
        if keep(Self.uiDensityKey) {
            uiDensity = UIDensity(rawValue: string(stored, Self.uiDensityKey, default: "comfortable")) ?? .comfortable
        }
        if keep(Self.editorFontNameKey) { editorFontName = string(stored, Self.editorFontNameKey, default: "") }
        if keep(Self.editorFontSizeKey) { editorFontSize = double(stored, Self.editorFontSizeKey, default: 12) }
        if keep(Self.editorShowLineNumbersKey) {
            editorShowLineNumbers = bool(stored, Self.editorShowLineNumbersKey, default: true)
        }
        if keep(Self.editorSoftWrapKey) { editorSoftWrap = bool(stored, Self.editorSoftWrapKey, default: false) }
        if keep(Self.editorTabWidthKey) { editorTabWidth = int(stored, Self.editorTabWidthKey, default: 4) }
        if keep(Self.editorSyntaxHighlightingKey) {
            editorSyntaxHighlighting = bool(stored, Self.editorSyntaxHighlightingKey, default: true)
        }
        if keep(Self.editorIntelliSenseKey) {
            editorIntelliSense = bool(stored, Self.editorIntelliSenseKey, default: true)
        }
        if keep(Self.editorShowDocsKey) { editorShowDocs = bool(stored, Self.editorShowDocsKey, default: true) }
        if keep(Self.defaultToRawEditorKey) {
            defaultToRawEditor = bool(stored, Self.defaultToRawEditorKey, default: false)
        }
        if keep(Self.confirmBeforeDeleteKey) {
            confirmBeforeDelete = bool(stored, Self.confirmBeforeDeleteKey, default: true)
        }
        if keep(Self.defaultHostUserKey) { defaultHostUser = string(stored, Self.defaultHostUserKey, default: "") }
        if keep(Self.defaultHostPortKey) { defaultHostPort = int(stored, Self.defaultHostPortKey, default: 0) }
        if keep(Self.defaultKeyAlgorithmKey) {
            defaultKeyAlgorithm = Self.algorithm(
                fromID: string(stored, Self.defaultKeyAlgorithmKey, default: "ed25519"))
        }
        if keep(Self.restoreTunnelsOnLaunchKey) {
            restoreTunnelsOnLaunch = bool(stored, Self.restoreTunnelsOnLaunchKey, default: true)
        }
        if keep(Self.tunnelMaxBackoffSecondsKey) {
            tunnelMaxBackoffSeconds = int(stored, Self.tunnelMaxBackoffSecondsKey, default: 60)
        }
        if keep(Self.gistSyncEnabledKey) { gistSyncEnabled = bool(stored, Self.gistSyncEnabledKey, default: false) }
        if keep(Self.gistEncryptionEnabledKey) {
            gistEncryptionEnabled = bool(stored, Self.gistEncryptionEnabledKey, default: true)
        }
        if keep(Self.gistIDKey) { gistID = string(stored, Self.gistIDKey, default: "") }
        if keep(Self.gistLastSyncedVersionKey) {
            gistLastSyncedVersion = string(stored, Self.gistLastSyncedVersionKey, default: "")
        }
        if keep(Self.gistLastSyncedLocalHashKey) {
            gistLastSyncedLocalHash = string(stored, Self.gistLastSyncedLocalHashKey, default: "")
        }
        if keep(Self.gistPendingPushKey) { gistPendingPush = bool(stored, Self.gistPendingPushKey, default: false) }
        if keep(Self.gistLastSyncedAtKey) { gistLastSyncedAt = double(stored, Self.gistLastSyncedAtKey, default: 0) }
        applyingLoad = false
        loaded = true

        // Flush pre-load user edits now that writes are enabled and the DB is ready.
        let pending = pendingPreloadWrites
        pendingPreloadWrites = [:]
        for (key, serialized) in pending { persistSerialized(key, serialized) }

        // Persist any key missing from SQLite so the database becomes authoritative
        // (one-time migration off UserDefaults / first-write of new defaults).
        for (key, serialized) in currentSerializedValues() where stored[key] == nil {
            persistSerialized(key, serialized)
        }
    }

    /// Every setting's key paired with its current serialized value — the source for
    /// the "write defaults that aren't in the DB yet" pass, so a new key only has to
    /// be declared once (above) and listed here.
    private func currentSerializedValues() -> [(String, String)] {
        [
            (Self.autosaveEnabledKey, serialize(autosaveEnabled)),
            (Self.showMenuBarExtraKey, serialize(showMenuBarExtra)),
            (Self.showTunnelMenuBarKey, serialize(showTunnelMenuBar)),
            (Self.tunnelNotificationsEnabledKey, serialize(tunnelNotificationsEnabled)),
            (Self.hostKeyMonitorEnabledKey, serialize(hostKeyMonitorEnabled)),
            (Self.hostKeyNotificationsEnabledKey, serialize(hostKeyNotificationsEnabled)),
            (Self.hostKeyCheckIntervalMinutesKey, String(hostKeyCheckIntervalMinutes)),
            (Self.liveFileWatchEnabledKey, serialize(liveFileWatchEnabled)),
            (Self.liveFileWatchNotificationsEnabledKey, serialize(liveFileWatchNotificationsEnabled)),
            (Self.preferredTerminalIDKey, preferredTerminalID),
            (Self.terminalCommandTemplateKey, terminalCommandTemplate),
            (Self.configHistoryEnabledKey, serialize(configHistoryEnabled)),
            (Self.maxConfigVersionsKey, String(maxConfigVersions)),
            (Self.auditWeakKeysKey, serialize(auditWeakKeys)),
            (Self.auditKeyPermissionsKey, serialize(auditKeyPermissions)),
            (Self.auditMissingPassphraseKey, serialize(auditMissingPassphrase)),
            (Self.auditOrphanedKeysKey, serialize(auditOrphanedKeys)),
            (Self.auditServerAlgorithmsKey, serialize(auditServerAlgorithms)),
            (Self.strictServerAlgorithmsKey, serialize(strictServerAlgorithms)),
            (Self.appearanceModeKey, appearanceMode.rawValue),
            (Self.accentChoiceKey, accentChoice.rawValue),
            (Self.uiDensityKey, uiDensity.rawValue),
            (Self.editorFontNameKey, editorFontName),
            (Self.editorFontSizeKey, String(editorFontSize)),
            (Self.editorShowLineNumbersKey, serialize(editorShowLineNumbers)),
            (Self.editorSoftWrapKey, serialize(editorSoftWrap)),
            (Self.editorTabWidthKey, String(editorTabWidth)),
            (Self.editorSyntaxHighlightingKey, serialize(editorSyntaxHighlighting)),
            (Self.editorIntelliSenseKey, serialize(editorIntelliSense)),
            (Self.editorShowDocsKey, serialize(editorShowDocs)),
            (Self.defaultToRawEditorKey, serialize(defaultToRawEditor)),
            (Self.confirmBeforeDeleteKey, serialize(confirmBeforeDelete)),
            (Self.defaultHostUserKey, defaultHostUser),
            (Self.defaultHostPortKey, String(defaultHostPort)),
            (Self.defaultKeyAlgorithmKey, Self.algorithmID(defaultKeyAlgorithm)),
            (Self.restoreTunnelsOnLaunchKey, serialize(restoreTunnelsOnLaunch)),
            (Self.tunnelMaxBackoffSecondsKey, String(tunnelMaxBackoffSeconds)),
            (Self.gistSyncEnabledKey, serialize(gistSyncEnabled)),
            (Self.gistEncryptionEnabledKey, serialize(gistEncryptionEnabled)),
            (Self.gistIDKey, gistID),
            (Self.gistLastSyncedVersionKey, gistLastSyncedVersion),
            (Self.gistLastSyncedLocalHashKey, gistLastSyncedLocalHash),
            (Self.gistPendingPushKey, serialize(gistPendingPush)),
            (Self.gistLastSyncedAtKey, String(gistLastSyncedAt)),
        ]
    }

    /// SQLite value if present, else a legacy UserDefaults value, else the default.
    private func bool(_ stored: [String: String], _ key: String, default fallback: Bool) -> Bool {
        if let value = stored[key] { return value == "1" }
        if let legacy = UserDefaults.standard.object(forKey: key) as? Bool { return legacy }
        return fallback
    }

    /// SQLite value if present, else a legacy UserDefaults value, else the default.
    private func string(_ stored: [String: String], _ key: String, default fallback: String) -> String {
        if let value = stored[key] { return value }
        if let legacy = UserDefaults.standard.object(forKey: key) as? String { return legacy }
        return fallback
    }

    /// SQLite value if present, else a legacy UserDefaults value, else the default.
    private func int(_ stored: [String: String], _ key: String, default fallback: Int) -> Int {
        if let value = stored[key], let parsed = Int(value) { return parsed }
        if let legacy = UserDefaults.standard.object(forKey: key) as? Int { return legacy }
        return fallback
    }

    /// SQLite value if present, else a legacy UserDefaults value, else the default.
    private func double(_ stored: [String: String], _ key: String, default fallback: Double) -> Double {
        if let value = stored[key], let parsed = Double(value) { return parsed }
        if let legacy = UserDefaults.standard.object(forKey: key) as? Double { return legacy }
        return fallback
    }

    private func serialize(_ value: Bool) -> String { value ? "1" : "0" }

    private func persist(_ key: String, _ value: Bool) { persistSerialized(key, serialize(value)) }
    private func persist(_ key: String, _ value: String) { persistSerialized(key, value) }
    private func persist(_ key: String, _ value: Int) { persistSerialized(key, String(value)) }
    private func persist(_ key: String, _ value: Double) { persistSerialized(key, String(value)) }

    private func persistSerialized(_ key: String, _ serialized: String) {
        if applyingLoad { return } // these are values being loaded in, not user edits
        // Half of "why is the app behaving like that?" is a setting the user forgot
        // they flipped — record every change, with its new value.
        Log.settings.notice("\(key, privacy: .public) = \(serialized, privacy: .public)")
        guard loaded else {
            // Edited before async load finished — remember it; `load()` won't clobber
            // it and will flush it once the database is ready.
            pendingPreloadWrites[key] = serialized
            return
        }
        guard let database else { return }
        let previous = persistTask
        persistTask = Task {
            await previous?.value // keep writes ordered
            try? await database.setSetting(key, serialized)
        }
    }

    /// Test/launch support.
    func waitUntilLoaded() async { await loadTask?.value }
    func waitForPendingWrites() async { await persistTask?.value }
}
