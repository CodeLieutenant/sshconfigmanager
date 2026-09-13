//
//  HostKeyMonitor.swift
//  SSHConfigMacUI
//
//  The alerts drive three surfaces: a banner + one-click resolution on the Known Hosts
//  screen, a section in the menu-bar extra, and the notification itself. Probing rides
//  the shared `ProbeScheduler`, so it honours the app-wide concurrency cap and pauses
//  while offline / asleep alongside the tunnel supervisor.
//

import Foundation
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
@preconcurrency import UserNotifications

/// One detected discrepancy between a host's live key and what's stored.
struct HostKeyAlert: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case changed // a stored key of this type exists but differs (possible MITM / re-key)
        case newKey // the server offered a key type not present in known_hosts
    }
    /// Stable across sweeps: same host + same live key ⇒ same alert (so it isn't
    /// re-notified every hour, only when it first appears).
    let id: String
    let groupID: String
    let hostTitle: String // the raw host/IP recorded in known_hosts
    let displayName: String // the friendly ssh_config alias, when known
    let hostToken: String // comma-joined host field, for writing a resolution
    let keyType: String
    let serverFingerprint: String
    let serverOpenSSH: String // full `type base64`, so the UI can trust/replace it
    let kind: Kind
    let detectedAt: Date
}

@MainActor
@Observable
final class HostKeyMonitor {
    static let shared = HostKeyMonitor()

    /// Unresolved discrepancies from the most recent sweep.
    private(set) var alerts: [HostKeyAlert] = []
    /// True while a sweep is in flight (drives the menu-bar / header spinner).
    private(set) var isChecking = false
    /// When the last sweep finished (restored from the database on launch).
    private(set) var lastCheck: Date?
    /// The most recent check record per host group ID. Populated from the DB on launch
    /// and kept current by sweep() and recordManualCheck(). Drives per-host sidebar
    /// indicators and the "Security" card in the Known Hosts detail pane.
    private(set) var latestCheckPerHost: [String: AppDatabase.HostKeyCheckRecord] = [:]

    /// How recently host keys were last verified — the security-freshness signal shown
    /// as a green / amber / red badge. Thresholds: fresh < 1 day, stale 1–7 days,
    /// critical > 7 days, never = no check on record.
    enum Freshness: Sendable {
        case never, fresh, stale, critical

        var symbol: String {
            switch self {
            case .fresh: return "checkmark.shield.fill"
            case .stale: return "exclamationmark.shield.fill"
            case .critical: return "xmark.shield.fill"
            case .never: return "shield.slash"
            }
        }
        var tint: StatusKind {
            switch self {
            case .fresh: return .ok
            case .stale: return .warn
            case .critical: return .error
            case .never: return .idle
            }
        }
    }

    /// Classifies `lastCheck` against `now()` into the freshness buckets.
    var freshness: Freshness {
        guard let lastCheck else { return .never }
        let age = now().timeIntervalSince(lastCheck)
        if age > 7 * 86_400 { return .critical }
        if age > 86_400 { return .stale }
        return .fresh
    }

    /// A compact label for the header pill, e.g. "Checked 5 minutes ago" / "Never checked".
    var freshnessShortLabel: String {
        guard let lastCheck else { return "Never checked" }
        return "Checked \(lastCheck.formatted(.relative(presentation: .named)))"
    }

    /// A fuller label for tooltips, calling out staleness.
    var freshnessLabel: String {
        guard let lastCheck else { return "Host keys never checked" }
        let when = lastCheck.formatted(.relative(presentation: .named))
        switch freshness {
        case .critical: return "Not checked in over a week (\(when))"
        case .stale: return "Not checked recently (\(when))"
        default: return "Checked \(when)"
        }
    }

    typealias ScanFn =
        @Sendable (_ host: String, _ port: Int) async -> Result<HostKeyScanner.Probe, HostKeyScanner.ScanError>

    private let groupsProvider: @MainActor () -> [KnownHostGroup]
    private let settings: AppSettings
    private let scan: ScanFn
    private let now: () -> Date
    private let notifier: (@MainActor ([HostKeyAlert]) -> Void)?
    private let database: AppDatabase?

    private var loopTask: Task<Void, Never>?
    /// Set once we've prompted for notification permission this session (don't re-ask).
    private var didRequestNotificationAuth = false
    /// Guards the one-time restore of persisted state on launch.
    private var didRestore = false

