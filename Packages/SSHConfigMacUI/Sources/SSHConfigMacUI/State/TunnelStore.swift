//
//  TunnelStore.swift
//  sshconfigmanager
//
//  App-side state for tunnels: the saved presets (persisted in the shared SQLite
//  database via `AppDatabase` — kept out of ssh_config so the config stays
//  lossless) plus the live, runtime-only status for each. Mirrors `ConfigStore`'s
//  @MainActor @Observable / shared-singleton shape.
//
//  This is also the supervisor: per tunnel it runs a recovery loop (start →
//  watch health → retry with backoff → give up), unifying the two failure
//  signals (engine-reported + local-port probe) and re-arming on network return
//  or wake. See docs/plans/tunneling/monitor.md and state-and-ui.md.
//

import Foundation
import Observation
import SSHConfigCore
@preconcurrency import UserNotifications

@MainActor
@Observable
final class TunnelStore {
    static let shared = TunnelStore()

    private(set) var presets: [TunnelPreset] = []
    /// Live status, keyed by preset id. Absent → `.stopped`.
    private(set) var statuses: [UUID: TunnelStatus] = [:]
    /// Per-tunnel rolling log/console (status transitions + engine lifecycle
    /// lines), newest last. Capped at `maxLogEntries` per tunnel.
    private(set) var logs: [UUID: [TunnelLogEntry]] = [:]
    /// Live byte throughput, keyed by preset id. Present only while a
    /// throughput-reporting engine has the tunnel up; absent → hidden in the UI.
    private(set) var throughput: [UUID: TunnelThroughput] = [:]
    /// Surfaced to the UI when a start fails.
    var errorMessage: String?

    /// Why the most recent connection attempt ended, kept around after the status
    /// has already moved on to "Reconnecting…". Without it the UI says a tunnel is
    /// retrying and never says what went wrong — the reason scrolled past in the
    /// console, or the user never opened it. Cleared once the tunnel reaches
    /// `.active`, and when it's started or stopped by hand.
    private(set) var lastFailureReason: [UUID: String] = [:]

    func failureReason(for id: UUID) -> String? { lastFailureReason[id] }

    /// Records an attempt's terminal reason. Synthetic cancellation reasons are not
    /// failures — they're what a deliberate `stop` looks like from inside the loop.
    private func noteFailure(_ id: UUID, _ reason: String) {
        guard reason != "cancelled" else { return }
        lastFailureReason[id] = reason
        Log.tunnel.error("tunnel attempt ended: \(reason, privacy: .public)")
    }

    /// A request to reveal a specific tunnel's console in the main window — set by
    /// the menu-bar indicator's "Logs" action and observed by `ContentView` (to
    /// switch to the Tunnels screen) and `TunnelsManagementView` (to select the
    /// tunnel). The `nonce` makes every request distinct so the same tunnel can be
    /// focused twice in a row and still fire `onChange`.
    private(set) var consoleFocus: ConsoleFocus?
    struct ConsoleFocus: Equatable {
        let id: UUID
        let nonce: Int
    }
    private var focusNonce = 0

    /// Asks the UI to open the main window on `id`'s console. Window activation is
    /// the caller's job (the menu-bar action does `openWindow` + `NSApp.activate`).
    func requestConsole(_ id: UUID) {
        focusNonce += 1
        consoleFocus = ConsoleFocus(id: id, nonce: focusNonce)
    }

    /// Test override; when nil the in-process NIO engine is used (see `currentEngine`).
    private let injectedEngine: TunnelEngine?
    private let nioEngine: NIOTunnelEngine
    /// SQLite-backed persistence (nil disables persistence, e.g. in some tests).
    private let database: AppDatabase?
    /// Legacy `tunnels.json` to import once, if present, on first run.
    private let legacyJSONURL: URL?
    /// Test seam: a custom notifier short-circuits the real `UNUserNotificationCenter`
    /// round-trip in `notify(title:body:)`. Nil (the production default) uses it.
    private let notifier: (@MainActor (_ title: String, _ body: String) -> Void)?

    /// The initial async load (DB open + migrate + read); awaited by tests and
    /// by autostart so they don't race the empty starting state.
    private var loadTask: Task<Void, Never>?
    /// The most recent async write; awaited by tests to observe persisted state.
    private var persistTask: Task<Void, Never>?
    /// True once the initial load finished. Guards against the load clobbering
    /// presets the user mutated during the (brief) launch window.
    private var didInitialLoad = false
    private var mutatedBeforeLoad = false

    /// The engine that actually started each tunnel — so stop/restart hit the
    /// same engine instance.
    private var engineByID: [UUID: TunnelEngine] = [:]
    /// The supervision task per running/recovering tunnel.
    private var supervisors: [UUID: Task<Void, Never>] = [:]

