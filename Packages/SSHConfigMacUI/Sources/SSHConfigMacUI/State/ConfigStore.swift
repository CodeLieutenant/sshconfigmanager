//
//  ConfigStore.swift
//  sshconfigmanager
//
//  The app's central state: owns the parsed documents, file access, and editing.
//

import AppKit
import Foundation
import Observation
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigEngine
import SSHConfigServices
import Security
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
@Observable
final class ConfigStore {
    /// Shared instance used across the main window, the menu-bar extra, settings,
    /// and the app delegate (quit handling).
    static let shared = ConfigStore()

    // MARK: - Observable state

    /// All loaded files (the main config first, then included files).
    var documents: [SSHConfigDocument] = []
    /// Include-directive id → the *paths* it expanded to, in load order. Paths, not
    /// parsed documents: `documents` is edited in place at ~15 sites without a full
    /// reload, so any `SSHConfigDocument` value stored here freezes at reload time.
    /// `EffectiveConfigResolver` reaches every included file through this map, so
    /// frozen values meant an edit to an `Include`d file stayed invisible until the
    /// next reload — the tunnel engine kept connecting with the pre-edit User/HostName.
    var _inclusionPaths: [UUID: [URL]] = [:]

    /// Live view of the config graph: always reflects the current in-memory
    /// `documents` (including mid-session edits) plus the include topology
    /// captured on the last `reload()`.
    var configGraph: ConfigGraph {
        var liveByPath: [String: SSHConfigDocument] = [:]
        for document in documents { liveByPath[document.sourceURL.standardizedFileURL.path] = document }
        let inclusions = _inclusionPaths.mapValues { paths in
            paths.compactMap { liveByPath[$0.standardizedFileURL.path] }
        }
        return ConfigGraph(documents: documents, inclusions: inclusions)
    }

    /// A config or `Include`d file that couldn't be read on the last `reload()` —
    /// most commonly a symlink (e.g. from a dotfiles repo) pointing outside every
    /// granted directory. Surfaced in `allFindings` with a "Grant Access" fix when
    /// the sandbox names an out-of-scope target it could ask for access to.
    struct ConfigReadIssue: Identifiable {
        let id = UUID()
        let url: URL
        let error: Error
        var symlinkTarget: URL? {
            guard case .symlinkOutsideGrantedDirectory(_, let target) = error as? SSHFileAccessError else { return nil }
            return target
        }
    }
    var configReadIssues: [ConfigReadIssue] = []

    /// Symlink-escape issues awaiting an access-grant decision, most recent
    /// `reload()` first and deduplicated by target directory (a whole dotfiles
    /// subtree behind one ungranted symlink shouldn't prompt once per file).
    /// Driven by a modal in `ContentView` — surfacing this only in the Issues tab
    /// left users with no indication *why* their config was empty.
    var symlinkAccessQueue: [ConfigReadIssue] = []
    /// The prompt currently shown as a modal, if any.
    var pendingSymlinkAccessRequest: ConfigReadIssue? { symlinkAccessQueue.first }
    /// Targets the user dismissed with "Not Now" this session — not re-prompted
    /// automatically on later reloads, but still offered from Issues > Grant Access.
    var dismissedSymlinkTargetPaths: Set<String> = []

    /// A hop's dependency on a path outside every granted directory that the sandbox
    /// couldn't reach on the last connect attempt — a custom `IdentityAgent` socket
    /// (almost always a third-party agent like 1Password) or a `UserKnownHostsFile`/
    /// `RevokedHostKeys` file. Reported live by the tunnel engine; fixed the same way
    /// a symlink escape is — grant the containing folder via `SSHFileAccess`. One
    /// shared queue for both cases (rather than a copy-pasted queue per case) since
    /// they're identical in shape: a path, a reason to show the user, and the same
    /// grant/dismiss mechanics.
    enum ExternalAccessReason: Equatable {
        case agentSocket(hopDescription: String)
        case userKnownHostsFile(hopDescription: String)
        case revokedHostKeys(hopDescription: String)

