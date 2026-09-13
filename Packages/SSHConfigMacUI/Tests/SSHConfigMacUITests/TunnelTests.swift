//
//  TunnelTests.swift
//  sshconfigmanagerTests
//
//  Coverage for the tunneling feature: the pure command builder, the health
//  reducer's state machine, the port-mapping model, and the store's CRUD +
//  persistence. The engine/monitor side effects (Terminal launch, live probing)
//  are out of scope for unit tests.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

// MARK: - Command builder (pure)

struct TunnelCommandBuilderTests {
    private func preset(
        _ mode: TunnelMode, _ mappings: [PortMapping],
        alias: String = "bastion"
    ) -> TunnelPreset {
        TunnelPreset(hostAlias: alias, mode: mode, mappings: mappings)
    }

    @Test func localForwardBuildsExpectedArgv() {
        let p = preset(.local, [PortMapping(listenPort: 5432, targetHost: "localhost", targetPort: 5432)])
        #expect(
            TunnelCommandBuilder.arguments(for: p)
                == ["ssh", "-N", "-T", "-o", "ControlPath=none", "-L", "5432:localhost:5432", "bastion"])
    }

    @Test func remoteForwardUsesDashR() {
        let p = preset(.remote, [PortMapping(listenPort: 8080, targetHost: "localhost", targetPort: 3000)])
        #expect(TunnelCommandBuilder.arguments(for: p).contains("-R"))
        #expect(
            TunnelCommandBuilder.commandString(for: p) == "ssh -N -T -o ControlPath=none -R 8080:localhost:3000 bastion"
        )
    }

    @Test func dynamicForwardOmitsTarget() {
        let p = preset(.dynamic, [PortMapping(listenPort: 1080)])
        #expect(TunnelCommandBuilder.commandString(for: p) == "ssh -N -T -o ControlPath=none -D 1080 bastion")
    }

    @Test func baseArgvIsStableNoDuplicateOptions() {
        // SSH config governs compression/keepAlive/exitOnForwardFailure; the
        // builder emits only the fixed scaffold + forwards + alias.
        let p = preset(.local, [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
        #expect(
            TunnelCommandBuilder.arguments(for: p) == [
                "ssh", "-N", "-T", "-o", "ControlPath=none",
                "-L", "5432:db:5432", "bastion",
            ])
    }

    @Test func multipleMappingsEachGetAFlag() {
        let p = preset(
            .local,
            [
                PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432),
                PortMapping(listenPort: 6379, targetHost: "cache", targetPort: 6379),
            ])
        let args = TunnelCommandBuilder.arguments(for: p)
        #expect(args.filter { $0 == "-L" }.count == 2)
        #expect(args.contains("6379:cache:6379"))
    }

    @Test func bindAddressIsIncluded() {
        let p = preset(
            .local,
            [
                PortMapping(
                    bindAddress: "127.0.0.1", listenPort: 5432,
                    targetHost: "db", targetPort: 5432)
            ])
        #expect(TunnelCommandBuilder.arguments(for: p).contains("127.0.0.1:5432:db:5432"))
    }

    @Test func shellQuotingProtectsSpecialCharacters() {
        #expect(TunnelCommandBuilder.shellQuoted("bastion") == "bastion")
        #expect(TunnelCommandBuilder.shellQuoted("~/.ssh/id_ed25519") == "~/.ssh/id_ed25519")
        #expect(TunnelCommandBuilder.shellQuoted("host with space") == "'host with space'")
        #expect(TunnelCommandBuilder.shellQuoted("a;rm -rf b") == "'a;rm -rf b'")
        #expect(TunnelCommandBuilder.shellQuoted("it's") == "'it'\\''s'")
        #expect(TunnelCommandBuilder.shellQuoted("") == "''")
    }

    @Test func aliasWithSpaceIsQuotedInCommandString() {
        let p = preset(.dynamic, [PortMapping(listenPort: 1080)], alias: "weird alias")
        #expect(TunnelCommandBuilder.commandString(for: p) == "ssh -N -T -o ControlPath=none -D 1080 'weird alias'")
    }
}