    /// Consecutive failed (re)connect attempts before giving up.
    private let giveUpAfter = 6
    /// Minimum time a tunnel must stay `.active` before a subsequent drop counts as a
    /// genuine recovery that resets the backoff counter. A shorter-lived "connected then
    /// immediately dropped" cycle is treated as a flap and does NOT reset `attempt`, so a
    /// pure flap eventually hits `giveUpAfter` instead of reconnecting forever (audit
    /// NET-2). Chosen well above a flap's sub-second/one-probe lifetime yet short enough
    /// that any normally-usable tunnel clears it.
    private let minStableUptimeToResetBackoff: TimeInterval = 30
    /// How long to wait for a fresh connection to become healthy.
    private let startupTimeout: TimeInterval = 20
    /// Base cadence for steady-state health probes of an active tunnel.
    private let probeInterval: Duration = .seconds(5)

    /// Background task draining ProbeScheduler's connectivity/wake signals.
    private var signalTask: Task<Void, Never>?

    /// How many log lines to keep per tunnel before dropping the oldest.
    private let maxLogEntries = 300

    /// Designated initializer. `database` is the shared SQLite store; `legacyJSONURL`
    /// is an old `tunnels.json` to import once on first run (nil to skip). `notifier`
    /// is a test seam — see its doc comment — and defaults to the real
    /// notification center.
    init(
        database: AppDatabase?, legacyJSONURL: URL?, engine: TunnelEngine?,
        notifier: (@MainActor (_ title: String, _ body: String) -> Void)? = nil,
        resolveChain: @escaping @MainActor (String) -> [TunnelHop]? = {
            try? TunnelJumpChain.resolve(alias: $0, in: ConfigStore.shared.configGraph)
        }
    ) {
        self.injectedEngine = engine
        self.nioEngine = NIOTunnelEngine()
        self.database = database
        self.legacyJSONURL = legacyJSONURL
        self.notifier = notifier
        self.resolveChain = resolveChain
        loadTask = Task { [weak self] in await self?.performInitialLoad() }
        startSchedulerSignals()
    }

    /// Production default: the app's shared SQLite store, importing any legacy JSON.
    convenience init() {
        #if DEBUG
            // Both the preview recording and the App Store screenshot harness want the
            // same thing: several presets with the first one genuinely RUNNING. A
            // stopped tunnel over an empty console is the worst possible advert for the
            // feature, so the screenshot path uses the demo engine too.
            if ScreenshotMode.isTunnelDemo || ScreenshotMode.isActive {
                self.init(
                    database: AppDatabase.shared,
                    legacyJSONURL: TunnelStore.defaultPersistenceURL,
                    engine: DemoTunnelEngine())
                seedTunnelDemo()
                return
            }
        #endif
        self.init(
            database: AppDatabase.shared,
            legacyJSONURL: TunnelStore.defaultPersistenceURL, engine: nil)
    }

    #if DEBUG
        /// Seeds the tunnel demo state: three presets (postgres local, redis local,
        /// SOCKS5 dynamic), the first already "Active" with a rich pre-populated console
        /// log and throughput. The in-memory state is the UI source of truth; the async
        /// DB load is blocked from overwriting it by `mutatedBeforeLoad`.
        private func seedTunnelDemo() {
            mutatedBeforeLoad = true
            let ps = ScreenshotMode.sampleTunnelPresets()
            // The screenshot run also gets the extra presets, several already up, so the
            // list shows the feature at scale. The recording gets only the three above.
            presets = ps + (ScreenshotMode.isTunnelDemo ? [] : ScreenshotMode.extraScreenshotTunnelPresets())
            if !ScreenshotMode.isTunnelDemo { seedExtraStatuses() }
            let active = ps[0]
            let baseDate = Date(timeIntervalSinceNow: -127)
            statuses[active.id] = .active(since: baseDate)
            logs[active.id] = [
                TunnelLogEntry(date: baseDate, level: .info, message: "Connecting to \(active.hostAlias)…"),
                TunnelLogEntry(
                    date: baseDate.addingTimeInterval(0.3), level: .detail,
                    message: "Host key verified (ssh-ed25519 SHA256:aBcDeFgH1234xYz)"),
                TunnelLogEntry(
                    date: baseDate.addingTimeInterval(0.6), level: .info,
                    message: "Authenticated using publickey (id_ed25519)"),
                TunnelLogEntry(
                    date: baseDate.addingTimeInterval(0.9), level: .info, message: "Listening on 127.0.0.1:5432"),
                TunnelLogEntry(
                    date: baseDate.addingTimeInterval(1.2), level: .status,
                    message: TunnelStatus.active(since: baseDate).label),
                TunnelLogEntry(
                    date: baseDate.addingTimeInterval(12.0), level: .detail,
                    message: "New inbound connection on 127.0.0.1:5432 → 10.0.1.20:5432"),
                TunnelLogEntry(
                    date: baseDate.addingTimeInterval(44.5), level: .detail,
                    message: "New inbound connection on 127.0.0.1:5432 → 10.0.1.20:5432"),
                TunnelLogEntry(
                    date: baseDate.addingTimeInterval(80.3), level: .detail,
                    message: "Keep-alive: peer is still responding"),
                TunnelLogEntry(
                    date: baseDate.addingTimeInterval(112.0), level: .detail,
                    message: "New inbound connection on 127.0.0.1:5432 → 10.0.1.20:5432"),
                TunnelLogEntry(
                    date: baseDate.addingTimeInterval(125.5), level: .detail,
                    message: "Throughput snapshot: ↓ 2.2 MB  ↑ 463 KB"),
            ]
            throughput[active.id] = TunnelThroughput(bytesIn: 2_341_760, bytesOut: 487_424)
        }

