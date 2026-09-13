//
//  SpotlightReindexOnEditTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for audit #24: `ConfigStore` used to only call
//  `SpotlightIndexer.reindex` from `reload()` (an external change or relaunch),
//  so an in-app add/rename/delete left the Spotlight index stale until then.
//  `ConfigStore.spotlightIndexer` (a `SpotlightIndexing` seam) lets these tests
//  assert the reindex happens right after a save, without touching the real
//  CoreSpotlight index.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

/// Records reindex calls (and the alias set at each call) instead of touching
/// the real CoreSpotlight index.
@MainActor
private final class FakeSpotlightIndexing: SpotlightIndexing {
    private(set) var reindexedAliasSets: [[String]] = []
    private(set) var deleteAllCallCount = 0

    func reindex(_ hosts: [HostBlock]) {
        reindexedAliasSets.append(hosts.compactMap(\.primaryAlias).sorted())
    }

    func deleteAll() { deleteAllCallCount += 1 }

    /// Clears recorded calls from `store.reload()`'s initial seed, so a test can
    /// assert only on what an in-app edit triggers afterward.
    func forgetCallsSoFar() { reindexedAliasSets.removeAll() }
}

@MainActor
struct SpotlightReindexOnEditTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshspotlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func autosaveOffStore() -> ConfigStore {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        return ConfigStore(settings: settings)
    }

    @Test func addingAHostReindexesOnSave() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Host alpha\n    HostName a\n".write(
            to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let store = autosaveOffStore()
        let fake = FakeSpotlightIndexing()
        store.spotlightIndexer = fake
        store.useDirectoryForTesting(dir)
        store.reload()
        // `reload()` seeds the index once — the regression is specifically about
        // in-app edits *after* that not reindexing, so reset the recorder here.
        fake.forgetCallsSoFar()

        store.addHost()
        #expect(fake.reindexedAliasSets.isEmpty, "must not reindex before the edit is saved")

        store.flushPendingSave()
        #expect(fake.reindexedAliasSets.count == 1, "must reindex exactly once per saved edit")
        #expect(fake.reindexedAliasSets.last?.contains(where: { $0.hasPrefix("new-host") }) == true)
    }

    @Test func deletingAHostReindexesWithoutTheStaleAlias() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Host alpha\n    HostName a\n\nHost beta\n    HostName b\n".write(
            to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let store = autosaveOffStore()
        let fake = FakeSpotlightIndexing()
        store.spotlightIndexer = fake
        store.useDirectoryForTesting(dir)
        store.reload()
        fake.forgetCallsSoFar()

        guard let beta = store.documents[0].blocks.first(where: { $0.patterns == ["beta"] }) else {
            Issue.record("expected a beta host block")
            return
        }
        store.deleteBlock(id: beta.id)
        store.flushPendingSave()

        #expect(
            fake.reindexedAliasSets.last == ["alpha"],
            "the deleted host's stale alias must not linger in the next reindex")
    }

    @Test func editsThatDontChangeAnythingOnDiskDontReindex() throws {
        // `writeDirtyDocuments` no-ops when nothing was actually dirty — reindex
        // must follow the same guard, not fire on every autosave tick regardless.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Host alpha\n    HostName a\n".write(
            to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let store = autosaveOffStore()
        let fake = FakeSpotlightIndexing()
        store.spotlightIndexer = fake
        store.useDirectoryForTesting(dir)
        store.reload()
        fake.forgetCallsSoFar()

        store.flushPendingSave() // nothing dirty
        #expect(fake.reindexedAliasSets.isEmpty)
    }
}