// MARK: - PortMapping / preset validation

struct TunnelModelTests {
    @Test func localMappingNeedsTargetAndPorts() {
        #expect(PortMapping(listenPort: 22, targetHost: "h", targetPort: 80).isValid(for: .local))
        #expect(!PortMapping(listenPort: 0, targetHost: "h", targetPort: 80).isValid(for: .local))
        #expect(!PortMapping(listenPort: 22, targetHost: "", targetPort: 80).isValid(for: .local))
        #expect(!PortMapping(listenPort: 22, targetHost: "h", targetPort: 0).isValid(for: .local))
    }

    @Test func dynamicMappingNeedsOnlyListenPort() {
        #expect(PortMapping(listenPort: 1080).isValid(for: .dynamic))
        #expect(!PortMapping(listenPort: 70000).isValid(for: .dynamic))
    }

    @Test func presetValidityRequiresAliasAndValidMappings() {
        #expect(
            TunnelPreset(
                hostAlias: "bastion", mode: .dynamic,
                mappings: [PortMapping(listenPort: 1080)]
            ).isValid)
        #expect(
            !TunnelPreset(
                hostAlias: "", mode: .dynamic,
                mappings: [PortMapping(listenPort: 1080)]
            ).isValid)
        #expect(!TunnelPreset(hostAlias: "bastion", mode: .local, mappings: []).isValid)
    }

    @Test func localProbePortOnlyForLocallyListeningModes() {
        let local = TunnelPreset(
            hostAlias: "b", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
        #expect(local.localProbePort == 5432)
        let remote = TunnelPreset(
            hostAlias: "b", mode: .remote,
            mappings: [PortMapping(listenPort: 8080, targetHost: "localhost", targetPort: 3000)])
        #expect(remote.localProbePort == nil)
        let dynamic = TunnelPreset(hostAlias: "b", mode: .dynamic, mappings: [PortMapping(listenPort: 1080)])
        #expect(dynamic.localProbePort == 1080)
    }

    @Test func forwardDirectivesMapModeToSSHConfig() {
        let local = TunnelPreset(
            hostAlias: "b", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "localhost", targetPort: 5432)])
        #expect(local.forwardDirectives.map(\.keyword) == ["LocalForward"])
        #expect(local.forwardDirectives.first?.value == "5432 localhost:5432")

        let dynamic = TunnelPreset(hostAlias: "b", mode: .dynamic, mappings: [PortMapping(listenPort: 1080)])
        #expect(dynamic.forwardDirectives.first?.keyword == "DynamicForward")
        #expect(dynamic.forwardDirectives.first?.value == "1080")

        let remote = TunnelPreset(
            hostAlias: "b", mode: .remote,
            mappings: [
                PortMapping(
                    bindAddress: "127.0.0.1", listenPort: 8080,
                    targetHost: "localhost", targetPort: 3000)
            ])
        #expect(remote.forwardDirectives.first?.keyword == "RemoteForward")
        #expect(remote.forwardDirectives.first?.value == "127.0.0.1:8080 localhost:3000")
    }

    @Test func parsingRoundTripsForwardDirectivesBackIntoMappings() {
        let localValue = TunnelPreset(
            hostAlias: "b", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db.internal", targetPort: 5432)]
        )
        .forwardDirectives.first!.value
        let local = PortMapping.parsing(localValue, mode: .local)
        #expect(local?.bindAddress == "")
        #expect(local?.listenPort == 5432)
        #expect(local?.targetHost == "db.internal")
        #expect(local?.targetPort == 5432)

        let remoteValue = TunnelPreset(
            hostAlias: "b", mode: .remote,
            mappings: [
                PortMapping(
                    bindAddress: "127.0.0.1", listenPort: 8080,
                    targetHost: "localhost", targetPort: 3000)
            ]
        )
        .forwardDirectives.first!.value
        let remote = PortMapping.parsing(remoteValue, mode: .remote)
        #expect(remote?.bindAddress == "127.0.0.1")
        #expect(remote?.listenPort == 8080)
        #expect(remote?.targetHost == "localhost")
        #expect(remote?.targetPort == 3000)

        let dynamicValue = TunnelPreset(hostAlias: "b", mode: .dynamic, mappings: [PortMapping(listenPort: 1080)])
            .forwardDirectives.first!.value
        let dynamic = PortMapping.parsing(dynamicValue, mode: .dynamic)
        #expect(dynamic?.bindAddress == "")
        #expect(dynamic?.listenPort == 1080)
    }

    @Test func parsingHandlesBracketedIPv6BindAndTarget() {
        let mapping = PortMapping.parsing("[::1]:5432 [2001:db8::1]:5432", mode: .local)
        #expect(mapping?.bindAddress == "::1")
        #expect(mapping?.listenPort == 5432)
        #expect(mapping?.targetHost == "2001:db8::1")
        #expect(mapping?.targetPort == 5432)
    }

    @Test func parsingRejectsMalformedValues() {
        #expect(PortMapping.parsing("not-a-port db:5432", mode: .local) == nil)
        #expect(PortMapping.parsing("5432", mode: .local) == nil) // missing target
        #expect(PortMapping.parsing("5432 db:5432", mode: .dynamic) == nil) // dynamic takes one token
        #expect(PortMapping.parsing("5432 db", mode: .local) == nil) // target missing port
    }

    @Test func displayNameFallsBackToForwardSpec() {
        let p = TunnelPreset(
            hostAlias: "b", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
        #expect(p.displayName == "-L 5432:db:5432")
        var named = p
        named.name = "  Postgres  "
        #expect(named.displayName == "Postgres")
    }

    @Test func throughputSummaryShowsBothDirections() {
        let tp = TunnelThroughput(bytesIn: 1_500_000, bytesOut: 0)
        #expect(tp.summary.contains("↓"))
        #expect(tp.summary.contains("↑"))
        #expect(tp.summary.contains("MB")) // 1.5 MB in, formatted via .byteCount(.file)
    }
}