        /// Puts the screenshot-only presets into a mix of states. The `retrying` one is
        /// deliberate: the Tunnels caption claims the app keeps a tunnel up on its own,
        /// and a visible reconnect attempt is the shot that backs the claim.
        private func seedExtraStatuses() {
            let extras = ScreenshotMode.extraScreenshotTunnelPresets().map(\.name)
            let states: [String: (TunnelStatus, TunnelThroughput?)] = [
                "Grafana on prod": (
                    .active(since: Date(timeIntervalSinceNow: -4_318)),
                    TunnelThroughput(bytesIn: 18_874_368, bytesOut: 2_306_867)
                ),
                "Staging API": (
                    .active(since: Date(timeIntervalSinceNow: -932)),
                    TunnelThroughput(bytesIn: 5_138_022, bytesOut: 913_408)
                ),
                "Home Assistant": (.retrying(attempt: 2), nil),
            ]
            for preset in presets where extras.contains(preset.name) {
                guard let (status, bytes) = states[preset.name] else { continue }
                statuses[preset.id] = status
                if let bytes { throughput[preset.id] = bytes }
            }
        }
    #endif

    /// Test convenience: persist to a private SQLite file at `persistenceURL`.
    convenience init(
        persistenceURL: URL?, engine: TunnelEngine? = nil,
        notifier: (@MainActor (_ title: String, _ body: String) -> Void)? = nil,
        resolveChain: @escaping @MainActor (String) -> [TunnelHop]? = {
            try? TunnelJumpChain.resolve(alias: $0, in: ConfigStore.shared.configGraph)
        }
    ) {
        self.init(
            database: persistenceURL.flatMap { try? AppDatabase(url: $0) },
            legacyJSONURL: nil, engine: engine, notifier: notifier,
            resolveChain: resolveChain)
    }

    /// Test convenience: explicit database + legacy JSON (migration test).
    convenience init(
        databaseURL: URL?, legacyJSONURL: URL?, engine: TunnelEngine?,
        notifier: (@MainActor (_ title: String, _ body: String) -> Void)? = nil,
    ) {
        self.init(
            database: databaseURL.flatMap { try? AppDatabase(url: $0) },
            legacyJSONURL: legacyJSONURL, engine: engine, notifier: notifier)
    }

    /// The engine to drive tunnels: the test-injected one if present, else the
    /// in-process NIO engine.
    private var currentEngine: TunnelEngine {
        injectedEngine ?? nioEngine
    }

    // MARK: - Loading (async; in-memory `presets` is the UI source of truth)

    /// Loads presets from the database on launch, importing a legacy JSON file
    /// the first time. Won't overwrite presets the user mutated before this ran.
    private func performInitialLoad() async {
        defer { didInitialLoad = true }
        guard let database else { return }
        do {
            let loaded: [TunnelPreset]
            if try await database.isEmpty(), let legacy = loadLegacyPresets() {
                Log.tunnel.notice("importing \(legacy.count) tunnel preset(s) from legacy tunnels.json")
                try await database.replaceAll(legacy)
                archiveLegacyFile()
                loaded = legacy
            } else {
                loaded = try await database.load()
            }
            // If the user already added/edited something during launch, keep theirs.
            if !mutatedBeforeLoad {
                presets = loaded
                Log.tunnel.notice("tunnel store loaded on launch: \(loaded.count) preset(s)")
            } else {
                Log.tunnel.notice("tunnel store load on launch superseded by an edit made during startup")
            }
        } catch {
            Log.tunnel.error("failed to load tunnel presets: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't load tunnels: \(error.localizedDescription)"
        }
    }

    private func loadLegacyPresets() -> [TunnelPreset]? {
        guard let legacyJSONURL,
            let data = try? Data(contentsOf: legacyJSONURL),
            let decoded = try? JSONDecoder().decode([TunnelPreset].self, from: data),
            !decoded.isEmpty
        else { return nil }
        return decoded
    }

    /// Renames the imported JSON aside so it isn't re-imported next launch.
    private func archiveLegacyFile() {
        guard let legacyJSONURL else { return }
        let archived = legacyJSONURL.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: legacyJSONURL, to: archived)
    }

    /// True once the initial async load (DB → presets) has finished. The UI uses
    /// this to avoid flashing an empty state while loading.
    var isLoaded: Bool { didInitialLoad }

    /// Test/launch support: await the initial load and any pending write.
    func waitUntilLoaded() async { await loadTask?.value }
    func waitForPendingWrites() async { await persistTask?.value }

