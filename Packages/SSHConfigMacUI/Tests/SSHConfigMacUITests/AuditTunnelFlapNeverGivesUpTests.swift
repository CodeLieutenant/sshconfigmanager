//
//  AuditTunnelFlapNeverGivesUpTests.swift
//  sshconfigmanagerTests
//
//  AUDIT 2026-07-11 (docs/release/macos-bug-audit-2026-07-11.md, finding NET-2) — FIXED.
//  A connect -> immediate-drop flap used to reset the retry counter forever, so the
//  "gave up after 6 attempts" cap was unreachable. `TunnelStore.supervise` set
//  `becameActive = true` the instant the engine reported `.connected` (no minimum uptime)
//  and `if becameActive { attempt = 0 }` then zeroed the counter every cycle. A tunnel
//  that authenticated and was torn down each time (server closes right after auth, a
//  keepalive that fails on the first interval, a target that resets every session)
//  reconnected endlessly — hammering the server and, for interactive auth, re-prompting
//  for a password/2FA every ~1s. The supervisor now resets the backoff only after the
//  tunnel stays `.active` for `minStableUptimeToResetBackoff`; a sub-second flap no longer
//  qualifies, so a pure flap climbs to `giveUpAfter` and stops.
//
//  This is distinct from audit #19 (which stopped a PRE-auth `.active` report and made
//  exhausted-credential closes fatal); here the connection genuinely reaches `.connected`,
//  so #19's fatal classification never applies.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
private final class FlapEngine: TunnelEngine {
    var capabilities = TunnelEngineCapabilities(
        reportsLiveness: true, canStop: true, survivesAppQuit: false, reportsThroughput: false)
    private(set) var startCount = 0
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    func start(_ preset: TunnelPreset) throws { startCount += 1 }
    func stop(_ preset: TunnelPreset) {
        continuations[preset.id]?.finish()
        continuations[preset.id] = nil
    }
    func events(for preset: TunnelPreset) -> AsyncStream<EngineEvent>? {
        AsyncStream { continuation in continuations[preset.id] = continuation }
    }
    func throughput(for preset: TunnelPreset) -> TunnelThroughput? { nil }
    func emit(_ event: EngineEvent, to id: UUID) { continuations[id]?.yield(event) }
}

@MainActor
struct AuditTunnelFlapNeverGivesUpTests {
    private func poll(timeout: TimeInterval = 8, until condition: @MainActor () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
    private func isActive(_ s: TunnelStatus) -> Bool {
        if case .active = s { return true }
        return false
    }
    private func isFailed(_ s: TunnelStatus) -> Bool {
        if case .failed = s { return true }
        return false
    }

    @Test func immediateConnectDropFlapEventuallyGivesUp() async {
        // Keep each backoff ~1s (schedule is 1,2,5,15,cap s) so ~7 flap cycles run fast.
        let previousCap = AppSettings.shared.tunnelMaxBackoffSeconds
        AppSettings.shared.tunnelMaxBackoffSeconds = 1
        defer { AppSettings.shared.tunnelMaxBackoffSeconds = previousCap }

        let engine = FlapEngine()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-flap-\(UUID().uuidString).store")
        let store = TunnelStore(persistenceURL: url, engine: engine)
        let preset = TunnelPreset(
            name: "PG", hostAlias: "bastion", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
        store.add(preset)
        store.start(preset)

        // Each cycle: the engine restarts, briefly reports `.connected` (active), then
        // immediately drops — an uptime far under `minStableUptimeToResetBackoff` (30s),
        // so `attempt` is NOT reset and climbs toward the give-up cap. Drive cycles until
        // the supervisor fails (stops restarting), with a generous ceiling as a backstop.
        var cycles = 0
        while cycles < 12 {
            let advanced = await poll {
                engine.startCount == cycles + 1 || self.isFailed(store.status(for: preset.id))
            }
            #expect(advanced)
            if isFailed(store.status(for: preset.id)) { break }
            cycles += 1
            engine.emit(.connected, to: preset.id)
            #expect(await poll { self.isActive(store.status(for: preset.id)) })
            engine.emit(.closed(reason: "Connection lost."), to: preset.id)
            #expect(await poll { !self.isActive(store.status(for: preset.id)) })
        }

        // FIXED: a pure connect->instant-drop flap now reaches the give-up cap instead of
        // reconnecting forever.
        #expect(await poll { self.isFailed(store.status(for: preset.id)) })
        if case .failed(let reason) = store.status(for: preset.id) {
            #expect(reason.contains("Gave up"))
        }
        // It gave up in a bounded number of cycles (giveUpAfter = 6, so ~7 starts), not
        // the "forever" of the pre-fix behavior.
        #expect(cycles <= 8)
        store.stop(preset.id)
    }
}
