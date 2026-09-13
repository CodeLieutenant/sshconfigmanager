//
//  TunnelSupervisionTests.swift
//  sshconfigmanagerTests
//
//  Drives `TunnelStore`'s supervisor (start → watch health → retry with backoff →
//  give up) through a fake liveness engine. The engine exposes an event stream the
//  test feeds by hand, so we can assert the store's reaction to connected/closed/
//  failed/log events deterministically — without a real SSH server. These cover
//  the supervision loop that the CRUD tests in TunnelTests.swift don't reach.
//

import Foundation
import SSHConfigCore
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

// MARK: - Fake engine

/// An engine that reports liveness via an event stream the test controls. Records
/// start/stop counts and can be told to throw from `start` or report throughput.
@MainActor
private final class FakeLivenessEngine: TunnelEngine {
    var capabilities = TunnelEngineCapabilities(
        reportsLiveness: true, canStop: true, survivesAppQuit: false, reportsThroughput: true)

    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    var throughputValue: TunnelThroughput?

    /// The live event-stream continuation for each preset id (the one `tickStream`
    /// is currently consuming). `events(for:)` is called more than once per attempt;
    /// the latest call wins, which is the stream the supervisor actually reads.
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    func start(_ preset: TunnelPreset) throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop(_ preset: TunnelPreset) {
        stopCount += 1
        continuations[preset.id]?.finish()
        continuations[preset.id] = nil
    }

    func events(for preset: TunnelPreset) -> AsyncStream<EngineEvent>? {
        AsyncStream { continuation in continuations[preset.id] = continuation }
    }

    func throughput(for preset: TunnelPreset) -> TunnelThroughput? { throughputValue }

    /// Feeds an event into the stream the supervisor is watching.
    func emit(_ event: EngineEvent, to id: UUID) { continuations[id]?.yield(event) }
}

// MARK: - Helpers

/// Spins the run loop until `condition` holds or `timeout` elapses. Returns the
/// final value of `condition` so callers can `#expect` on it. Sleeping yields to
/// the supervisor's @MainActor task so it can make progress between checks.
@MainActor
private func poll(
    timeout: TimeInterval = 3,
    until condition: @MainActor () -> Bool
) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - Supervision tests