// MARK: - Health reducer (state machine)

struct TunnelHealthTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func reachableProbeGoesActive() {
        var health = TunnelHealth()
        let next = health.apply(.reachable(milliseconds: 4), to: .starting, now: t0)
        #expect(next == .active(since: t0))
    }

    @Test func activeKeepsOriginalSinceWhileReachable() {
        var health = TunnelHealth()
        let active = TunnelStatus.active(since: t0)
        let next = health.apply(.reachable(milliseconds: 4), to: active, now: t0.addingTimeInterval(30))
        #expect(next == active) // uptime keeps counting from the original time
    }

    @Test func singleMissDoesNotFlap() {
        var health = TunnelHealth(degradeAfter: 2, giveUpAfter: 6)
        let active = TunnelStatus.active(since: t0)
        #expect(health.apply(.timedOut, to: active, now: t0) == active)
    }

    @Test func consecutiveMissesDegradeThenFail() {
        var health = TunnelHealth(degradeAfter: 2, giveUpAfter: 4)
        var state = TunnelStatus.active(since: t0)
        state = health.apply(.unreachable, to: state, now: t0) // 1 — tolerated
        #expect(state == .active(since: t0))
        state = health.apply(.unreachable, to: state, now: t0) // 2 — degraded
        #expect(state == .degraded)
        state = health.apply(.unreachable, to: state, now: t0) // 3 — still degraded
        #expect(state == .degraded)
        state = health.apply(.unreachable, to: state, now: t0) // 4 — failed
        if case .failed = state {} else { Issue.record("expected failed, got \(state)") }
    }

    @Test func recoveryResetsFailureCount() {
        var health = TunnelHealth(degradeAfter: 2, giveUpAfter: 4)
        var state = TunnelStatus.active(since: t0)
        state = health.apply(.unreachable, to: state, now: t0)
        state = health.apply(.unreachable, to: state, now: t0)
        #expect(state == .degraded)
        state = health.apply(.reachable(milliseconds: 5), to: state, now: t0.addingTimeInterval(10))
        #expect(state == .active(since: t0.addingTimeInterval(10)))
        // After recovery, it again tolerates a single miss.
        #expect(health.apply(.timedOut, to: state, now: t0) == state)
    }
}