    // MARK: - Status updates (single chokepoint → opt-in notifications)

    /// Sets a tunnel's status and posts an opt-in notification on the meaningful
    /// transitions: gave-up failure, and recovery back to active after trouble.
    private func setStatus(_ id: UUID, _ new: TunnelStatus) {
        let old = statuses[id] ?? .stopped
        statuses[id] = new
        guard old != new else { return }

        // Record the transition in the tunnel's console as a `.status` line.
        appendLog(id, .status, new.label)

        let name = presets.first { $0.id == id }?.displayName ?? "Tunnel"
        // Every transition, in the unified log too — the console is per-tunnel and
        // in-memory, so it can't answer "what was this tunnel doing at 03:12?".
        Log.tunnel.notice(
            "tunnel '\(name, privacy: .private)': \(old.label, privacy: .public) → \(new.label, privacy: .public)")
        switch (old, new) {
        case (_, .failed(let reason)):
            notify(title: "Tunnel failed", body: "\(name): \(reason)")
        case (.retrying, .active), (.degraded, .active):
            notify(title: "Tunnel recovered", body: "\(name) is active again.")
        default:
            break
        }
    }

    /// Appends a line to a tunnel's console, trimming to `maxLogEntries`.
    private func appendLog(_ id: UUID, _ level: TunnelLogLevel, _ message: String) {
        var log = logs[id] ?? []
        log.append(TunnelLogEntry(date: Date(), level: level, message: message))
        if log.count > maxLogEntries { log.removeFirst(log.count - maxLogEntries) }
        logs[id] = log
    }

    /// Whether we've already asked the system for notification permission this
    /// session — so a flurry of failed/recovered transitions can't re-prompt.
    private var didRequestNotificationAuth = false

    private func notify(title: String, body: String) {
        guard AppSettings.shared.tunnelNotificationsEnabled else { return }
        // Test seam: a custom notifier short-circuits the real notification center.
        if let notifier {
            notifier(title, body)
            return
        }
        // Ask the system for permission at most once per session; later transitions
        // won't re-prompt. The flag is read/written on the main actor.
        let mayRequest = !didRequestNotificationAuth
        if mayRequest { didRequestNotificationAuth = true }
        Task { await Self.deliver(title: title, body: body, mayRequestAuthorization: mayRequest) }
    }

    /// Delivers a local notification via the async `UNUserNotificationCenter` API,
    /// requesting authorization the first time if it's still undetermined.
    private static func deliver(title: String, body: String, mayRequestAuthorization: Bool) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        let authorized: Bool
        switch status {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined where mayRequestAuthorization:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = false
        }
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Status access

    func status(for id: UUID) -> TunnelStatus { statuses[id] ?? .stopped }
    func status(for preset: TunnelPreset) -> TunnelStatus { status(for: preset.id) }

    /// Console log for a tunnel, oldest first (natural reading order).
    func logEntries(for id: UUID) -> [TunnelLogEntry] { logs[id] ?? [] }

    /// Clears a tunnel's console (the "Clear" action). Does not affect the tunnel.
    func clearLogs(_ id: UUID) { logs[id] = [] }

    func presets(for hostAlias: String) -> [TunnelPreset] {
        presets.filter { $0.hostAlias == hostAlias }
    }

    /// Presets currently meant to be up — drives the menu-bar control center.
    var runningPresets: [TunnelPreset] {
        presets.filter { status(for: $0.id).isRunning }
    }

    /// The in-process engine can always start/stop tunnels from within the app.
    var canControlEngine: Bool { true }

    // MARK: - CRUD

    func add(_ preset: TunnelPreset) {
        presets.append(preset)
        persist()
    }

    func update(_ preset: TunnelPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persist()
    }

    /// Repoints presets when a Host's primary alias is renamed, so a tunnel keyed
    /// to the old alias keeps following its host. Called from the alias-edit commit
    /// boundaries in the host editor (field blur / raw-apply). Silent and idempotent.
    func renameHostAlias(from old: String, to new: String) {
        guard old != new, !old.isEmpty, !new.isEmpty else { return }
        var changed = false
        for index in presets.indices where presets[index].hostAlias == old {
            presets[index].hostAlias = new
            changed = true
        }
        if changed { persist() }
    }

    /// Restarts any currently-running tunnels bound to `hostAlias` so they pick up
    /// a config change (HostName, Port, ProxyJump, auth settings, …) that only
    /// takes effect on a fresh connection — an already-open SSH link keeps talking
    /// to whatever address it dialled originally. Called from the same host-editor
    /// commit boundaries as `renameHostAlias` (field blur / raw-apply); a no-op for
    /// presets that aren't currently running.
    func restartRunningTunnels(for hostAlias: String) {
        guard !hostAlias.isEmpty else { return }
        for preset in presets where preset.hostAlias == hostAlias && status(for: preset.id).isRunning {
            stop(preset.id)
            start(preset)
        }
    }

