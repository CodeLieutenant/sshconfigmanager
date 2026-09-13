//
//  SettingsTests.swift
//  sshconfigmanagerTests
//
//  Coverage for AppSettings persisting through the shared SQLite database.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
struct AppSettingsTests {
    private func makeDatabase() -> AppDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-test-\(UUID().uuidString).store")
        return AppDatabase.testDatabase(at: url)
    }

    @Test func settingsPersistAcrossInstances() async {
        let database = makeDatabase()
        let settings = AppSettings(database: database)
        await settings.waitUntilLoaded()
        settings.autosaveEnabled = false
        settings.tunnelNotificationsEnabled = true
        await settings.waitForPendingWrites()

        let reopened = AppSettings(database: database)
        await reopened.waitUntilLoaded()
        #expect(reopened.autosaveEnabled == false)
        #expect(reopened.tunnelNotificationsEnabled == true)
        #expect(reopened.showMenuBarExtra == true) // untouched → default
    }

    @Test func defaultsApplyForAFreshDatabase() async {
        let settings = AppSettings(database: makeDatabase())
        await settings.waitUntilLoaded()
        #expect(settings.autosaveEnabled == true)
        #expect(settings.showMenuBarExtra == true)
        #expect(settings.tunnelNotificationsEnabled == false)
    }
}

@MainActor
struct AppDatabaseConcurrencyTests {
    /// Reproduces the launch race: a fresh `AppDatabase` (schema not yet created)
    /// hit by two operations at once — as `AppSettings` and `TunnelStore` do on
    /// launch — must not let either fail or return empty.
    @Test func concurrentFirstAccessLoadsBoth() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-race-\(UUID().uuidString).store")

        // Seed the file (its own actor instance), then close it out.
        let seed = AppDatabase.testDatabase(at: url)
        try await seed.replaceAll([
            TunnelPreset(
                name: "PG", hostAlias: "bastion", mode: .local,
                mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
        ])
        try await seed.setSetting("autosaveEnabled", "0")

        // Fresh actor = a new process where schema setup hasn't run yet.
        let database = AppDatabase.testDatabase(at: url)
        async let tunnels = database.load()
        async let settings = database.loadSettings()
        let (loadedTunnels, loadedSettings) = try await (tunnels, settings)

        #expect(loadedTunnels.count == 1)
        #expect(loadedTunnels.first?.hostAlias == "bastion")
        #expect(loadedSettings["autosaveEnabled"] == "0")
    }

    /// Reproduces the launch ordering: TunnelStore and AppSettings both load
    /// asynchronously against the same shared database at once. The tunnel load
    /// must complete with all presets.
    @Test func tunnelLoadSurvivesConcurrentSettingsLoadAtLaunch() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-launch-\(UUID().uuidString).store")
        let shared = AppDatabase.testDatabase(at: url)

        // Seed two tunnels through a separate store, fully flushed.
        let seeder = TunnelStore(database: shared, legacyJSONURL: nil, engine: nil)
        await seeder.waitUntilLoaded()
        seeder.add(TunnelPreset(name: "A", hostAlias: "h1", mode: .dynamic, mappings: [PortMapping(listenPort: 1080)]))
        seeder.add(TunnelPreset(name: "B", hostAlias: "h2", mode: .dynamic, mappings: [PortMapping(listenPort: 1081)]))
        await seeder.waitForPendingWrites()

        // Launch order: store first (schedules async load), then settings blocks main.
        let store = TunnelStore(database: shared, legacyJSONURL: nil, engine: nil)
        _ = AppSettings(database: shared) // synchronous, blocks the main thread
        await store.waitUntilLoaded()
        #expect(store.presets.count == 2)
    }
}