        var hopDescription: String {
            switch self {
            case .agentSocket(let d), .userKnownHostsFile(let d), .revokedHostKeys(let d): return d
            }
        }
    }
    struct ExternalAccessIssue: Identifiable, Equatable {
        let id = UUID()
        let path: URL
        let reason: ExternalAccessReason
    }
    var externalAccessQueue: [ExternalAccessIssue] = []
    /// The prompt currently shown as a modal, if any.
    var pendingExternalAccessRequest: ExternalAccessIssue? { externalAccessQueue.first }
    /// Paths dismissed with "Not Now" this session — not re-prompted automatically,
    /// but the next connect attempt that hits the same unreachable path queues it again.
    var dismissedExternalAccessPaths: Set<String> = []

    var hasAccess = false
    var grantedDirectoryName: String?

    /// Absolute path of the granted `~/.ssh` directory, when access exists. Feeds the
    /// raw-editor file-path completion (`PathCompletionBrowser`); reads stay confined
    /// to this root.
    var sshDirectoryPath: String? { fileAccess.directoryURL?.path }

    var selectedBlockID: HostBlock.ID?
    var searchText = ""
    /// Drives the ⌘K quick-open sheet.
    var showCommandPalette = false

    var publicKeys: [SSHPublicKey] = []
    var knownHosts: [KnownHostEntry] = [] {
        didSet { serverKeyFindingsCache = nil }
    }

    /// Memoises `serverKeyFindings`, which base64-decodes every stored host key and parses
    /// each RSA modulus. `allFindings` backs the sidebar badge, so an uncached read landed
    /// that work on every SwiftUI render pass. Invalidated by `knownHosts` changing or by
    /// the audit toggle flipping — the only two inputs.
    @ObservationIgnored var serverKeyFindingsCache: (enabled: Bool, findings: [LintFinding])?

    /// Which file inside the granted `~/.ssh` directory the Known Hosts screen reads
    /// and edits. Defaults to `known_hosts`; the user can switch it to `known_hosts2`,
    /// a custom `UserKnownHostsFile`, etc. via the file picker.
    var knownHostsFileName = "known_hosts"

    /// Set by the menu bar / a tapped notification to jump the main window to the Known
    /// Hosts screen and select a specific host group (the `KnownHostGroup.id`). ContentView
    /// observes it to navigate; KnownHostsView consumes it to select, then clears it.
    var pendingKnownHostsSelection: String?

    var externalKnownHostsChange: KnownHostsChangeSummary?

    /// Set by a tapped live-file-watch notification to jump the main window to the Known
    /// Hosts screen so a fresh `externalKnownHostsChange` banner is visible immediately.
    /// ContentView observes it to navigate, then resets it.
    var pendingKnownHostsFocus = false

    /// Set by a tapped live-file-watch notification for a config change, to jump the main
    /// window to the Version History screen so the freshly-recorded external version is
    /// visible immediately. ContentView observes it to navigate, then resets it.
    var pendingHistoryFocus = false

    /// The audit-ready snapshot of the keys on disk (modes + private-key headers),
    /// gathered on `reload()` and after a permission fix. `keyFindings` runs the pure
    /// `KeyAuditor` over this, so toggling an audit category in Settings re-filters
    /// the findings live without re-reading the filesystem.
    var keyAuditInputs: [KeyAuditor.KeyInput] = []
    var sshDirectorySnapshot: (path: String, mode: Int)?

    /// A request to open the "Generate key" sheet pre-filled, set when the user taps
    /// **Generate Replacement** on a weak-key finding. The Keys screen consumes and
    /// clears it. Carries the old key's comment so the new key keeps it.
    struct KeyGenerationRequest: Equatable { var comment: String }
    var pendingKeyGeneration: KeyGenerationRequest?

    /// Identities currently loaded in the running ssh-agent, refreshed on demand
    /// from `SSHAgentService`. Correlated against `publicKeys` in the Agent view.
    var agentIdentities: [AgentIdentity] = []

    /// The agent's reachability, kept distinct so the Agent view can tell apart
    /// "no agent running", "agent reachable but empty", and "the lookup failed".
    enum AgentStatus: Equatable {
        case unknown // not yet refreshed
        case unavailable // SSH_AUTH_SOCK unset — no agent at all
        case available // reachable; agentIdentities is authoritative
        case failed(String) // socket present but the lookup errored
    }
    var agentStatus: AgentStatus = .unknown

    var errorMessage: String?