// MARK: - Store CRUD + persistence

@MainActor
struct TunnelStoreTests {
    /// A store backed by a fresh temp SQLite file and a no-op engine.
    private func makeStore() -> (TunnelStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-test-\(UUID().uuidString).store")
        return (TunnelStore(persistenceURL: url, engine: NoopEngine()), url)
    }

    private func sample() -> TunnelPreset {
        TunnelPreset(
            name: "PG", hostAlias: "bastion", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
    }

    @Test func addUpdateDeleteRoundTrips() {
        let (store, _) = makeStore()
        var p = sample()
        store.add(p)
        #expect(store.presets(for: "bastion").count == 1)

        p.name = "Postgres"
        store.update(p)
        #expect(store.presets.first?.name == "Postgres")

        store.delete(p.id)
        #expect(store.presets.isEmpty)
    }

    @Test func presetsPersistAcrossInstances() async {
        let (store, url) = makeStore()
        await store.waitUntilLoaded()
        store.add(sample())
        await store.waitForPendingWrites()
        // A second store reading the same database should see it.
        let reopened = TunnelStore(persistenceURL: url, engine: NoopEngine())
        await reopened.waitUntilLoaded()
        #expect(reopened.presets.count == 1)
        #expect(reopened.presets.first?.hostAlias == "bastion")
    }

    @Test func startMarksRunningStopMarksStopped() {
        let (store, _) = makeStore()
        let p = sample()
        store.add(p)
        store.start(p)
        #expect(store.status(for: p.id).isRunning)
        store.stop(p.id)
        #expect(store.status(for: p.id) == .stopped)
    }

    @Test func startingInvalidPresetReportsError() {
        let (store, _) = makeStore()
        let invalid = TunnelPreset(hostAlias: "bastion", mode: .local, mappings: [])
        store.add(invalid)
        store.start(invalid)
        #expect(store.errorMessage != nil)
        #expect(!store.status(for: invalid.id).isRunning)
    }

    @Test func renameHostAliasMigratesOnlyMatchingPresets() {
        let (store, _) = makeStore()
        store.add(
            TunnelPreset(
                name: "a", hostAlias: "bastion", mode: .dynamic,
                mappings: [PortMapping(listenPort: 1080)]))
        store.add(
            TunnelPreset(
                name: "b", hostAlias: "other", mode: .dynamic,
                mappings: [PortMapping(listenPort: 1081)]))

        store.renameHostAlias(from: "bastion", to: "jump-host")
        #expect(store.presets(for: "jump-host").count == 1)
        #expect(store.presets(for: "bastion").isEmpty)
        #expect(store.presets(for: "other").count == 1) // untouched
    }

    @Test func renameHostAliasIgnoresEmptyOrUnchanged() {
        let (store, _) = makeStore()
        store.add(sample()) // hostAlias "bastion"
        store.renameHostAlias(from: "bastion", to: "bastion") // no change
        store.renameHostAlias(from: "", to: "x") // empty old
        store.renameHostAlias(from: "bastion", to: "") // empty new
        #expect(store.presets(for: "bastion").count == 1)
    }

    /// A running tunnel must reconnect after a config edit (HostName, Port, …) so it
    /// picks up the change instead of continuing to talk to whatever it dialled
    /// before — the propagation gap reported for editing a Host's IP address.
    @Test func restartRunningTunnelsCyclesOnlyRunningMatchingPresets() {
        let (store, _) = makeStore()
        let running = TunnelPreset(
            name: "a", hostAlias: "bastion", mode: .dynamic,
            mappings: [PortMapping(listenPort: 1080)])
        let stopped = TunnelPreset(
            name: "b", hostAlias: "bastion", mode: .dynamic,
            mappings: [PortMapping(listenPort: 1081)])
        let other = TunnelPreset(
            name: "c", hostAlias: "other", mode: .dynamic,
            mappings: [PortMapping(listenPort: 1082)])
        store.add(running)
        store.add(stopped)
        store.add(other)
        store.start(running)
        store.start(other)
        #expect(store.status(for: running.id).isRunning)
        #expect(!store.status(for: stopped.id).isRunning)

        let logCountBefore = store.logEntries(for: running.id).count
        let otherLogCountBefore = store.logEntries(for: other.id).count
        store.restartRunningTunnels(for: "bastion")

        // The running "bastion" tunnel cycled through stop → start (two logged
        // status transitions) and came back up; the stopped one and the tunnel on
        // another host were left untouched.
        #expect(store.logEntries(for: running.id).count == logCountBefore + 2)
        #expect(store.status(for: running.id).isRunning)
        #expect(!store.status(for: stopped.id).isRunning)
        #expect(store.logEntries(for: other.id).count == otherLogCountBefore)
    }

    @Test func restartRunningTunnelsIgnoresEmptyAlias() {
        let (store, _) = makeStore()
        store.add(sample())
        store.start(store.presets[0])
        let logCountBefore = store.logEntries(for: store.presets[0].id).count
        store.restartRunningTunnels(for: "")
        #expect(store.logEntries(for: store.presets[0].id).count == logCountBefore)
    }

    /// A preset whose `hostAlias` no longer appears among the reload's aliases
    /// (an external rename/removal `ConfigStore.reload()` couldn't safely
    /// auto-migrate — see `reconcileOrphanedPresets`'s doc comment) must be flagged,
    /// not silently left looking healthy.
    @Test func reconcileOrphanedPresetsFlagsPresetWhoseHostDisappeared() {
        let (store, _) = makeStore()
        let preset = sample() // hostAlias == "bastion"
        store.add(preset)
        #expect(!store.isOrphaned(preset))

        store.reconcileOrphanedPresets(validHostAliases: ["other-host"])
        #expect(store.isOrphaned(preset))
    }

    /// Once the alias reappears (the rename was reverted, or it was a transient
    /// reload mid-edit), the flag clears — this isn't a one-way "broken" marker.
    @Test func reconcileOrphanedPresetsClearsFlagWhenHostReappears() {
        let (store, _) = makeStore()
        let preset = sample()
        store.add(preset)
        store.reconcileOrphanedPresets(validHostAliases: [])
        #expect(store.isOrphaned(preset))

        store.reconcileOrphanedPresets(validHostAliases: [preset.hostAlias])
        #expect(!store.isOrphaned(preset))
    }

    @Test func reconcileOrphanedPresetsLeavesMatchingPresetsAlone() {
        let (store, _) = makeStore()
        let preset = sample()
        store.add(preset)
        store.reconcileOrphanedPresets(validHostAliases: [preset.hostAlias, "another-host"])
        #expect(!store.isOrphaned(preset))
    }

    /// Deleting an orphaned preset must also drop its orphan flag — otherwise a
    /// later preset that reuses the same (freed, then recycled) UUID would show up
    /// as orphaned before `reconcileOrphanedPresets` ever ran for it. UUIDs aren't
    /// actually reused, but the flag should still track the preset's lifetime, not
    /// outlive it.
    @Test func deletingAnOrphanedPresetClearsItsFlag() {
        let (store, _) = makeStore()
        let preset = sample()
        store.add(preset)
        store.reconcileOrphanedPresets(validHostAliases: [])
        #expect(store.isOrphaned(preset))

        store.delete(preset.id)
        store.reconcileOrphanedPresets(validHostAliases: [preset.hostAlias])
        #expect(!store.isOrphaned(preset))
    }

    @Test func importsLegacyJSONOnFirstRun() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("tunnels.store")
        let jsonURL = dir.appendingPathComponent("tunnels.json")
        try JSONEncoder().encode([sample()]).write(to: jsonURL)

        let store = TunnelStore(databaseURL: dbURL, legacyJSONURL: jsonURL, engine: NoopEngine())
        await store.waitUntilLoaded()
        #expect(store.presets.count == 1)
        #expect(store.presets.first?.hostAlias == "bastion")
        // The JSON is archived so it isn't re-imported next launch.
        #expect(!FileManager.default.fileExists(atPath: jsonURL.path))

        // A fresh store reads from SQLite (no JSON now) and still sees it.
        let reopened = TunnelStore(databaseURL: dbURL, legacyJSONURL: jsonURL, engine: NoopEngine())
        await reopened.waitUntilLoaded()
        #expect(reopened.presets.count == 1)
    }