@MainActor
struct TunnelSupervisionTests {
    private func makeStore(
        _ engine: FakeLivenessEngine,
        resolveChain: @escaping @MainActor (String) -> [TunnelHop]? = { _ in nil }
    ) -> TunnelStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-sup-\(UUID().uuidString).store")
        return TunnelStore(persistenceURL: url, engine: engine, resolveChain: resolveChain)
    }

    private func sample(autostart: Bool = false) -> TunnelPreset {
        TunnelPreset(
            name: "PG", hostAlias: "bastion", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)],
            autostart: autostart)
    }

    @Test func connectedEventDrivesActive() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.connected, to: p.id)
        #expect(await poll { isActive(store.status(for: p.id)) })
        store.stop(p.id)
    }

    @Test func logEventsLandInTheConsole() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.log(.info, "Connecting to bastion"), to: p.id)
        #expect(await poll { store.logEntries(for: p.id).contains { $0.message == "Connecting to bastion" } })
        store.stop(p.id)
    }

    @Test func authFailureIsFatalAndDoesNotRetry() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.failed(reason: "auth failed: bad key"), to: p.id)
        #expect(await poll { isFailed(store.status(for: p.id)) })
        // A fatal classification must not spin the retry loop.
        #expect(engine.startCount == 1)
    }

    /// Regression guard for audit #19's reason-propagation half. Before the fix,
    /// `SSHHopChainConnector` never reported *why* a hop's channel closed
    /// (`.closed(reason: nil)` always), so a genuinely-rejected connection could
    /// never be told apart from a transient drop — every cycle retried, ignoring
    /// the give-up cap entirely. `waitForAuthentication`'s close handler now emits
    /// this exact wording (`CompositeAuthDelegate.exhaustedAllMethods == true`)
    /// when the server rejected every offered credential; it must classify fatal.
    @Test func exhaustedCredentialsReasonIsFatal() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(
            .closed(
                reason: "Authentication failed for bastion:22 — the server "
                    + "rejected every offered credential."), to: p.id)
        #expect(await poll { isFailed(store.status(for: p.id)) })
        #expect(engine.startCount == 1)
    }

    /// Companion to `exhaustedCredentialsReasonIsFatal`: a pre-auth channel close
    /// that *isn't* attributable to exhausted credentials (e.g. a transient
    /// network drop mid-handshake) must stay retryable, not become fatal too.
    @Test func preAuthDropWithoutExhaustionStaysRetryable() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(
            .closed(
                reason: "Connection to bastion:22 closed before the SSH "
                    + "handshake finished."), to: p.id)
        #expect(
            await poll {
                if case .retrying = store.status(for: p.id) { return true }
                return false
            })
        store.stop(p.id)
    }

    @Test func failureNotifiesViaInjectedSeamWhenProAndEnabled() async {
        let previouslyEnabled = AppSettings.shared.tunnelNotificationsEnabled
        AppSettings.shared.tunnelNotificationsEnabled = true
        defer { AppSettings.shared.tunnelNotificationsEnabled = previouslyEnabled }

        let engine = FakeLivenessEngine()
        var delivered: [(title: String, body: String)] = []
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-sup-\(UUID().uuidString).store")
        let store = TunnelStore(
            persistenceURL: url, engine: engine,
            notifier: { title, body in delivered.append((title, body)) })
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.failed(reason: "auth failed: bad key"), to: p.id)
        #expect(await poll { isFailed(store.status(for: p.id)) })
        #expect(await poll { !delivered.isEmpty })
        #expect(delivered.first?.title == "Tunnel failed")
        #expect(delivered.first?.body.contains("auth failed: bad key") == true)
    }

    @Test func closedConnectionRetriesAndCanRecover() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.connected, to: p.id)
        #expect(await poll { isActive(store.status(for: p.id)) })

        // A retryable drop restarts the engine (backoff resets after an active run).
        engine.emit(.closed(reason: "Connection lost."), to: p.id)
        #expect(await poll(timeout: 5) { engine.startCount == 2 })
        #expect(isRetrying(store.status(for: p.id)) || isActive(store.status(for: p.id)))

        // Reconnecting brings it back to active (the recovery transition).
        engine.emit(.connected, to: p.id)
        #expect(await poll { isActive(store.status(for: p.id)) })
        store.stop(p.id)
    }

    @Test func stopWhileActiveStaysStoppedAndDoesNotRetry() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.connected, to: p.id)
        #expect(await poll { isActive(store.status(for: p.id)) })

        // Stopping mid-connection cancels the supervisor; `engine.stop` finishes the
        // event stream, so `runConnection` returns a synthetic `.down`. The supervisor
        // must observe the cancellation and NOT fall through to the retry block — the
        // status has to settle on `.stopped` and the engine must not restart.
        store.stop(p.id)
        #expect(store.status(for: p.id) == .stopped)
        // Give the cancelled supervisor ample time to (incorrectly) restart or flip to
        // `.retrying`; it must do neither.
        let flipped = await poll(timeout: 1) {
            store.status(for: p.id) != .stopped || engine.startCount != 1
        }
        #expect(!flipped)
        #expect(store.status(for: p.id) == .stopped)
        #expect(engine.startCount == 1)
    }

    @Test func engineStartThrowsMarksFailed() async {
        let engine = FakeLivenessEngine()
        engine.startError = TunnelEngineError.launchFailed("no route")
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { isFailed(store.status(for: p.id)) })
        #expect(engine.startCount == 1) // threw before any watch
    }

    @Test func throughputIsPublishedWhileActive() async {
        let engine = FakeLivenessEngine()
        engine.throughputValue = TunnelThroughput(bytesIn: 2048, bytesOut: 1024)
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.connected, to: p.id)
        #expect(await poll { store.throughput[p.id] != nil })
        #expect(store.throughput[p.id]?.bytesIn == 2048)
        store.stop(p.id)
        #expect(store.throughput[p.id] == nil) // cleared on stop
    }

    @Test func deleteStopsRunningTunnelAndClearsState() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.connected, to: p.id)
        #expect(await poll { isActive(store.status(for: p.id)) })

        store.delete(p.id)
        #expect(store.presets.isEmpty)
        #expect(store.status(for: p.id) == .stopped)
        #expect(store.logEntries(for: p.id).isEmpty)
        #expect(engine.stopCount >= 1)
    }

    @Test func toggleStartsThenStops() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.toggle(p)
        #expect(await poll { store.status(for: p.id).isRunning })
        store.toggle(p)
        #expect(store.status(for: p.id) == .stopped)
    }

    @Test func runningPresetsReflectsLiveTunnels() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let a = sample()
        let b = TunnelPreset(
            name: "redis", hostAlias: "bastion", mode: .local,
            mappings: [PortMapping(listenPort: 6379, targetHost: "cache", targetPort: 6379)])
        store.add(a)
        store.add(b)
        store.start(a)
        #expect(await poll { store.runningPresets.contains { $0.id == a.id } })
        #expect(!store.runningPresets.contains { $0.id == b.id })
        store.stop(a.id)
    }

    @Test func externalConfigChangeRestartsRunningTunnel() async {
        let engine = FakeLivenessEngine()
        var user = "rocky"
        let store = makeStore(engine, resolveChain: { _ in [TunnelHop(host: "10.0.0.1", port: 22, user: user)] })
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.connected, to: p.id)
        #expect(await poll { isActive(store.status(for: p.id)) })

        user = "deploy"
        store.restartTunnelsWithChangedConfig()

        #expect(await poll { engine.startCount == 2 })
        #expect(store.logEntries(for: p.id).contains { $0.message.contains("Host configuration changed") })
        store.stop(p.id)
    }

    /// The flip side: a reload that didn't touch this tunnel's hops must not tear
    /// down a healthy connection. Reloads fire on every app activation, so a
    /// too-eager comparison would drop the link every time the window regains focus.
    @Test func unchangedConfigLeavesRunningTunnelAlone() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine, resolveChain: { _ in [TunnelHop(host: "10.0.0.1", port: 22, user: "rocky")] })
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.connected, to: p.id)
        #expect(await poll { isActive(store.status(for: p.id)) })

        // The chain resolves identically — nothing on the wire changed.
        store.restartTunnelsWithChangedConfig()
        #expect(engine.startCount == 1)
        #expect(isActive(store.status(for: p.id)))
        store.stop(p.id)
    }

    /// "Reconnecting (try 2)" on its own is the complaint: the status says a tunnel
    /// is retrying and never says what went wrong. The reason has to outlive the
    /// attempt that produced it.
    @Test func failureReasonSurvivesIntoTheRetryingState() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.closed(reason: "Couldn't reach 10.0.0.1:22 — Connection refused"), to: p.id)

        #expect(await poll { isRetrying(store.status(for: p.id)) })
        #expect(store.failureReason(for: p.id) == "Couldn't reach 10.0.0.1:22 — Connection refused")
        store.stop(p.id)
    }

    /// …and must not linger once the tunnel is healthy again, or the UI shows a
    /// stale error under a working connection.
    @Test func failureReasonClearsOnRecovery() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.closed(reason: "Connection reset by peer"), to: p.id)
        #expect(await poll { store.failureReason(for: p.id) != nil })

        #expect(await poll(timeout: 5) { engine.startCount == 2 })
        engine.emit(.connected, to: p.id)
        #expect(await poll { isActive(store.status(for: p.id)) })
        #expect(store.failureReason(for: p.id) == nil)
        store.stop(p.id)
    }

    /// A deliberate stop isn't a failure — it must not leave an error behind.
    @Test func stoppingLeavesNoFailureReason() async {
        let engine = FakeLivenessEngine()
        let store = makeStore(engine)
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(await poll { engine.startCount == 1 })
        engine.emit(.connected, to: p.id)
        #expect(await poll { isActive(store.status(for: p.id)) })
        store.stop(p.id)
        #expect(store.failureReason(for: p.id) == nil)
    }

    @Test func autostartTunnelsStartAfterLoad() async {
        let engine = FakeLivenessEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-autostart-\(UUID().uuidString).store")
        let store = TunnelStore(persistenceURL: url, engine: engine)
        await store.waitUntilLoaded()
        let p = sample(autostart: true)
        store.add(p)
        store.restoreAutostartTunnels()
        #expect(await poll { engine.startCount >= 1 })
        store.stop(p.id)
    }
}

// MARK: - Status shape helpers

private func isActive(_ status: TunnelStatus) -> Bool {
    if case .active = status { return true }
    return false
}
private func isFailed(_ status: TunnelStatus) -> Bool {
    if case .failed = status { return true }
    return false
}
private func isRetrying(_ status: TunnelStatus) -> Bool {
    if case .retrying = status { return true }
    return false
}
