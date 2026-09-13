//
//  TunnelRestartRaceTests.swift
//  sshconfigmanagerTests
//
//  Reproducer: a cancelled supervisor tore down the tunnel that replaced it.
//
//  `stop(_:)` cancels a supervisor Task but cannot make it stop *immediately* — the
//  cancellation lands inside `await runConnection(...)`, and the task only resumes on
//  a later @MainActor hop. `restartRunningTunnels(for:)` (called whenever a host field
//  is edited while its tunnel is up) does `stop(id)` then `start(preset)`
//  synchronously, so the replacement supervisor is already running by then.
//
//  The old code's cleanup ran regardless: `engine.stop(preset)` twice plus
//  `throughput[id] = nil`, on the SAME shared engine instance the new attempt is using.
//  So the outgoing supervisor stopped the incoming tunnel, whose event stream then died
//  and dropped it into "Reconnecting…".
//
//  The deterministic assertion is the engine's stop count, not a status: it is three
//  (one legitimate, two stale) with the bug and one after the fix, whichever order the
//  two tasks happen to be scheduled in.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

/// Records the exact order of engine calls so a teardown arriving after a restart is
/// visible, and finishes the event stream on `stop` the way a real engine does.
@MainActor
private final class RecordingEngine: TunnelEngine {
    var capabilities = TunnelEngineCapabilities(
        reportsLiveness: true, canStop: true, survivesAppQuit: false, reportsThroughput: true)

    enum Call: Equatable { case start, stop }
    private(set) var calls: [Call] = []
    var startCount: Int { calls.filter { $0 == .start }.count }
    var stopCount: Int { calls.filter { $0 == .stop }.count }

    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    func start(_ preset: TunnelPreset) throws { calls.append(.start) }

    func stop(_ preset: TunnelPreset) {
        calls.append(.stop)
        continuations[preset.id]?.finish()
        continuations[preset.id] = nil
    }

    func events(for preset: TunnelPreset) -> AsyncStream<EngineEvent>? {
        AsyncStream { continuation in continuations[preset.id] = continuation }
    }

    func throughput(for preset: TunnelPreset) -> TunnelThroughput? { nil }

    func emit(_ event: EngineEvent, to id: UUID) { continuations[id]?.yield(event) }
    /// Whether a live event stream is currently registered — i.e. whether the attempt
    /// the supervisor is watching can still receive events.
    func hasLiveStream(_ id: UUID) -> Bool { continuations[id] != nil }
}

@MainActor
private func poll(timeout: TimeInterval = 3, until condition: @MainActor () -> Bool) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
struct TunnelRestartRaceTests {
    private func makeStore(_ engine: RecordingEngine) -> TunnelStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-race-\(UUID().uuidString).store")
        return TunnelStore(persistenceURL: url, engine: engine)
    }

    private func sample() -> TunnelPreset {
        TunnelPreset(
            name: "PG", hostAlias: "bastion", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
    }

    /// Brings a tunnel up and leaves it `.active`.
    private func startActive(
        _ store: TunnelStore, _ engine: RecordingEngine, _ preset: TunnelPreset
    ) async {
        store.start(preset)
        _ = await poll { engine.hasLiveStream(preset.id) }
        engine.emit(.connected, to: preset.id)
        _ = await poll { if case .active = store.status(for: preset.id) { return true } else { return false } }
    }

    // MARK: - The race

    /// A restart must produce exactly ONE engine stop. Three means the cancelled
    /// supervisor ran its teardown on top of the replacement's.
    @Test func restartStopsTheEngineExactlyOnce() async {
        let engine = RecordingEngine()
        let store = makeStore(engine)
        let preset = sample()
        store.add(preset)
        await startActive(store, engine, preset)
        #expect(engine.stopCount == 0, "nothing stopped it yet")

        store.restartRunningTunnels(for: "bastion")
        // Let the replacement start, then give the cancelled supervisor every chance to
        // resume and run the teardown it should no longer be running.
        _ = await poll { engine.startCount == 2 }
        try? await Task.sleep(for: .milliseconds(200))

        #expect(engine.startCount == 2, "the tunnel must be started again")
        #expect(
            engine.stopCount == 1,
            "expected one stop (from `stop(_:)`); extra stops are the cancelled supervisor tearing down the attempt that replaced it — calls: \(engine.calls)"
        )
    }

    /// The user-visible consequence: after a restart the new attempt's event stream must
    /// still be live, so `.connected` reaches the supervisor and the tunnel gets back to
    /// `.active`. The stale teardown finished that stream instead.
    ///
    /// Kept as an invariant pin, NOT as a detector — it depends on the stale teardown
    /// landing *after* the replacement registered its stream, and with the bug in place
    /// it happened to land before, so this passed. `restartStopsTheEngineExactlyOnce` is
    /// the assertion that catches the regression whatever the scheduling order.
    @Test func restartedTunnelReachesActiveAgain() async {
        let engine = RecordingEngine()
        let store = makeStore(engine)
        let preset = sample()
        store.add(preset)
        await startActive(store, engine, preset)

        store.restartRunningTunnels(for: "bastion")
        _ = await poll { engine.startCount == 2 }
        try? await Task.sleep(for: .milliseconds(200))

        #expect(engine.hasLiveStream(preset.id), "the replacement attempt's event stream must survive")
        engine.emit(.connected, to: preset.id)
        let active = await poll {
            if case .active = store.status(for: preset.id) { return true } else { return false }
        }
        #expect(active, "status after restart: \(store.status(for: preset.id).label)")
    }

    /// The same teardown ran on a plain user stop, where it was merely redundant —
    /// `stop(_:)` had already stopped the engine. Pinned so the fix can't be undone by
    /// "restoring" the cleanup.
    @Test func plainStopStopsTheEngineExactlyOnce() async {
        let engine = RecordingEngine()
        let store = makeStore(engine)
        let preset = sample()
        store.add(preset)
        await startActive(store, engine, preset)

        store.stop(preset.id)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(engine.stopCount == 1, "calls: \(engine.calls)")
        #expect(store.status(for: preset.id) == .stopped)
    }

    /// A stop must stay stopped: the cancelled supervisor must not fall through to the
    /// retry block and overwrite `.stopped` with `.retrying`. This one already held — the
    /// pre-existing `if Task.isCancelled` check covered it — and is pinned so moving that
    /// check (which the fix does) can't quietly regress it.
    @Test func stoppedTunnelDoesNotResurrectAsRetrying() async {
        let engine = RecordingEngine()
        let store = makeStore(engine)
        let preset = sample()
        store.add(preset)
        await startActive(store, engine, preset)

        store.stop(preset.id)
        try? await Task.sleep(for: .milliseconds(250))

        #expect(store.status(for: preset.id) == .stopped)
        #expect(engine.startCount == 1, "a stopped tunnel must not be started again")
    }
}