    @Test func renameHostAliasPersists() async {
        let (store, url) = makeStore()
        await store.waitUntilLoaded()
        store.add(sample())
        store.renameHostAlias(from: "bastion", to: "jump-host")
        await store.waitForPendingWrites()
        let reopened = TunnelStore(persistenceURL: url, engine: NoopEngine())
        await reopened.waitUntilLoaded()
        #expect(reopened.presets.first?.hostAlias == "jump-host")
    }

}

// MARK: - Writing forward directives into the config

@MainActor
struct TunnelConfigWriteTests {
    @Test func writesForwardDirectiveIntoMatchingHostWithoutDuplicating() {
        // Autosave off via injected settings (no background writes, no shared state).
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings)
        store.loadForTesting([
            SSHConfigParser.parse(
                "Host web\n    HostName w.example.com\n", sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])

        #expect(store.writeForwardDirectives([("LocalForward", "5432 localhost:5432")], toHostAlias: "web"))
        let block = store.allHostBlocks.first { $0.patterns.first == "web" }
        #expect(block?.values(for: "LocalForward") == ["5432 localhost:5432"])

        // Idempotent: writing the identical line again doesn't duplicate it.
        _ = store.writeForwardDirectives([("LocalForward", "5432 localhost:5432")], toHostAlias: "web")
        #expect(
            store.allHostBlocks.first { $0.patterns.first == "web" }?
                .values(for: "LocalForward") == ["5432 localhost:5432"])