    /// The hop chain each running tunnel resolved when it started. An open SSH link
    /// keeps the user/host/port/identity it dialled with, so this is the baseline a
    /// reload compares against to decide whether a config change actually affects
    /// what's on the wire.
    private var startedChains: [UUID: [TunnelHop]] = [:]

    /// Resolves an alias to its hop chain. A seam so tests can drive the comparison
    /// without standing up a `ConfigStore`; production reads the live config graph.
    private let resolveChain: @MainActor (String) -> [TunnelHop]?

    /// Restarts every running tunnel whose resolved hop chain no longer matches the
    /// one it connected with — called from `ConfigStore.reload()`, which is the only
    /// path an *external* edit (vim, a script, a dotfiles pull) travels: the in-app
    /// host editors already restart at their own commit boundaries via
    /// `restartRunningTunnels(for:)`. Without this an edited `User`/`HostName`/
    /// `ProxyJump` silently never reaches a tunnel that's already up, and the console
    /// keeps showing the identity it dialled with hours ago.
    ///
    /// Compares whole chains rather than the target alias, so a change to a
    /// *jump* host — which `restartRunningTunnels(for:)` misses, since no preset
    /// names it — counts too. A chain that no longer resolves (the host block was
    /// deleted mid-session) leaves the tunnel alone: `reconcileOrphanedPresets`
    /// already flags that, and tearing down a working link over it would be worse.
    func restartTunnelsWithChangedConfig() {
        for preset in presets where status(for: preset.id).isRunning {
            guard let started = startedChains[preset.id],
                let current = resolveChain(preset.hostAlias),
                current != started
            else { continue }
            Log.tunnel.notice(
                "restarting tunnel — host config changed since it connected: \(preset.hostAlias, privacy: .public)")
            appendLog(preset.id, .info, "Host configuration changed — reconnecting to apply it.")
            stop(preset.id)
            start(preset)
        }
    }

    /// Presets whose `hostAlias` doesn't match any currently loaded `Host` block —
    /// set by `reconcileOrphanedPresets(validHostAliases:)`. Surfaced by the Tunnels
    /// UI as a "host not found" badge.
    private(set) var orphanedPresetIDs: Set<UUID> = []

    func isOrphaned(_ preset: TunnelPreset) -> Bool { orphanedPresetIDs.contains(preset.id) }

    /// Recomputes which presets are orphaned against the aliases `ConfigStore` just
    /// loaded — called from `ConfigStore.reload()` after every reload (launch, an
    /// in-app save, or an external edit picked up by the file watcher), so a preset
    /// left pointing at a renamed-or-removed host doesn't silently sit there looking
    /// healthy.
    ///
    /// Deliberately does NOT auto-migrate `hostAlias` to a guessed replacement the
    /// way `renameHostAlias` does for an in-app rename: a reload has no reliable way
    /// to tell "this alias was renamed to that one" apart from "this alias was
    /// deleted and an unrelated one was added" (host blocks don't carry a stable
    /// identity across a re-parse), and a tunnel is a live network target — silently
    /// repointing it at a guessed-wrong host would be worse than just flagging it,
    /// since a mismatched real host fails quietly (or, worse, "succeeds" against the
    /// wrong server) instead of the loud, safe failure an orphaned preset produces.
    func reconcileOrphanedPresets(validHostAliases: Set<String>) {
        let orphaned = Set(presets.filter { !validHostAliases.contains($0.hostAlias) }.map(\.id))
        guard orphaned != orphanedPresetIDs else { return }
        let newlyOrphaned = orphaned.subtracting(orphanedPresetIDs)
        let recovered = orphanedPresetIDs.subtracting(orphaned)
        orphanedPresetIDs = orphaned
        if !newlyOrphaned.isEmpty {
            let names = presets.filter { newlyOrphaned.contains($0.id) }.map(\.displayName).joined(separator: ", ")
            Log.tunnel.notice(
                "tunnel preset(s) orphaned — host alias no longer found in config: \(names, privacy: .public)")
        }
        if !recovered.isEmpty {
            Log.tunnel.notice("\(recovered.count) previously-orphaned tunnel preset(s) matched a host again")
        }
    }

    func delete(_ id: UUID) {
        stop(id)
        presets.removeAll { $0.id == id }
        statuses[id] = nil
        logs[id] = nil
        throughput[id] = nil
        orphanedPresetIDs.remove(id)
        persist()
    }

    // MARK: - Start / stop

    func start(_ preset: TunnelPreset) {
        guard preset.isValid else {
            errorMessage = TunnelEngineError.invalidPreset.localizedDescription
            return
        }
        guard !status(for: preset.id).isRunning else { return } // no double-start
        let engine = currentEngine
        engineByID[preset.id] = engine
        startedChains[preset.id] = resolveChain(preset.hostAlias)
        lastFailureReason[preset.id] = nil
        setStatus(preset.id, .starting) // reflect immediately; the supervisor refines it
        beginSupervision(preset, engine: engine)
    }