    var onConfigSaved: (() -> Void)?

    /// Non-error, transient status from a Connect launch (e.g. "command copied to
    /// the clipboard" when automation isn't available). Surfaced as an info alert.
    var launchStatus: String?

    /// Opens terminals for `connect`. A stored, non-observed seam so tests can
    /// inject a fake launcher instead of driving real AppleScript.
    @ObservationIgnored
    var terminalLauncher: TerminalLaunching = TerminalLauncher()

    /// When the document was last written to disk (drives the "saved" status).
    private(set) var lastSavedDate: Date?

    /// High-level save state for the status indicator.
    enum SaveStatus { case upToDate, saving, unsaved }
    var saveStatus: SaveStatus {
        guard isDirty else { return .upToDate }
        return autosaveEnabled ? .saving : .unsaved
    }

    /// Whether edits are written to disk automatically (Settings toggle, default on).
    var autosaveEnabled: Bool {
        settings.autosaveEnabled
    }

    /// The window's undo manager, injected by the root view so ⌘Z / ⌘⇧Z work
    /// through the standard Edit menu.
    var undoManager: UndoManager?

    var favoriteAliases: Set<String> = []
    var tagsByAlias: [String: [String]] = [:]
    /// When set, the sidebar shows only hosts carrying this tag.
    var tagFilter: String?