        // Unknown alias → no-op, returns false.
        #expect(!store.writeForwardDirectives([("LocalForward", "x")], toHostAlias: "nope"))
    }

    private func storeWithConfig(_ text: String) -> ConfigStore {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings)
        store.loadForTesting([SSHConfigParser.parse(text, sourceURL: URL(fileURLWithPath: "/tmp/config"))])
        return store
    }

    @Test func importForwardsFromConfigParsesMatchingDirective() {
        let store = storeWithConfig("Host web\n    HostName w.example.com\n    LocalForward 5432 db.internal:5432\n")
        let preset = TunnelPreset(hostAlias: "web", mode: .local, mappings: [PortMapping()])
        let imported = store.importForwardsFromConfig(into: preset)
        #expect(imported?.count == 2) // the blank default mapping + the imported one
        #expect(imported?.last?.targetHost == "db.internal")
        #expect(imported?.last?.targetPort == 5432)
    }

    @Test func importForwardsFromConfigSkipsDirectivesForAnotherMode() {
        let store = storeWithConfig("Host web\n    HostName w.example.com\n    RemoteForward 8080 localhost:3000\n")
        let preset = TunnelPreset(hostAlias: "web", mode: .local, mappings: [])
        #expect(store.importForwardsFromConfig(into: preset) == nil)
    }

    @Test func importForwardsFromConfigReturnsNilWhenNothingNewToAdd() {
        let store = storeWithConfig("Host web\n    HostName w.example.com\n    LocalForward 5432 db.internal:5432\n")
        let preset = TunnelPreset(
            hostAlias: "web", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db.internal", targetPort: 5432)])
        #expect(store.importForwardsFromConfig(into: preset) == nil)
    }
}

/// Test engine that records calls without touching Terminal or the clipboard.
@MainActor
private final class NoopEngine: TunnelEngine {
    let capabilities = TunnelEngineCapabilities(reportsLiveness: false, canStop: true, survivesAppQuit: false)
    func start(_ preset: TunnelPreset) throws {
        if !preset.isValid { throw TunnelEngineError.invalidPreset }
    }
    func stop(_ preset: TunnelPreset) {}
}