    func stop(_ id: UUID) {
        supervisors[id]?.cancel()
        supervisors[id] = nil
        throughput[id] = nil
        startedChains[id] = nil
        lastFailureReason[id] = nil
        if let preset = presets.first(where: { $0.id == id }) {
            (engineByID[id] ?? currentEngine).stop(preset)
        }
        engineByID[id] = nil
        setStatus(id, .stopped) // single chokepoint: logs the transition consistently
    }

    func toggle(_ preset: TunnelPreset) {
        status(for: preset.id).isRunning ? stop(preset.id) : start(preset)
    }

    /// Starts every autostart-enabled preset (called once on launch). Waits for
    /// the async load so presets are populated before deciding what to start.
    func restoreAutostartTunnels() {
        Task { [weak self] in
            await self?.waitUntilLoaded()
            guard let self else { return }
            for preset in self.presets where preset.autostart { self.start(preset) }
        }
    }

    // MARK: - Supervision (start → watch → retry with backoff → give up)

    private func beginSupervision(_ preset: TunnelPreset, engine: TunnelEngine) {
        let id = preset.id
        supervisors[id]?.cancel()
        supervisors[id] = Task { [weak self] in await self?.supervise(preset, engine: engine) }
    }

    private func supervise(_ preset: TunnelPreset, engine: TunnelEngine) async {
        let id = preset.id
        let canRecover = engine.capabilities.canStop // only auto-restart engines we control
        var attempt = 0

        while !Task.isCancelled {
            setStatus(id, attempt == 0 ? .starting : .retrying(attempt: attempt))

            do {
                try engine.start(preset)
            } catch {
                let reason = localized(error)
                noteFailure(id, reason)
                setStatus(id, .failed(reason: reason))
                return
            }

            let (outcome, activeSince) = await runConnection(preset, engine: engine)

            // Cancelled while a connection was in flight: the user stopped it, it was
            // deleted, or `restartRunningTunnels` replaced this supervisor. The
            // cancellation arrives mid-`runConnection`, which then returns a synthetic
            // `.down`. Return BEFORE any teardown, and before the retry block below
            // could set `.retrying` and clobber the `.stopped` that `stop(_:)` just
            // wrote (which would freeze the tunnel on "Reconnecting…" with no
            // supervisor alive to ever reconnect).
            //
            // Returning without tearing down is deliberate, not an omission. `stop(_:)`
            // is the only path that cancels a *live* supervisor, and it has already
            // called `engine.stop` and cleared the throughput. Meanwhile a restart does
            // `stop(id)` then `start(preset)` synchronously, so by the time this
            // cancelled task resumes, a NEW attempt is very likely already running on
            // the same shared engine — the `engine.stop(preset)`/`throughput[id] = nil`
            // that used to sit here tore down *that* tunnel instead, and the fresh
            // supervisor then watched its own event stream die and dropped straight
            // into "Reconnecting…". Editing a host field while its tunnel was up was
            // enough to trigger it.
            if Task.isCancelled { return }
            // Hold on to *why* this attempt ended before the status flips to
            // "Reconnecting…" and buries it.
            switch outcome {
            case .down(let reason), .fatal(let reason): noteFailure(id, reason)
            case .healthy: break
            }
            engine.stop(preset)
            throughput[id] = nil

            if case .fatal(let reason) = outcome {
                setStatus(id, .failed(reason: reason))
                return
            }
            guard canRecover else {
                let reason = {
                    if case .down(let r) = outcome { return r }
                    return "Connection lost."
                }()
                setStatus(id, .failed(reason: reason))
                return
            }
            // A tunnel that stayed up for a sustained period then dropped restarts its
            // backoff from 1. A connect->instant-drop flap does NOT qualify: resetting on
            // any `.active`, however brief, zeroed `attempt` every cycle so `giveUpAfter`
            // was unreachable — an endless ~1s reconnect loop that hammered the server and
            // re-prompted for interactive auth each time (audit NET-2).
            if let activeSince, Date().timeIntervalSince(activeSince) >= minStableUptimeToResetBackoff {
                attempt = 0
            }
            attempt += 1
            guard attempt <= giveUpAfter else {
                setStatus(id, .failed(reason: "Gave up after \(giveUpAfter) attempts."))
                return
            }
            setStatus(id, .retrying(attempt: attempt))
            try? await Task.sleep(for: backoff(attempt))
        }
        // Cancelled between attempts (during the backoff sleep above, or at loop entry).
        // No teardown here either, for exactly the reason spelled out at the in-flight
        // cancellation check: `stop(_:)` already did it, and a replacement supervisor may
        // now own the engine.
    }

    /// A terminal verdict for one connection attempt. `.healthy` is never returned
    /// as a terminal value — it's only an intermediate per-tick signal.
    private enum Outcome {
        case healthy
        case down(String)
        case fatal(String)
    }

    /// One thing the supervisor reacts to while watching a tunnel: an immediate
    /// engine liveness event, a local-port probe result, a bare refresh tick (for
    /// `-R`, which has no local port), or the one-shot startup deadline.
    private enum Tick {
        case engine(EngineEvent)
        case probe(ConnectionResult)
        case refresh
        case startupTimeout
    }

