//
//  ConfigHistoryStoreTests.swift
//  sshconfigmanagerTests
//
//  The SQLite-backed config version history: content-addressed storage (dedup),
//  the no-op guard, branching, non-destructive restore, oldest-first pruning with
//  blob GC, renaming, and the one-time legacy `.bak` migration. Each test gets its
//  own temp-file database, so nothing touches the real app database (per the
//  test-isolation convention).
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
struct ConfigHistoryStoreTests {
    private let cap = 100_000

    private func makeStore() -> (ConfigHistoryStore, AppDatabase) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-test-\(UUID().uuidString).store")
        let db = AppDatabase.testDatabase(at: url)
        return (ConfigHistoryStore(database: db), db)
    }

    // MARK: - Codec

    @Test func codecRoundTrips() {
        for sample in ["", "Host x\n  HostName y\n", String(repeating: "line\n", count: 5_000)] {
            let encoded = ConfigHistoryStore.encode(Data(sample.utf8))
            #expect(ConfigHistoryStore.decode(encoded) == sample)
        }
    }

    // MARK: - Commit / dedup / no-op

    @Test func unchangedFilesDedupeToOneBlob() async throws {
        let (history, db) = makeStore()
        await history.waitUntilLoaded()
        await history.commit(files: [("config", "A\n"), ("conf.d/x", "X\n")], source: .initial, maxVersions: cap)
        // Change only config; conf.d/x is byte-identical, so its blob is reused.
        await history.commit(files: [("config", "B\n"), ("conf.d/x", "X\n")], source: .autosave, maxVersions: cap)
        #expect(history.versions.count == 2)
        // Blobs A, X, B — X deduped across the two versions.
        #expect(try await db.blobCount() == 3)
    }

    @Test func identicalSnapshotIsNoOp() async {
        let (history, _) = makeStore()
        await history.waitUntilLoaded()
        await history.commit(files: [("config", "same\n")], source: .initial, maxVersions: cap)
        await history.commit(files: [("config", "same\n")], source: .autosave, maxVersions: cap)
        #expect(history.versions.count == 1)
    }

    @Test func diffStatsMatchTextDiff() async {
        let (history, _) = makeStore()
        await history.waitUntilLoaded()
        let old = "a\nb\nc\n"
        let new = "a\nB\nc\nd\n"
        await history.commit(files: [("config", old)], source: .initial, maxVersions: cap)
        await history.commit(files: [("config", new)], source: .autosave, maxVersions: cap)
        let newest = history.versions.first { $0.id == history.headID }!
        let expected = TextDiff.stat(old: old, new: new)
        #expect(newest.addedLines == expected.added)
        #expect(newest.removedLines == expected.removed)
        #expect(newest.filesChanged == 1)
    }

    // MARK: - Per-file browsing

    @Test func fileChangesReportsOnlyTouchedFiles() async {
        let (history, _) = makeStore()
        await history.waitUntilLoaded()
        await history.commit(files: [("config", "A\n"), ("conf.d/x", "X\n")], source: .initial, maxVersions: cap)
        // Second commit only edits "config"; "conf.d/x" is byte-identical.
        await history.commit(files: [("config", "B\n"), ("conf.d/x", "X\n")], source: .autosave, maxVersions: cap)
        let head = history.headID!
        let changes = await history.fileChanges(for: head)
        #expect(changes.map(\.relPath) == ["config"])
        #expect(changes.first?.kind == .modified)
    }

    @Test func fileChangesMarksAddedAndRemovedFiles() async {
        let (history, _) = makeStore()
        await history.waitUntilLoaded()
        await history.commit(files: [("config", "A\n")], source: .initial, maxVersions: cap)
        await history.commit(
            files: [("config", "A\n"), ("group.conf", "Host g\n")], source: .autosave, maxVersions: cap)
        let addedVersion = history.headID!
        let added = await history.fileChanges(for: addedVersion)
        #expect(added.count == 1)
        #expect(added.first?.relPath == "group.conf")
        #expect(added.first?.kind == .added)

        // Dropping "group.conf" from the tracked set (as a delete would) marks it removed.
        await history.commit(files: [("config", "A\n")], source: .autosave, maxVersions: cap)
        let removedVersion = history.headID!
        let removed = await history.fileChanges(for: removedVersion)
        #expect(removed.count == 1)
        #expect(removed.first?.relPath == "group.conf")
        #expect(removed.first?.kind == .removed)
    }

    @Test func fileTextReturnsPerFileContentAtEachVersion() async {
        let (history, _) = makeStore()
        await history.waitUntilLoaded()
        await history.commit(files: [("config", "A\n"), ("conf.d/x", "X1\n")], source: .initial, maxVersions: cap)
        let v1 = history.headID!
        await history.commit(files: [("config", "A\n"), ("conf.d/x", "X2\n")], source: .autosave, maxVersions: cap)
        let v2 = history.headID!

        #expect(await history.fileText("conf.d/x", at: v1) == "X1\n")
        #expect(await history.fileText("conf.d/x", at: v2) == "X2\n")
        #expect(await history.fileText("config", at: v2) == "A\n")
        // A file this version never tracked returns "".
        #expect(await history.fileText("nowhere.conf", at: v2) == "")
    }

    // MARK: - Restore / branching

    @Test func restoreMaterializesAndMovesHead() async throws {
        let (history, _) = makeStore()
        await history.waitUntilLoaded()
        await history.commit(files: [("config", "v1\n")], source: .initial, maxVersions: cap)
        let v1 = history.headID!
        await history.commit(files: [("config", "v2\n")], source: .autosave, maxVersions: cap)

        let restored = try await history.restore(to: v1)
        #expect(restored.count == 1)
        #expect(restored.first?.text == "v1\n")
        #expect(history.headID == v1)
    }

    @Test func editingAfterRestoreForksAndKeepsEverything() async throws {
        let (history, _) = makeStore()
        await history.waitUntilLoaded()
        await history.commit(files: [("config", "A\n")], source: .initial, maxVersions: cap)
        let a = history.headID!
        await history.commit(files: [("config", "B\n")], source: .autosave, maxVersions: cap)
        await history.commit(files: [("config", "C\n")], source: .autosave, maxVersions: cap)
        let c = history.headID!

        _ = try await history.restore(to: a)
        await history.commit(files: [("config", "D\n")], source: .autosave, maxVersions: cap)
        let d = history.versions.first { $0.id == history.headID }!

        #expect(d.parentID == a) // forked from A, not C
        #expect(history.versions.count == 4) // nothing discarded
        #expect(await history.reconstruct(c).first?.text == "C\n") // C still reconstructable
    }

    // MARK: - Pruning

    @Test func pruneDropsOldestKeepsHeadAndGCsBlobs() async throws {
        let (history, db) = makeStore()
        await history.waitUntilLoaded()
        let smallCap = 3
        for i in 1...6 {
            await history.commit(files: [("config", "ver\(i)\n")], source: .autosave, maxVersions: smallCap)
        }
        #expect(history.versions.count == 3)
        // The newest (HEAD) is never pruned and reconstructs exactly.
        #expect(await history.reconstruct(history.headID!).first?.text == "ver6\n")
        // Blobs were GC'd down to the three survivors.
        #expect(try await db.blobCount() == 3)
    }

    // MARK: - Rename / clear

    @Test func renamePersistsAndBlankClears() async {
        let (history, _) = makeStore()
        await history.waitUntilLoaded()
        await history.commit(files: [("config", "x\n")], source: .initial, maxVersions: cap)
        let id = history.headID!
        await history.rename(id, to: "Milestone")
        #expect(history.versions.first { $0.id == id }?.name == "Milestone")
        await history.rename(id, to: "   ")
        #expect(history.versions.first { $0.id == id }?.name == nil)
    }

    @Test func clearWipesEverything() async throws {
        let (history, db) = makeStore()
        await history.waitUntilLoaded()
        await history.commit(files: [("config", "x\n")], source: .initial, maxVersions: cap)
        await history.clearHistory()
        #expect(history.versions.isEmpty)
        #expect(history.headID == nil)
        #expect(try await db.blobCount() == 0)
    }

    // MARK: - Reload across instances

    @Test func headAndVersionsSurviveReopen() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-reopen-\(UUID().uuidString).store")
        let first = ConfigHistoryStore(database: AppDatabase.testDatabase(at: url))
        await first.waitUntilLoaded()
        await first.commit(files: [("config", "one\n")], source: .initial, maxVersions: cap)
        await first.commit(files: [("config", "two\n")], source: .autosave, maxVersions: cap)
        let head = first.headID

        let reopened = ConfigHistoryStore(database: AppDatabase.testDatabase(at: url))
        await reopened.waitUntilLoaded()
        #expect(reopened.versions.count == 2)
        #expect(reopened.headID == head)
    }

    // MARK: - Legacy migration (ConfigStore level)

    @Test func migrationImportsLegacyBackupsThenBaseline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-mig-\(UUID().uuidString)", isDirectory: true)
        let backupDir = dir.appendingPathComponent(".sshmanager-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Host current\n".write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host old1\n".write(
            to: backupDir.appendingPathComponent("config.20250101-120000.bak"),
            atomically: true, encoding: .utf8)
        try "Host old2\n".write(
            to: backupDir.appendingPathComponent("config.20250102-120000.bak"),
            atomically: true, encoding: .utf8)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-mig-\(UUID().uuidString).store")
        let history = ConfigHistoryStore(database: AppDatabase.testDatabase(at: url))
        let store = ConfigStore(
            settings: AppSettings(database: nil),
            passphraseStore: FakePassphraseStore([:]), history: history)
        store.useDirectoryForTesting(dir)
        store.reload()
        await store.runHistoryLaunchForTesting()

        // Two imported backups (oldest→newest) + the current baseline.
        #expect(history.versions.count == 3)
        #expect(await history.reconstruct(history.versions.last!.id).first?.text == "Host old1\n")
        #expect(await history.reconstruct(history.headID!).first?.text == "Host current\n")
    }

    /// Restoring must fully replace the tree: a group file extracted after the
    /// target version was recorded isn't in that version's manifest, so it should be
    /// deleted from disk — and its now-dangling sidebar entry pruned — not left behind
    /// as an orphan overlaid onto the restored state.
    @Test func restoreVersionDeletesGroupFileNotInTargetManifestAndPrunesGroup() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Host main\n  HostName m\n".write(
            to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-restore-\(UUID().uuidString).store")
        let history = ConfigHistoryStore(database: AppDatabase.testDatabase(at: url))
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings, passphraseStore: FakePassphraseStore([:]), history: history)
        store.useDirectoryForTesting(dir)
        store.reload()
        await store.runHistoryLaunchForTesting()
        let baselineID = try #require(history.headID)

        let groupID = try #require(store.createFileBackedGroup(name: "Staging", fileName: "staging.conf"))
        store.flushPendingSave()
        await history.waitForPendingWrites()
        let groupFileURL = try #require(store.groups.first { $0.id == groupID }?.fileURL)
        #expect(FileManager.default.fileExists(atPath: groupFileURL.path))

        await store.restoreVersionForTesting(baselineID)

        #expect(!FileManager.default.fileExists(atPath: groupFileURL.path))
        #expect(!store.groups.contains { $0.id == groupID })
        #expect(store.documents.count == 1)
    }

    /// `snapshotNow` is the explicit "before I make a risky change" checkpoint
    /// (`ConfigVersionSource.manual`, previously unused) — it should record every
    /// tracked file and, when given a name, apply it to the resulting HEAD.
    @Test func snapshotNowRecordsManualVersionWithName() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Host main\n  HostName m\n".write(
            to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-snap-\(UUID().uuidString).store")
        let history = ConfigHistoryStore(database: AppDatabase.testDatabase(at: url))
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings, passphraseStore: FakePassphraseStore([:]), history: history)
        store.useDirectoryForTesting(dir)
        store.reload()
        await store.runHistoryLaunchForTesting()
        let beforeCount = history.versions.count

        await store.snapshotNowForTesting(name: "Checkpoint")

        // Nothing changed since the baseline, so no duplicate version — the name
        // lands on the existing HEAD instead.
        #expect(history.versions.count == beforeCount)
        #expect(history.versions.first { $0.id == history.headID }?.name == "Checkpoint")
    }
}