    init(
        groups: @escaping @MainActor () -> [KnownHostGroup] = {
            KnownHostGroup.build(
                from: ConfigStore.shared.knownHosts,
                configAliasesByHost: ConfigStore.shared.configAliasesByHost())
        },
        settings: AppSettings = .shared,
        now: @escaping () -> Date = { Date() },
        scan: @escaping ScanFn = { await HostKeyScanner.scan(host: $0, port: $1) },
        database: AppDatabase? = AppDatabase.shared,
        notifier: (@MainActor ([HostKeyAlert]) -> Void)? = nil
    ) {
        self.groupsProvider = groups
        self.settings = settings
        self.now = now
        self.scan = scan
        self.database = database
        self.notifier = notifier
    }

    // MARK: - Lifecycle

    /// Starts the periodic sweep loop (idempotent). Restores the last-known check state
    /// from the database first so the freshness badge and any open alerts are correct
    /// immediately on launch, before the first live sweep.
    func start() {
        ProbeScheduler.shared.start()
        Task { [weak self] in
            await self?.restore()
            self?.rearm()
        }
    }

    /// Loads the most recent persisted check per host: sets `lastCheck` (freshness) and
    /// rebuilds any standing changed/new-key alerts. Runs once.
    private func restore() async {
        guard !didRestore, let database else { return }
        didRestore = true
        guard let records = try? await database.loadLatestHostKeyChecks() else { return }
        lastCheck = records.map(\.checkedAt).max()
        latestCheckPerHost = Dictionary(records.map { ($0.groupID, $0) }, uniquingKeysWith: { a, _ in a })
        alerts = records.compactMap(Self.alert(from:))
    }

    private static func alert(from r: AppDatabase.HostKeyCheckRecord) -> HostKeyAlert? {
        let kind: HostKeyAlert.Kind
        switch r.outcome {
        case "changed": kind = .changed
        case "newKey": kind = .newKey
        default: return nil
        }
        return HostKeyAlert(
            id: "\(r.groupID)|\(r.fingerprint)", groupID: r.groupID,
            hostTitle: r.hostTitle, displayName: r.displayName, hostToken: r.hostToken,
            keyType: r.keyType, serverFingerprint: r.fingerprint, serverOpenSSH: r.serverOpenSSH,
            kind: kind, detectedAt: r.checkedAt)
    }

    /// Cancels and (if enabled) restarts the loop. Clears alerts when turned off.
    func rearm() {
        loopTask?.cancel()
        loopTask = nil
        guard settings.hostKeyMonitorEnabled else {
            alerts = []
            return
        }
        loopTask = Task { [weak self] in await self?.loop() }
    }

    private func loop() async {
        // Let launch settle before the first network sweep.
        if (try? await Task.sleep(for: .seconds(20))) == nil { return }
        while !Task.isCancelled {
            await sweep(reason: .scheduled)
            let minutes = max(5, settings.hostKeyCheckIntervalMinutes)
            if (try? await Task.sleep(for: .seconds(Double(minutes) * 60))) == nil { return }
        }
    }

    /// Triggers an immediate sweep (menu-bar "Check Now" / header refresh).
    func checkNow() {
        Task { await sweep(reason: .manual) }
    }

    enum Reason { case scheduled, manual }

    /// Drops standing alerts for a host once the user has resolved it (the next sweep
    /// would clear them anyway; this updates the UI immediately).
    func dismissAlerts(forGroup groupID: String) {
        alerts.removeAll { $0.groupID == groupID }
    }

    /// Records the result of a user-triggered manual verify. Updates
    /// `latestCheckPerHost` immediately so the sidebar and detail pane reflect the
    /// result without waiting for the next background sweep. Also persists to the DB.
    func recordManualCheck(_ record: AppDatabase.HostKeyCheckRecord) {
        latestCheckPerHost[record.groupID] = record
        if lastCheck.map({ record.checkedAt > $0 }) ?? true { lastCheck = record.checkedAt }
        Task { [weak self] in
            guard let db = self?.database else { return }
            try? await db.recordHostKeyChecks([record])
        }
    }

    // MARK: - The sweep