    /// How the sidebar organises the host list. Persisted in UserDefaults.
    var groupingMode: GroupingMode = .byTag {
        didSet { UserDefaults.standard.set(groupingMode.rawValue, forKey: "groupingMode") }
    }
    /// Names of host groups the user has collapsed in the sidebar tree. Persisted in UserDefaults.
    var collapsedGroupNames: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(collapsedGroupNames), forKey: "collapsedGroupNames") }
    }
    /// Every sidebar group the user can see — some backed by a real `Include`d
    /// file (`fileRelPath != nil`), the rest "virtual" (tag-based membership only,
    /// as `persistedGroupNames` worked before this type existed). SQLite-backed
    /// (see `AppDatabase.host_groups`); loaded async at launch by `groupsLoadTask`,
    /// so early reads may see an empty array until that resolves (mirrors
    /// `TunnelStore.presets`/`ConfigHistoryStore.versions`).
    var groups: [PersistedGroup] = []

    /// The source of truth for the autosave toggle. Injectable so tests can drive
    /// it with a private instance instead of mutating the shared singleton (which
    /// would race across parallel suites). Production passes `.shared`.
    let settings: AppSettings

    /// Where passphrases are persisted for "keep loaded after restart". Injectable
    /// so the remember/forget/reload logic is testable without a signed keychain.
    let passphraseStore: PassphraseStoring

    /// Key file names (e.g. `id_ed25519`) whose passphrase is remembered for
    /// reload-at-login. Mirrors `passphraseStore`; drives the UI toggle state.
    var rememberedKeyNames: Set<String> = []

    /// The config version-history timeline (SQLite-backed). Production wires the
    /// shared database; tests get a disabled (nil-database) store unless they inject
    /// one, so unit tests never write history to the real app database.
    let history: ConfigHistoryStore

    /// SQLite-backed `groups` persistence (`host_groups` table). `nil` disables
    /// persistence (unit tests), mirroring `TunnelStore`/`ConfigHistoryStore`.
    let database: AppDatabase?
    /// The initial async `groups` load; awaited by `startGroupsOnLaunch()` so
    /// auto-discovery runs against the real persisted set, not an empty one.
    var groupsLoadTask: Task<Void, Never>?
    /// True once `loadGroupsFromDatabase()` has assigned (or given up on) `groups`.
    /// Gates whether a plain `reload()` may run auto-discovery inline — before this
    /// flips, a mid-flight discovery would race the DB load and get clobbered (or
    /// clobber it), per `TunnelStore.didInitialLoad`/`mutatedBeforeLoad`.
    var groupsInitialLoadCompleted = false
    /// True once any code has mutated `groups` before the initial load resolved —
    /// guards against the async load overwriting those changes.
    var groupsMutatedBeforeLoad = false
    var hostMetadataMutatedBeforeLoad = false

    // Convenience inits avoid `@MainActor` default-argument expressions (`.shared`,
    // `KeychainPassphraseStore()`), which trip "main actor-isolated value in a
    // nonisolated context"; the bodies run on the main actor, so they're fine here.
    convenience init() {
        self.init(
            settings: .shared, passphraseStore: KeychainPassphraseStore(),
            history: ConfigHistoryStore(), database: AppDatabase.shared)
    }

    convenience init(settings: AppSettings) {
        self.init(settings: settings, passphraseStore: KeychainPassphraseStore())
    }

    init(
        settings: AppSettings, passphraseStore: PassphraseStoring,
        history: ConfigHistoryStore? = nil, database: AppDatabase? = nil
    ) {
        self.settings = settings
        self.passphraseStore = passphraseStore
        self.history = history ?? ConfigHistoryStore(database: nil)
        self.database = database
        if let raw = UserDefaults.standard.string(forKey: "groupingMode"),
            let mode = GroupingMode(rawValue: raw)
        {
            groupingMode = mode
        }
        if let names = UserDefaults.standard.array(forKey: "collapsedGroupNames") as? [String] {
            collapsedGroupNames = Set(names)
        }
        rememberedKeyNames = Set(passphraseStore.allKeyPaths())
        groupsLoadTask = Task { [weak self] in await self?.loadGroupsFromDatabase() }
    }

    // MARK: - Private

    let fileAccess = SSHFileAccess()
    /// Test seam (audit #24): swap in a fake to assert `reindex`/`deleteAll`
    /// calls — and their timing relative to a write — without touching the real
    /// CoreSpotlight index.
    var spotlightIndexer: SpotlightIndexing = SpotlightIndexer.shared
    var dirtyURLs: Set<URL> = []
    /// URLs of documents that were in `documents` at some `mutate` baseline but
    /// aren't anymore (e.g. deleting a file-backed group) — physically deleted by
    /// the next `writeDirtyDocuments()`. See `markChanged(from:)`.
    var pendingDeleteURLs: Set<URL> = []
    var modificationDates: [URL: Date] = [:]
    private var autosaveTask: Task<Void, Never>?
    /// Set once the one-time history bootstrap (migration + baseline) has been
    /// kicked off, after which `reload()` records external changes as versions.
    var historyLaunchStarted = false
    /// The async migration + baseline work kicked off by `startHistoryOnLaunch`.
    var historyLaunchTask: Task<Void, Never>?

    let fileWatcher = ConfigFileWatcher()
    /// Which URLs `fileWatcher` currently holds a *document* watch on, so
    /// `updateFileWatchers()` can diff against the live `documents` set — the
    /// coordinator itself just tracks URLs, it has no notion of "document" vs
    /// "known_hosts".
    var watchedDocumentURLs: Set<URL> = []
    /// The path `fileWatcher` currently holds the known-hosts watch on, so
    /// `updateFileWatchers()` can tell the user switched known-hosts files (via
    /// `selectKnownHostsFile`) and needs to re-point the watch rather than leave it
    /// watching the old file.
    var watchedKnownHostsURL: URL?
    /// Whether we've already asked for notification permission this session (mirrors
    /// `HostKeyMonitor`'s same-named flag) — don't re-prompt on every change.
    var didRequestFileWatchNotificationAuth = false
    /// Coalesces `handleConfigFileChanged()` firing from multiple per-document watchers
    /// in quick succession (e.g. a script touching several `Include`d files) into one
    /// `checkForExternalChanges()` pass instead of one per file.
    var configChangeCoalesceTask: Task<Void, Never>?

    /// Debounce window between an edit and the automatic write to disk.
    private let autosaveDelay: Duration = .milliseconds(700)

    var isDirty: Bool { !dirtyURLs.isEmpty || !pendingDeleteURLs.isEmpty }

    // MARK: - Access lifecycle

    /// Attempts to restore access from a stored bookmark and load the config.
    func restoreOnLaunch() {
        #if DEBUG
            // UI-test seam. Two flavors, both bypass the open-panel grant:
            //  • `--uitest-seed-keys`: the *app* seeds a fixture ~/.ssh inside its own
            //    sandbox-temp and uses it. Works in a SIGNED, sandboxed build — which is
            //    what XCUITest needs (an unsigned runner gets killed before it connects).
            //  • `--uitest-ssh-dir <path>`: use a caller-provided directory (only readable
            //    in an unsigned build where the sandbox isn't enforced).
            // Screenshot/preview harness: seed a polished fixture (rich config + healthy
            // keys + known_hosts), then deterministically tag + group the hosts so the
            // captures are reproducible regardless of any persisted sidebar state.
            if ScreenshotMode.isActive, let directory = ScreenshotMode.createSeededDirectory() {
                useDirectoryForTesting(directory)
                // Clear sidebar state left by earlier screenshot runs (these live in
                // UserDefaults, not the fixture dir) so groups/favorites are reproducible.
                for key in ["collapsedGroupNames", "groupingMode"] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                tagsByAlias = [:]
                favoriteAliases = []
                groups = []
                collapsedGroupNames = []
                reload()
                // Plain tags (shown in the host detail) + named groups (shown in the
                // sidebar tree) + a favorite, so the grouped sidebar reads well.
                let plainTags = [
                    "production-web": ["production"], "db-bastion": ["production"],
                    "staging-api": ["staging"], "raspberry-pi": ["home"],
                    "github.com": ["personal"],
                ]
                let namedGroup = [
                    "production-web": "Production", "db-bastion": "Production",
                    "staging-api": "Staging", "raspberry-pi": "Home",
                    "github.com": "Personal",
                ]
                for block in allHostBlocks {
                    let a = alias(of: block)
                    if let t = plainTags[a] { setTags(t, for: block) }
                    if let g = namedGroup[a] {
                        let target =
                            group(named: g)
                            ?? {
                                let id = createGroup()
                                renameGroup(id, to: g)
                                return group(id: id)!
                            }()
                        assignToGroup(blockID: block.id, group: target)
                    }
                    if a == "production-web" { toggleFavorite(block) }
                }
                groupingMode = .byTag
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--uitest-seed-keys"),
                let directory = Self.createSeededUITestDirectory()
            {
                useDirectoryForTesting(directory)
                reload()
                return
            }
            if let directory = Self.uiTestDirectory() {
                useDirectoryForTesting(directory)
                reload()
                return
            }
        #endif
        if fileAccess.restoreAccess() {
            Log.config.notice("restored ~/.ssh access on launch")
            hasAccess = true
            grantedDirectoryName = fileAccess.directoryURL?.lastPathComponent
            reload(trigger: "launch")
            startHistoryOnLaunch()
            startGroupsOnLaunch()
            // Re-inject "keep loaded after restart" keys into the agent. This is
            // what makes them persist across reboots: macOS relaunches us at login
            // (LoginItemManager) and we reload here.
            Task { await reloadPersistedAgentKeys() }
        }
    }

    /// Prompts the user to grant access, then loads the config.
    func requestAccess() {
        do {
            try fileAccess.requestAccess()
            Log.config.notice("user granted ~/.ssh access")
            hasAccess = true
            grantedDirectoryName = fileAccess.directoryURL?.lastPathComponent
            reload()
            startHistoryOnLaunch()
            startGroupsOnLaunch()
        } catch SSHFileAccessError.accessDenied {
            // User cancelled — leave the onboarding screen up, no error banner.
            Log.config.notice("~/.ssh access request cancelled by user")
        } catch {
            Log.config.error("~/.ssh access request failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func changeFolder() {
        spotlightIndexer.deleteAll()
        fileAccess.revokeAccess()
        hasAccess = false
        documents = []
        _inclusionPaths = [:]
        configReadIssues = []
        symlinkAccessQueue = []
        dismissedSymlinkTargetPaths = []
        externalAccessQueue = []
        dismissedExternalAccessPaths = []
        publicKeys = []
        knownHosts = []
        externalKnownHostsChange = nil
        keyAuditInputs = []
        sshDirectorySnapshot = nil
        dirtyURLs.removeAll()
        historyLaunchStarted = false // allow startHistoryOnLaunch() to run for the new folder
        historyLaunchTask?.cancel()
        historyLaunchTask = nil
        stopFileWatchers()
        requestAccess()
    }

    // MARK: - Loading

    /// Re-reads the config (and its includes), keys, and known_hosts from disk.
    /// Discards any pending edits and clears the undo history (they no longer apply).
    /// `trigger` is purely for observability — a short label (e.g. "launch",
    /// "external-file-change", "focus-regain") noting *why* this reload ran, so
    /// `log stream --predicate '... && category == "config"'` can distinguish "the
    /// user clicked Refresh" from "the file watcher saw an outside edit" without
    /// changing what a reload actually does.
    func reload(trigger: String = "manual") {
        autosaveTask?.cancel()
        autosaveTask = nil
        // A reload replaces the in-memory tree with disk's, so every snapshot (and any
        // open field-edit group) now references a tree that no longer matches disk —
        // undoing into it would clobber an external change. Discard the whole history.
        coalescingFieldEdit = nil
        lastDiscreteUndo = nil
        undoManager?.removeAllActions()
        guard let configURL = fileAccess.configURL else { return }

        // Create the config file if it does not yet exist (first-run or deleted).
        if !FileManager.default.fileExists(atPath: configURL.path) {
            do {
                try fileAccess.writeText("", to: configURL, makeBackup: false)
                Log.config.notice("created empty config file at \(configURL.path, privacy: .public)")
            } catch {
                Log.config.error("failed to create config file: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Auto-wire config.d/ via an Include directive when the directory exists but
        // is not yet referenced — mirrors how OpenSSH itself handles the pattern and
        // keeps the include graph correct without any special-case loading logic.
        var readIssues: [ConfigReadIssue] = []
        if let issue = ensureConfigDInclude(configURL: configURL) { readIssues.append(issue) }

        var loaded: [SSHConfigDocument] = []
        var byPath: [String: SSHConfigDocument] = [:]
        // Each `Include` directive's id → the paths it expanded to, in order.
        // Threaded into `ConfigGraph` so the resolver can splice includes inline.
        var inclusions: [UUID: [URL]] = [:]

        // Loads `url` once (dedup by path), recording the include graph. Returns the
        // parsed document so an `Include` directive can map to the files it expands to
        // even when a file is reached again through a second include. A read failure
        // (e.g. a symlink into a dotfiles repo the sandbox can't follow) is recorded
        // rather than swallowed, so it surfaces as an actionable finding instead of
        // silently producing an empty document.
        @discardableResult
        func loadFile(_ url: URL) -> SSHConfigDocument {
            let standardized = url.standardizedFileURL
            if let existing = byPath[standardized.path] { return existing }
            let text: String
            do {
                text = try fileAccess.readText(at: standardized)
            } catch {
                text = ""
                readIssues.append(ConfigReadIssue(url: standardized, error: error))
                Log.config.error(
                    "failed to read \(standardized.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            let document = SSHConfigParser.parse(text, sourceURL: standardized)
            byPath[standardized.path] = document
            loaded.append(document)
            for include in document.includeDirectives {
                inclusions[include.id] = fileAccess.resolveIncludes(include.value) { source, target in
                    readIssues.append(
                        ConfigReadIssue(
                            url: source,
                            error: SSHFileAccessError.symlinkOutsideGrantedDirectory(source: source, target: target)))
                }.map { url in
                    loadFile(url)
                    return url.standardizedFileURL
                }
            }
            return document
        }

        loadFile(configURL)
        documents = loaded
        _inclusionPaths = inclusions
        configReadIssues = readIssues
        var seenSymlinkTargets: Set<String> = []
        symlinkAccessQueue = readIssues.filter { issue in
            guard let target = issue.symlinkTarget?.standardizedFileURL.path,
                !dismissedSymlinkTargetPaths.contains(target)
            else { return false }
            return seenSymlinkTargets.insert(target).inserted
        }
        dirtyURLs.removeAll()
        pendingDeleteURLs.removeAll()
        captureModificationDates()
        loadKeys()
        // reload() runs for reasons unrelated to known_hosts (an external config edit,
        // focus regain, initial launch) — don't let it silently drop a still-unseen
        // externalKnownHostsChange banner.
        loadKnownHosts(clearingExternalChange: false)
        loadKeyFindings()
        Log.config.notice(
            "reloaded config (\(trigger, privacy: .public)): \(loaded.count) file(s), \(self.publicKeys.count) key(s), \(self.knownHosts.count) known-host line(s)"
        )
        spotlightIndexer.reindex(allHostBlocks)
        // Auto-discover groups for any Include'd file or "group/<name>" tag with no
        // matching PersistedGroup — but only once the real persisted set has loaded
        // (`startGroupsOnLaunch()` runs this same pass right after that resolves on
        // the very first reload(); a plain re-reload afterwards is safe to run inline).
        if groupsInitialLoadCompleted {
            performGroupAutoDiscovery()
            pruneOrphanedFileBackedGroups()
            persistGroups()
        }
        // Keep tunnel presets honest against whatever just loaded — a rename or
        // deletion made outside the app (in vim, by a script, or picked up by the
        // file watcher) leaves a preset's `hostAlias` stale otherwise, since nothing
        // else re-checks it outside the in-app editors' commit points.
        TunnelStore.shared.reconcileOrphanedPresets(
            validHostAliases: Set(allHostBlocks.flatMap(\.patterns)))
        // An external edit reaches a *running* tunnel only here — the in-app editors
        // restart at their own commit points, but vim (or a dotfiles pull) has no
        // such boundary, and an established SSH link keeps whatever user/host it
        // dialled with until something reconnects it.
        TunnelStore.shared.restartTunnelsWithChangedConfig()
        // After launch, any reload reflects a change made on disk outside the app
        // (or a restore, which the no-op guard collapses). The initial baseline is
        // recorded by startHistoryOnLaunch(), so skip until that has run.
        if historyLaunchStarted { recordHistory(.external) }
        // The document set (and therefore which files need real-time watching) may
        // have changed — an Include could have appeared/disappeared.
        updateFileWatchers()
    }

    // MARK: - Saving (automatic)

    /// Schedules a debounced write to disk. Called after every edit. No-op when
    /// autosave is disabled — edits stay dirty until the user saves with ⌘S.
    func scheduleAutosave() {
        guard isDirty, autosaveEnabled else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.autosaveDelay)
            if Task.isCancelled { return }
            self.writeDirtyDocuments()
        }
    }

    /// Writes any pending edits immediately (on quit, resign-active, before reload).
    func flushPendingSave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        writeDirtyDocuments()
    }

    private func writeDirtyDocuments() {
        guard isDirty else { return }
        // Each file is written independently — one bad file (classically, a symlinked
        // `Include` whose target was never granted) used to abort this whole method on
        // the first throw, via one `do` wrapping every write. That left *every other*
        // pending edit permanently stuck un-saved too (dirtyURLs/pendingDeleteURLs were
        // only ever cleared after the loop, never reached), not just the one file that
        // actually failed — every subsequent autosave would fail again the same way,
        // forever, for documents that had nothing wrong with them.
        var writeCount = 0
        var writtenURLs: Set<URL> = []
        var failures: [(url: URL, error: Error)] = []
        for document in documents where dirtyURLs.contains(document.sourceURL) {
            let text = SSHConfigSerializer.serialize(document)
            do {
                // The version history (below) is the backup now, so the legacy
                // hidden .bak copies are no longer made for config writes.
                try fileAccess.writeText(text, to: document.sourceURL, makeBackup: false)
                dirtyURLs.remove(document.sourceURL)
                writtenURLs.insert(document.sourceURL)
                writeCount += 1
            } catch {
                failures.append((document.sourceURL, error))
            }
        }
        // A document removed from `documents` (e.g. deleting a file-backed group) is
        // invisible to the loop above; `markChanged` records its URL here instead. Skip
        // it if the URL is back in `documents` by write time (a delete undone before
        // this autosave fired) — `markChanged` already cancels the pending delete in
        // that case, but the guard is cheap insurance.
        let stillPresent = Set(documents.map(\.sourceURL))
        var deleteCount = 0
        var deletedURLs: Set<URL> = []
        for url in Array(pendingDeleteURLs) where !stillPresent.contains(url) {
            do {
                try fileAccess.deleteFile(at: url, makeBackup: false)
                pendingDeleteURLs.remove(url)
                deletedURLs.insert(url)
                deleteCount += 1
            } catch {
                failures.append((url, error))
            }
        }
        // Re-baseline ONLY the files we actually wrote/deleted. Re-capturing EVERY
        // document (the old `captureModificationDates()`) folded a concurrent external
        // edit to an untouched Include into the baseline, so the next
        // checkForExternalChanges() never saw it and a later in-app edit overwrote the
        // external change — silent data loss (audit #4).
        for url in writtenURLs { modificationDates[url] = modificationDate(of: url) }
        for url in deletedURLs { modificationDates.removeValue(forKey: url) }
        // Only claim a save when something actually reached disk. If every write threw
        // (e.g. an ungranted symlinked Include), don't advance lastSavedDate or snapshot
        // an in-memory state to history that never persisted (audit #7).
        if writeCount + deleteCount > 0 {
            lastSavedDate = Date()
            // Coalesced: writeDirtyDocuments runs once per settled autosave burst, so
            // this records one version per burst (the no-op guard drops empties).
            recordHistory(.autosave)
            // Keep Spotlight current with in-app add/rename/delete (audit #24) —
            // previously the index only refreshed on `reload()` (an external change
            // or relaunch), so a renamed/deleted host's stale entry lingered in
            // search results until then, and a freshly added host wasn't searchable
            // all session. Coalesced by the same autosave debounce as the write
            // itself, so this doesn't run per keystroke.
            spotlightIndexer.reindex(allHostBlocks)
            onConfigSaved?()
        }
        Log.config.notice("saved \(writeCount) config file(s), deleted \(deleteCount)")
        for url in writtenURLs { Log.config.info("wrote \(url.path, privacy: .public)") }
        for url in deletedURLs { Log.config.notice("deleted \(url.path, privacy: .public)") }
        if let first = failures.first {
            for failure in failures { enqueueSymlinkIssueIfNeeded(failure.error, url: failure.url) }
            Log.config.error(
                "config save failed for \(failures.count) file(s): \(first.error.localizedDescription, privacy: .public)"
            )
            errorMessage = first.error.localizedDescription
        }
    }

    // MARK: - Edit pipeline (dirty tracking + undo + autosave)

    /// An in-flight free-text field edit: the snapshot taken at the *first* keystroke
    /// of a focus session plus the action name to register it under. Consecutive
    /// keystrokes in the same field extend this group (keeping the earliest snapshot)
    /// instead of each pushing an undo step; `commitFieldEdit()` registers it as one
    /// step on focus loss, and any discrete edit flushes it first. nil when no field
    /// edit is open.
    /// The full undo-relevant state at a `mutate` baseline. `documents`, `groups` and
    /// `tagsByAlias` travel together so a single edit (e.g. deleting a file-backed
    /// group) reverts atomically — the file, its hosts, the `groups` row and every
    /// member's `group/<name>` tag all come back on ⌘Z.
    ///
    /// `tagsByAlias` used to be left out, and since a *virtual* group's membership lives
    /// entirely in those tags, every group operation undid only half of itself:
    /// undoing a rename restored the group's name but left members tagged
    /// `group/<newName>`, so `GroupResolver` found no group by that name and the hosts
    /// silently fell into "Ungrouped"; undoing a delete brought the group row back empty;
    /// undoing "move host to group" left the host in the group it had just left.
    struct EditorSnapshot: Equatable {
        var documents: [SSHConfigDocument]
        var groups: [PersistedGroup]
        var tagsByAlias: [String: [String]]
    }

    var coalescingFieldEdit: (snapshot: EditorSnapshot, actionName: String)?

    /// Clock for time-window coalescing of rapid discrete edits. Injectable so tests
    /// are deterministic (production uses the wall clock).
    var clock: () -> Date = { Date() }
    /// How long after a discrete edit a repeat of the *same target* folds into it,
    /// so e.g. stepping an integer or re-toggling a switch a few times is one undo step.
    var discreteCoalesceWindow: TimeInterval = 0.4
    /// The last discrete undo registration eligible for coalescing: its target key and
    /// when it happened. Reset by any non-targeted/structural edit, a disk reload, or
    /// an undo/redo — so only an uninterrupted burst on one target collapses.
    var lastDiscreteUndo: (target: String, at: Date)?

    #if DEBUG
        /// Test seam: how many undo steps were actually pushed. Coalesced repeats (folded
        /// into a prior step) don't increment it, so it measures the coalescing decision
        /// deterministically — unlike NSUndoManager's run-loop event grouping.
        var undoStepsRegistered = 0
    #endif
}