    /// Drives one connection attempt to a terminal outcome, consuming the engine's
    /// event stream **exactly once** (so we never re-iterate an AsyncStream). It
    /// transitions `starting → active` on the first healthy signal — reflecting it
    /// in the store — then keeps watching until the tunnel drops or faults. Returns
    /// the terminal outcome and the instant it first reached `active` (nil if it never
    /// did), so the supervisor can reset the backoff only after a sustained uptime.
    private func runConnection(_ preset: TunnelPreset, engine: TunnelEngine) async -> (Outcome, Date?) {
        let id = preset.id
        let events = engine.events(for: preset)
        let port = preset.localProbePort

        // No way to observe (e.g. Assist + -R): trust after a grace, then hold.
        if events == nil && port == nil {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return (.down("cancelled"), nil) }
            let since = Date()
            setStatus(id, .active(since: since))
            while !Task.isCancelled { try? await Task.sleep(for: probeInterval) }
            return (.down("cancelled"), since)
        }

        var becameActive = false
        // The instant the tunnel first reached `.active`, kept in lockstep with
        // `becameActive` so the supervisor can measure how long it stayed up (NET-2).
        var activeSince: Date?
        var health = TunnelHealth()
        var status = TunnelStatus.starting
        // Set once the engine shows an interactive prompt (passphrase/2FA). The
        // startup deadline is then suppressed for this attempt — the user's typing
        // time can't be bounded by a fixed client timeout (see `.startupTimeout`).
        var interactiveSeen = false