    func sweep(reason: Reason) async {
        // Scheduled sweeps respect the toggle; a manual "Check Now" always runs.
        if reason == .scheduled, !settings.hostKeyMonitorEnabled { return }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let groups = groupsProvider().filter { $0.connectHost != nil }
        Log.knownHosts.info(
            "host-key sweep (\(String(describing: reason), privacy: .public)) over \(groups.count, privacy: .public) host(s)"
        )

        let previous = Dictionary(alerts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var fresh: [HostKeyAlert] = []
        var records: [AppDatabase.HostKeyCheckRecord] = []
        let sweptAt = now()

        for group in groups {
            if Task.isCancelled { return }
            guard let host = group.connectHost else { continue }
            let port = group.connectPort
            // nil means this task was cancelled while waiting for a probe slot
            // (audit #29) — the loop's own cancellation check next iteration
            // (or immediately, via the `continue`) ends the sweep the same way
            // a mid-scan cancellation always has.
            guard let result = await ProbeScheduler.shared.run({ await scan(host, port) }) else { continue }

            // Classify into an outcome string + (for a successful probe) the live key.
            let outcome: String
            var probe: HostKeyScanner.Probe?
            switch result {
            case .success(let p):
                probe = p
                switch VerifyOutcome(probe: p, group: group) {
                case .verified: outcome = "verified"
                case .changed: outcome = "changed"
                case .notStored: outcome = "newKey"
                case .failed: outcome = "unreachable"
                }
            case .failure:
                outcome = "unreachable"
            }

            records.append(
                AppDatabase.HostKeyCheckRecord(
                    groupID: group.id, hostTitle: group.title, displayName: group.displayName,
                    hostToken: group.hostToken, keyType: probe?.keyType ?? "",
                    fingerprint: probe?.fingerprint ?? "", serverOpenSSH: probe?.openSSH ?? "",
                    outcome: outcome, checkedAt: sweptAt))

            // Only changed / new-key outcomes raise an alert.
            guard let probe, outcome == "changed" || outcome == "newKey" else { continue }
            let id = "\(group.id)|\(probe.fingerprint)"
            fresh.append(
                HostKeyAlert(
                    id: id, groupID: group.id, hostTitle: group.title, displayName: group.displayName,
                    hostToken: group.hostToken, keyType: probe.keyType,
                    serverFingerprint: probe.fingerprint, serverOpenSSH: probe.openSSH,
                    kind: outcome == "changed" ? .changed : .newKey,
                    // Preserve the original detection time across sweeps so "just now" is honest.
                    detectedAt: previous[id]?.detectedAt ?? sweptAt))
        }

        lastCheck = sweptAt
        for r in records { latestCheckPerHost[r.groupID] = r }
        let appeared = fresh.filter { previous[$0.id] == nil }
        alerts = fresh

        if let database, !records.isEmpty {
            try? await database.recordHostKeyChecks(records)
        }
        if !appeared.isEmpty {
            Log.knownHosts.error("host-key sweep raised \(appeared.count, privacy: .public) new alert(s)")
            notify(appeared)
        }
    }

    // MARK: - Notifications

    private func notify(_ appeared: [HostKeyAlert]) {
        guard settings.hostKeyNotificationsEnabled else { return }
        // Test seam: a custom notifier short-circuits the real notification center.
        if let notifier {
            notifier(appeared)
            return
        }

        let mayRequest = !didRequestNotificationAuth
        if mayRequest { didRequestNotificationAuth = true }
        let payloads = appeared.map {
            NotificationPayload(title: Self.title(for: $0), body: Self.body(for: $0), groupID: $0.groupID)
        }
        Task { await Self.deliver(payloads, mayRequestAuthorization: mayRequest) }
    }

    private static func title(for alert: HostKeyAlert) -> String {
        switch alert.kind {
        case .changed: return "Host key changed"
        case .newKey: return "New host key offered"
        }
    }

    private static func body(for alert: HostKeyAlert) -> String {
        let name = alert.displayName == alert.hostTitle ? alert.hostTitle : "\(alert.displayName) (\(alert.hostTitle))"
        switch alert.kind {
        case .changed:
            return
                "\(name) is presenting a different \(alert.keyType) key than the one you trust. Review it before reconnecting."
        case .newKey:
            return "\(name) offered a \(alert.keyType) key that isn’t in your known_hosts."
        }
    }

    private struct NotificationPayload: Sendable {
        let title: String, body: String, groupID: String
    }

    /// The notification-category id whose tap routes to the Known Hosts screen (handled
    /// by the app's `UNUserNotificationCenterDelegate`).
    static let categoryIdentifier = "hostKeyChange"

    private static func deliver(_ payloads: [NotificationPayload], mayRequestAuthorization: Bool) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        let authorized: Bool
        switch status {
        case .authorized, .provisional: authorized = true
        case .notDetermined where mayRequestAuthorization:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: authorized = false
        }
        guard authorized else { return }
        for payload in payloads {
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            content.categoryIdentifier = categoryIdentifier
            content.userInfo = ["groupID": payload.groupID]
            try? await center.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
