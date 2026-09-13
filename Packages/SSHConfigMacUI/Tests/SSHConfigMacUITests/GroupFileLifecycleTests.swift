//
//  GroupFileLifecycleTests.swift
//  sshconfigmanagerTests
//
//  File-backed groups: auto-discovery of existing Includes/tags, creating and
//  extracting groups to a real file, cross-file drag-and-drop, and — the part
//  that most needed to be right — deleting a file-backed group being fully
//  undoable (file, hosts, and the group row all come back together, and redo
//  re-deletes all three).
//

import Foundation
import SSHConfigCore
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

@MainActor
struct GroupFileLifecycleTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshgroups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Matches `StoreIntegrationTests.autosaveOffStore()` — a private, autosave-off,
    /// database-less store so group/version-history persistence never touches real
    /// state and explicit save/undo assertions aren't raced by background writes.
    private func autosaveOffStore() -> ConfigStore {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        return ConfigStore(settings: settings)
    }

    // MARK: - Auto-discovery

    @Test func autoDiscoveryCreatesGroupForExistingInclude() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Include work.conf\n\nHost main\n    HostName m\n", to: dir.appendingPathComponent("config"))
        try write("Host prod-db\n    HostName db.example.com\n", to: dir.appendingPathComponent("work.conf"))

        let store = autosaveOffStore()
        await store.waitForGroupsLoadedForTesting()
        store.useDirectoryForTesting(dir)
        store.reload()

        let group = try #require(store.groups.first { $0.isFileBacked })
        #expect(group.name == "Work")
        #expect(
            store.allHostBlocks.first { $0.patterns == ["prod-db"] }?.sourceURL
                == dir.appendingPathComponent("work.conf"))
    }

    @Test func autoDiscoveryCreatesGroupForOrphanTag() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Host alpha\n    HostName a\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        await store.waitForGroupsLoadedForTesting()
        store.useDirectoryForTesting(dir)
        store.reload()
        let alpha = try #require(store.allHostBlocks.first { $0.patterns == ["alpha"] })
        store.setTags(["group/legacy"], for: alpha)

        store.reload() // re-scans tags; no disk change, but still runs auto-discovery
        #expect(store.groups.contains { $0.name == "legacy" && !$0.isFileBacked })
    }

    // MARK: - Creating a file-backed group

    @Test func createFileBackedGroupWritesFileAndInclude() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Host main\n    HostName m\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        let id = try #require(store.createFileBackedGroup(name: "Staging", fileName: "staging.conf"))
        store.flushPendingSave()

        let group = try #require(store.group(id: id))
        #expect(group.filePath == dir.appendingPathComponent("ssh-config-manager.d/staging.conf").path)
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("ssh-config-manager.d/staging.conf").path))
        let configOnDisk = try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
        // A file inside the default groups directory is covered by one shared glob
        // Include, not a per-file one — see `insertIncludeDirective`.
        #expect(configOnDisk.contains("Include ~/") || configOnDisk.contains("ssh-config-manager.d/*.conf"))
    }

    /// The shared default-directory glob Include is added once and reused across
    /// every group extracted into that directory — never one line per file.
    @Test func multipleDefaultDirectoryGroupsShareOneGlobInclude() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Host main\n    HostName m\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        _ = try #require(store.createFileBackedGroup(name: "Staging", fileName: "staging.conf"))
        _ = try #require(store.createFileBackedGroup(name: "Prod", fileName: "prod.conf"))
        store.flushPendingSave()

        let configOnDisk = try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
        let includeLines = configOnDisk.components(separatedBy: .newlines).filter {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("include")
        }
        #expect(includeLines.count == 1, "both groups' files must be covered by one shared glob Include")
        #expect(includeLines.first?.contains("ssh-config-manager.d/*.conf") == true)
    }

    /// A directory the user explicitly picked (not the app's default groups
    /// directory) isn't assumed to be dedicated to this app's files, so it still
    /// gets a literal per-file Include rather than a directory-wide glob.
    @Test func customDirectoryGroupGetsLiteralInclude() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let customDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: customDir) }
        try write("Host main\n    HostName m\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.useAdditionalDirectoryForTesting(customDir)
        store.reload()

        _ = try #require(store.createFileBackedGroup(name: "Shared", fileName: "shared.conf", in: customDir))
        store.flushPendingSave()

        let configOnDisk = try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
        #expect(configOnDisk.contains("shared.conf"), "custom directory must get its own literal Include")
        #expect(!configOnDisk.contains("*.conf"), "custom directory must not use the default-dir glob")
    }

    // MARK: - Extracting a virtual group to file

    @Test func extractGroupToFileMovesMembersLosslessly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(
            "Host alpha\n    HostName a\n\n# pinned bastion\nHost beta\n    HostName b\n",
            to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        let groupID = store.createGroup()
        let alpha = try #require(store.allHostBlocks.first { $0.patterns == ["alpha"] })
        let beta = try #require(store.allHostBlocks.first { $0.patterns == ["beta"] })
        let group = try #require(store.group(id: groupID))
        store.assignToGroup(blockID: alpha.id, group: group)
        store.assignToGroup(blockID: beta.id, group: group)

        store.extractGroupToFile(groupID, fileName: "extracted.conf")
        store.flushPendingSave()

        let targetURL = dir.appendingPathComponent("ssh-config-manager.d/extracted.conf")
        #expect(store.group(id: groupID)?.filePath == targetURL.path)
        let onDisk = try String(contentsOf: targetURL, encoding: .utf8)
        #expect(onDisk.contains("Host alpha"))
        #expect(onDisk.contains("# pinned bastion"), "leading comment must travel with its host")
        #expect(onDisk.contains("Host beta"))
        // Both moved out of the main config.
        #expect(!(try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)).contains("Host alpha"))
    }

    // MARK: - Deleting a file-backed group: the undo-correctness case

    @Test func deleteFileBackedGroupIsFullyUndoableAndRedoable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Host main\n    HostName m\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.useDirectoryForTesting(dir)
        store.reload()

        let groupID = try #require(store.createFileBackedGroup(name: "Prod", fileName: "prod.conf"))
        let fileURL = try #require(store.group(id: groupID)?.fileURL)
        store.flushPendingSave()
        let hostID = try #require(store.addHost(to: fileURL))
        store.flushPendingSave()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        undo.removeAllActions()

        store.deleteGroup(groupID)
        store.flushPendingSave()
        #expect(store.group(id: groupID) == nil, "group row must be gone")
        #expect(store.block(id: hostID) == nil, "the group's host must be gone")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path), "the file must be deleted from disk")

        undo.undo()
        store.flushPendingSave()
        #expect(store.group(id: groupID) != nil, "undo must restore the group row")
        #expect(store.block(id: hostID) != nil, "undo must restore the host")
        #expect(FileManager.default.fileExists(atPath: fileURL.path), "undo must restore the file on disk")

        undo.redo()
        store.flushPendingSave()
        #expect(store.group(id: groupID) == nil, "redo must re-delete the group row")
        #expect(store.block(id: hostID) == nil, "redo must re-delete the host")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path), "redo must re-delete the file from disk")
    }

    /// `deleteGroup` must flush its physical delete immediately rather than leaving
    /// it in the normal ~700ms autosave debounce. `reload()` unconditionally discards
    /// any still-pending delete (see its doc comment) — if a reload races in first
    /// (an external-change check, a crash, a force-quit before the debounce fires),
    /// the file is still on disk and auto-discovery resurrects the group right back.
    /// This reproduces that race directly: delete with no explicit flush, then reload.
    @Test func deleteFileBackedGroupSurvivesAnImmediateReload() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Host main\n    HostName m\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        let groupID = try #require(store.createFileBackedGroup(name: "Staging", fileName: "staging.conf"))
        let fileURL = try #require(store.group(id: groupID)?.fileURL)
        store.flushPendingSave()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        store.deleteGroup(groupID) // no explicit flushPendingSave() here — race repro
        store.reload()

        #expect(
            !FileManager.default.fileExists(atPath: fileURL.path),
            "the file must actually be deleted from disk, not just scheduled")
        #expect(store.group(id: groupID) == nil, "the group row must stay gone")
        #expect(
            store.groups.first(where: { $0.name == "Staging" }) == nil,
            "auto-discovery must not resurrect the group from a leftover file")
    }

    @Test func deleteVirtualGroupKeepsHostButClearsTag() throws {
        let store = autosaveOffStore()
        store.loadForTesting([
            SSHConfigParser.parse(
                "Host alpha\n    HostName a\n", sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        let alpha = store.documents[0].blocks[0]
        let groupID = store.createGroup()
        store.assignToGroup(blockID: alpha.id, group: try #require(store.group(id: groupID)))
        #expect(store.isInGroup(alpha))

        store.deleteGroup(groupID)

        #expect(store.group(id: groupID) == nil)
        #expect(store.block(id: alpha.id) != nil, "host must survive deleting a virtual group")
        #expect(!store.isInGroup(store.block(id: alpha.id)!))
    }

    // MARK: - Cross-file drag-and-drop between two file-backed groups

    @Test func assignToGroupMovesBlockAcrossFileBackedGroups() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Host main\n    HostName m\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        let groupAID = try #require(store.createFileBackedGroup(name: "A", fileName: "a.conf"))
        let groupBID = try #require(store.createFileBackedGroup(name: "B", fileName: "b.conf"))
        let fileA = try #require(store.group(id: groupAID)?.fileURL)
        let fileB = try #require(store.group(id: groupBID)?.fileURL)
        let hostID = try #require(store.addHost(to: fileA))

        #expect(store.block(id: hostID)?.sourceURL == fileA)

        store.assignToGroup(blockID: hostID, group: try #require(store.group(id: groupBID)))

        #expect(store.block(id: hostID)?.sourceURL == fileB, "host must physically move to group B's file")
        #expect(
            GroupResolver.currentGroup(
                for: store.block(id: hostID)!, groups: store.groups,
                tags: store.tags(for: store.block(id: hostID)!))?.id == groupBID)
    }

    // MARK: - Renaming a file-backed group never touches its file

    @Test func renameFileBackedGroupDoesNotChangeFilePath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Host main\n    HostName m\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()
        let groupID = try #require(store.createFileBackedGroup(name: "Prod", fileName: "prod.conf"))
        let originalPath = store.group(id: groupID)?.filePath

        store.renameGroup(groupID, to: "Production")

        #expect(store.group(id: groupID)?.name == "Production")
        #expect(store.group(id: groupID)?.filePath == originalPath)
    }
}

extension GroupFileLifecycleTests {
    @Test func nestedIncludesAreFollowedRecursively() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Include work.conf\n\nHost main\n    HostName m\n", to: dir.appendingPathComponent("config"))
        try write("Include nested.conf\n\nHost work\n    HostName w\n", to: dir.appendingPathComponent("work.conf"))
        try write("Host deep\n    HostName d\n", to: dir.appendingPathComponent("nested.conf"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        #expect(store.documents.count == 3, "main + work.conf + nested.conf must all load")
        #expect(
            store.allHostBlocks.map { $0.title }.sorted() == ["deep", "main", "work"],
            "hosts inside a doubly-nested Include must be parsed and shown")
    }
}

extension GroupFileLifecycleTests {
    /// An `Include` pointing at a real, ordinary directory that was never granted
    /// (no symlink involved at all) used to be silently dropped with zero
    /// indication — the only recoverable case was a symlink escape specifically.
    /// Now it must queue the same "Grant Access" prompt a symlink escape does.
    @Test func ungrantedPlainIncludeQueuesGrantAccessPrompt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        try write("Host outside-host\n    HostName o\n", to: outside.appendingPathComponent("extra.conf"))
        try write(
            "Include \(outside.path)/extra.conf\n\nHost main\n    HostName m\n",
            to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        #expect(
            !store.allHostBlocks.contains { $0.patterns == ["outside-host"] },
            "still can't read it without a grant, but that's not the point of this test")
        let pending = try #require(store.pendingSymlinkAccessRequest)
        #expect(pending.symlinkTarget?.path == outside.appendingPathComponent("extra.conf").path)
    }

    // MARK: - Pruning orphaned groups on reload (the external-change counterpart
    // to auto-discovery's additions)

    /// If a file-backed group's backing file disappears outside the app — deleted
    /// directly, or by a script the file watcher's external-change reload then
    /// picks up — the group row must not dangle forever. `performGroupAutoDiscovery`
    /// only ever adds; `pruneOrphanedFileBackedGroups` is the removal half, run from
    /// the same `reload()`.
    @Test func reloadPrunesGroupWhoseFileWasDeletedExternally() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Host main\n    HostName m\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        await store.waitForGroupsLoadedForTesting()
        store.useDirectoryForTesting(dir)
        store.reload()

        let groupID = try #require(store.createFileBackedGroup(name: "Staging", fileName: "staging.conf"))
        store.flushPendingSave()
        #expect(store.group(id: groupID) != nil)

        // External deletion, bypassing the app entirely — the shared directory
        // glob Include still resolves fine to zero matches once the file is gone.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("ssh-config-manager.d/staging.conf"))

        store.reload()

        #expect(store.group(id: groupID) == nil, "the dangling group row must be pruned")
    }

    /// A group whose file is untouched must survive a reload — pruning only fires
    /// for a backing file that's genuinely gone, never as a side effect of an
    /// unrelated reload.
    @Test func reloadKeepsGroupWhoseFileStillExists() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Host main\n    HostName m\n", to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        await store.waitForGroupsLoadedForTesting()
        store.useDirectoryForTesting(dir)
        store.reload()

        let groupID = try #require(store.createFileBackedGroup(name: "Staging", fileName: "staging.conf"))
        store.flushPendingSave()

        store.reload()

        #expect(store.group(id: groupID) != nil)
    }

    /// Virtual (tag-based) groups aren't tied to a document at all, so they must
    /// never be pruned regardless of what happens on disk.
    @Test func reloadNeverPrunesVirtualGroups() async throws {
        let store = autosaveOffStore()
        await store.waitForGroupsLoadedForTesting()
        store.loadForTesting([
            SSHConfigParser.parse(
                "Host alpha\n    HostName a\n", sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        let alpha = store.documents[0].blocks[0]
        let groupID = store.createGroup()
        store.assignToGroup(blockID: alpha.id, group: try #require(store.group(id: groupID)))

        store.reload()

        #expect(store.group(id: groupID) != nil, "a virtual group must never be pruned")
    }

    /// One bad write (e.g. a symlinked/ungranted file) must not block every other
    /// pending file from being saved, and must not get stuck retrying forever.
    @Test func oneFailingWriteDoesNotBlockOtherFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let confd = dir.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: confd, withIntermediateDirectories: true)
        try write("Include conf.d/*.conf\n\nHost main\n    HostName m\n", to: dir.appendingPathComponent("config"))
        try write("Host work\n    HostName w\n", to: confd.appendingPathComponent("work.conf"))

        let store = ConfigStore(settings: AppSettings(database: nil))
        store.useDirectoryForTesting(dir)
        store.reload()

        let main = try #require(store.allHostBlocks.first { $0.patterns == ["main"] })
        let work = try #require(store.allHostBlocks.first { $0.patterns == ["work"] })
        // Simulate work.conf becoming unwritable mid-session (e.g. its underlying
        // symlink target was revoked) while a totally unrelated edit to main is
        // also pending — both would previously fail together.
        store.updateBlock(id: work.id, undoable: false) { $0.setValue("w2", for: "HostName") }
        try FileManager.default.removeItem(at: confd.appendingPathComponent("work.conf"))
        try FileManager.default.removeItem(at: confd)
        store.updateBlock(id: main.id, undoable: false) { $0.setValue("m2", for: "HostName") }

        store.flushPendingSave()

        let mainOnDisk = try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
        #expect(mainOnDisk.contains("m2"), "main's edit must be saved even though work.conf's write failed")
    }
}