        for await tick in tickStream(for: preset, engine: engine) {
            if Task.isCancelled { break }
            switch tick {
            case .engine(let event):
                // Console lines aren't health signals — record and move on.
                if case .log(let level, let message) = event {
                    appendLog(id, level, message)
                    continue
                }
                if case .awaitingInput(let waiting) = event {
                    if waiting {
                        interactiveSeen = true
                        appendLog(id, .info, "Waiting for sign-in (passphrase or 2FA)…")
                    }
                    continue
                }
                // Surface the *reason* a connection ended in the console. The status
                // line only shows "Reconnecting…"/"Failed"; this explains why.
                switch event {
                case .closed(let reason):
                    appendLog(id, .detail, "SSH connection closed" + (reason.map { ": \($0)" } ?? "."))
                case .failed(let reason):
                    appendLog(id, .error, "Connection error: \(reason)")
                default:
                    break
                }
                switch outcome(for: event) {
                case .healthy:
                    if !becameActive {
                        becameActive = true
                        activeSince = Date()
                        status = .active(since: activeSince!)
                        lastFailureReason[id] = nil
                        setStatus(id, status)
                    }
                    health = TunnelHealth() // recovered: reset the failure streak
                case .down(let reason): return (.down(reason), activeSince)
                case .fatal(let reason): return (.fatal(reason), activeSince)
                case .none: break
                }
            case .probe(let result):
                publishThroughput(id, engine.throughput(for: preset))
                if !becameActive {
                    if result.isReachable {
                        becameActive = true
                        activeSince = Date()
                        status = .active(since: activeSince!)
                        lastFailureReason[id] = nil
                        setStatus(id, status)
                    }
                } else {
                    let next = health.apply(result, to: status, now: Date())
                    if case .failed = next { return (.down("Lost the tunnel."), activeSince) }
                    if next != status {
                        setStatus(id, next)
                        status = next
                    }
                }
            case .refresh:
                publishThroughput(id, engine.throughput(for: preset))
            case .startupTimeout:
                // Don't fail an attempt that's blocked on (or has shown) an
                // interactive prompt — the user may still be entering 2FA.
                if !becameActive && !interactiveSeen {
                    return (.down("Timed out establishing the tunnel."), nil)
                }
            }
        }
        return (.down("cancelled"), activeSince)
    }

    /// Maps an engine event to an outcome. `.failed`/`.closed` reasons run through
    /// `classify` so a refused connection retries while a bad key gives up.
    private func outcome(for event: EngineEvent) -> Outcome? {
        switch event {
        case .connected: return .healthy
        case .failed(let reason): return classify(reason)
        case .closed(let reason): return classify(reason ?? "Connection lost.")
        case .log, .awaitingInput: return nil // handled before this point; never a health signal
        }
    }

    /// Merges the engine's event stream with a probe/refresh cadence (and a one-shot
    /// startup-timeout) into one sequence, so a connection drop escalates
    /// *immediately* instead of waiting for the next tick. Probes go through the
    /// shared, gated, concurrency-capped scheduler.
    private func tickStream(for preset: TunnelPreset, engine: TunnelEngine) -> AsyncStream<Tick> {
        let events = engine.events(for: preset)
        let port = preset.localProbePort
        // Engines that report liveness (the in-process NIO engine) don't need
        // local-port probing — health comes from their connected/closed events.
        // Probing would open a throwaway connection every tick, which the engine
        // logs as a "New connection" and even forwards to the remote target. So
        // only probe when the engine can't observe its own connection.
        let probesLocally = port != nil && !engine.capabilities.reportsLiveness
        let base = probeInterval
        let startupSeconds = startupTimeout
        return AsyncStream { continuation in
            let eventTask = Task {
                guard let events else { return }
                for await event in events { continuation.yield(.engine(event)) }
            }
            let probeTask = Task {
                while !Task.isCancelled {
                    if probesLocally, let port {
                        // nil means this task was cancelled while parked waiting
                        // for a probe slot (audit #29) — skip yielding and let
                        // the loop's own `!Task.isCancelled` check end it next
                        // iteration, same as any other cancellation here.
                        if let result = await ProbeScheduler.shared.run({
                            await ConnectionTester.probe(host: "127.0.0.1", port: port, timeout: 3)
                        }) {
                            continuation.yield(.probe(result))
                        }
                    } else {
                        continuation.yield(.refresh) // event-driven liveness (or -R): just refresh throughput
                    }
                    try? await Task.sleep(for: await ProbeScheduler.shared.interval(base: base))
                }
            }
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(startupSeconds))
                continuation.yield(.startupTimeout)
            }
            continuation.onTermination = { _ in
                eventTask.cancel()
                probeTask.cancel()
                timeoutTask.cancel()
            }
        }
    }

    private func publishThroughput(_ id: UUID, _ value: TunnelThroughput?) {
        if let value { throughput[id] = value }
    }

    /// Substrings in a failure reason that mark it as fatal (don't retry):
    /// credentials/config problems that retrying can't fix. "auth" / "permission
    /// denied" cover a rejected key or password (a bad key never fixes itself).
    /// (No "rsa" here: RSA is supported now, so an RSA-related blip is not
    /// inherently fatal — a genuine RSA auth rejection is caught by "auth".)
    private static let fatalReasonMarkers = [
        "passphrase", "host key", "proxyjump",
        "identityfile", "auth", "permission denied", "unsupported", "cancelled",
    ]

    /// Hard failures we should not keep retrying.
    private func classify(_ reason: String) -> Outcome {
        let r = reason.lowercased()
        return Self.fatalReasonMarkers.contains(where: r.contains) ? .fatal(reason) : .down(reason)
    }

    private func localized(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Exponential backoff with ±20% jitter (1s, 2s, 5s, 15s, then the user-configured
    /// cap — default 60s, via `AppSettings.tunnelMaxBackoffSeconds`). The schedule
    /// itself is pure and lives in `TunnelBackoff` (SSHConfigCore) so it's unit-testable
    /// without this store or `AppSettings`.
    private func backoff(_ attempt: Int) -> Duration {
        TunnelBackoff.duration(forAttempt: attempt, cap: AppSettings.shared.tunnelMaxBackoffSeconds)
    }

    // MARK: - Network-return / wake re-arming (via the shared scheduler)

    /// Drains ProbeScheduler's connectivity/wake signals: when the network returns
    /// or the machine wakes, proactively re-arm tunnels that had given up rather
    /// than waiting out a backoff. One shared NWPathMonitor lives in the scheduler.
    private func startSchedulerSignals() {
        ProbeScheduler.shared.start()
        signalTask = Task { [weak self] in
            let stream = await ProbeScheduler.shared.signals()
            for await signal in stream {
                guard !Task.isCancelled else { break }
                switch signal {
                case .pathReturned, .didWake:
                    await MainActor.run { self?.rearmFailedTunnels() }
                case .pathLost:
                    break // probes pause inside the scheduler; nothing to do here
                }
            }
        }
    }

    /// Restarts tunnels that gave up, once the network/wake suggests they might
    /// work again. Only engines we can control are re-armed.
    private func rearmFailedTunnels() {
        for preset in presets {
            guard case .failed = status(for: preset.id),
                let engine = engineByID[preset.id], engine.capabilities.canStop
            else { continue }
            beginSupervision(preset, engine: engine)
        }
    }

    // MARK: - Persistence

    /// The legacy `tunnels.json` file, imported once into SQLite if present.
    static let defaultPersistenceURL: URL? = AppDatabase.supportDirectory?.appendingPathComponent("tunnels.json")

    /// Writes the current presets to SQLite asynchronously. The in-memory list is
    /// already updated, so the UI reflects the change immediately; this just makes
    /// it durable. Replaces the whole set — cheap at this row count.
    private func persist() {
        if !didInitialLoad { mutatedBeforeLoad = true }
        guard let database else { return }
        let snapshot = presets
        let previous = persistTask
        persistTask = Task { [weak self] in
            await previous?.value // keep writes in order; last snapshot wins
            do {
                try await database.replaceAll(snapshot)
            } catch {
                Log.tunnel.error("failed to persist tunnels: \(error.localizedDescription, privacy: .public)")
                self?.errorMessage = "Couldn't save tunnels: \(error.localizedDescription)"
            }
        }
    }
}
