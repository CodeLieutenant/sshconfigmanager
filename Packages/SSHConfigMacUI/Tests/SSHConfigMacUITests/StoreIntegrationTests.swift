//
//  StoreIntegrationTests.swift
//  sshconfigmanagerTests
//
//  End-to-end ConfigStore behavior against a real temp directory: multi-file
//  Include loading, saving to disk, external-change detection, raw-edit replace,
//  undo/redo, and the search filters behind the sidebar and menu bar.
//

import Foundation
import SSHConfigCore
import SSHConfigServices
import SwiftUI
import Testing

@testable import SSHConfigMacUI

@MainActor
struct StoreIntegrationTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func order(_ store: ConfigStore, _ index: Int = 0) -> [String] {
        store.documents[index].blocks.map { $0.patterns.joined(separator: " ") }
    }

    /// A ConfigStore wired to a private, autosave-off `AppSettings` so explicit
    /// save/undo assertions aren't raced by background autosave writes — and
    /// nothing touches the shared `AppSettings` (or legacy UserDefaults) that
    /// other parallel suites read.
    private func autosaveOffStore() -> ConfigStore {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        return ConfigStore(settings: settings)
    }

    private let threeHosts =
        "Host alpha\n    HostName a\n\nHost beta\n    HostName b\n\nHost gamma\n    HostName c\n"

    // MARK: - Include loading

    @Test func reloadLoadsMainConfigAndIncludedFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let confd = dir.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: confd, withIntermediateDirectories: true)
        try write(
            "Include conf.d/*.conf\n\nHost main\n    HostName m\n",
            to: dir.appendingPathComponent("config"))
        try write("Host work\n    HostName w\n", to: confd.appendingPathComponent("work.conf"))

        let store = ConfigStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        #expect(store.documents.count == 2)
        #expect(store.documents[0].displayName == "config")
        #expect(store.documents[0].blocks.contains { $0.patterns == ["main"] })
        #expect(store.documents[1].blocks.contains { $0.patterns == ["work"] })
        #expect(store.filteredGroups.count == 2)
    }

    // MARK: - Saving to disk

    @Test func saveWritesReorderedConfig() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        try write(threeHosts, to: configURL)

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()
        store.moveBlocks(in: configURL, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        store.flushPendingSave()

        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        let reparsed = SSHConfigParser.parse(onDisk, sourceURL: configURL)
        #expect(reparsed.blocks.map { $0.patterns.joined() } == ["gamma", "alpha", "beta"])
        // Config writes no longer leave legacy `.bak` files — the version history is
        // the backup now, so the hidden backups folder isn't created on save.
        #expect(
            !FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(".sshmanager-backups").path))
        #expect(!store.isDirty)
    }

    // MARK: - External change detection

    @Test func externalChangeReloadsWhenNotDirty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        try write("Host a\n    HostName a\n", to: configURL)

        let store = ConfigStore()
        store.useDirectoryForTesting(dir)
        store.reload()
        #expect(store.allHostBlocks.count == 1)

        // Simulate another program editing the file, with a clearly newer timestamp.
        try write("Host a\n    HostName a\n\nHost b\n    HostName b\n", to: configURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: configURL.path)

        store.checkForExternalChanges()
        #expect(store.allHostBlocks.map { $0.title }.sorted() == ["a", "b"])
    }

    // MARK: - Raw-edit replace

    @Test func replaceBlockFromRawUpdatesTheBlock() {
        let store = ConfigStore()
        store.loadForTesting([
            SSHConfigParser.parse(
                "Host a\n    HostName a\n",
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        let id = store.documents[0].blocks[0].id
        let ok = store.replaceBlockFromRaw(
            id: id, rawText: "Host a\n    HostName changed.example\n    Port 2200\n")
        #expect(ok)
        #expect(store.block(id: id)?.firstValue(for: "HostName") == "changed.example")
        #expect(store.block(id: id)?.firstValue(for: "Port") == "2200")
    }

    @Test func replaceBlockFromRawRejectsMultipleBlocks() {
        let store = ConfigStore()
        store.loadForTesting([
            SSHConfigParser.parse(
                "Host a\n",
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        let id = store.documents[0].blocks[0].id
        let ok = store.replaceBlockFromRaw(id: id, rawText: "Host a\nHost b\n")
        #expect(!ok)
        #expect(store.documents[0].blocks.count == 1)
    }

    // MARK: - Undo / redo

    @Test func undoAndRedoRestoreStructuralEdits() {
        let store = autosaveOffStore()
        // groupsByEvent stays true (the production default): registerUndo auto-opens
        // a group, and undo()/redo() close and process it.
        let undo = UndoManager()
        store.undoManager = undo
        store.loadForTesting([
            SSHConfigParser.parse(
                threeHosts,
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])

        let beta = store.documents[0].blocks[1]
        store.deleteBlock(id: beta.id)
        #expect(order(store) == ["alpha", "gamma"])

        undo.undo()
        #expect(order(store) == ["alpha", "beta", "gamma"])

        undo.redo()
        #expect(order(store) == ["alpha", "gamma"])
    }

    @Test func freeTextEditsDoNotPushUndoSteps() {
        let store = autosaveOffStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.loadForTesting([
            SSHConfigParser.parse(
                threeHosts,
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        undo.removeAllActions()

        let alpha = store.documents[0].blocks[0]
        store.updateBlock(id: alpha.id, undoable: false) { block in
            block.header.value = "alpha2"
            block.header.isDirty = true
        }
        #expect(!undo.canUndo)
    }

    @Test func coalescedTypingCommitsToOneUndoStep() {
        let store = autosaveOffStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.loadForTesting([
            SSHConfigParser.parse(
                threeHosts,
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        undo.removeAllActions()

        let alpha = store.documents[0].blocks[0]
        // Simulate keystroke-by-keystroke typing into HostName.
        for value in ["a.", "a.exa", "a.example.com"] {
            store.updateBlock(id: alpha.id, actionName: "Edit HostName", coalescing: true) {
                $0.setValue(value, for: "HostName")
            }
        }
        // Nothing on the global stack while the field is still focused — the field
        // editor owns intra-field undo until the edit commits.
        #expect(!undo.canUndo)

        store.commitFieldEdit() // field loses focus
        #expect(undo.canUndo)

        undo.undo() // one step reverts the whole edit
        #expect(store.documents[0].blocks[0].firstValue(for: "HostName") == "a")
        undo.redo()
        #expect(store.documents[0].blocks[0].firstValue(for: "HostName") == "a.example.com")
    }

    @Test func committingWithNoOpenFieldEditPushesNoStep() {
        let store = autosaveOffStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.loadForTesting([
            SSHConfigParser.parse(
                threeHosts,
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        undo.removeAllActions()

        // Focusing then blurring a field without typing (no coalescing edit ever ran)
        // must not push an undo step — commitFieldEdit() is a no-op when none is open.
        store.commitFieldEdit()
        #expect(!undo.canUndo)
    }

    @Test func reloadClearsPendingFieldEdit() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(threeHosts, to: dir.appendingPathComponent("config"))
        let store = autosaveOffStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.useDirectoryForTesting(dir)
        store.reload()
        undo.removeAllActions()

        // Open a field edit but never commit it…
        let alpha = store.documents[0].blocks[0]
        store.updateBlock(id: alpha.id, actionName: "Edit HostName", coalescing: true) {
            $0.setValue("changed", for: "HostName")
        }
        // …then a disk reload happens (external change). The stale group must be dropped.
        store.reload()
        store.commitFieldEdit()
        #expect(!undo.canUndo)
    }

    @Test func undoOfDeleteReselectsRestoredBlock() {
        let store = autosaveOffStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.loadForTesting([
            SSHConfigParser.parse(
                threeHosts,
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])

        let beta = store.documents[0].blocks[1]
        store.selectedBlockID = beta.id
        store.deleteBlock(id: beta.id)
        #expect(store.selectedBlockID == nil) // dangling selection dropped on delete

        undo.undo()
        #expect(order(store) == ["alpha", "beta", "gamma"])
        #expect(store.selectedBlockID == beta.id) // restored block is re-selected
    }

    // MARK: - Time-window coalescing of rapid discrete edits

    private func coalescingStore() -> ConfigStore {
        let store = autosaveOffStore()
        store.undoManager = UndoManager()
        store.loadForTesting([
            SSHConfigParser.parse(
                threeHosts,
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        return store
    }

    @Test func rapidSameTargetEditsCoalesceToOneStep() {
        let store = coalescingStore()
        var now = Date(timeIntervalSince1970: 1000)
        store.clock = { now }
        let alpha = store.documents[0].blocks[0].id

        store.updateBlock(
            id: alpha, actionName: "Toggle Compression",
            coalesceTarget: "alpha:Compression"
        ) { $0.setValue("yes", for: "Compression") }
        now = now.addingTimeInterval(0.1) // within the 0.4 s window
        store.updateBlock(
            id: alpha, actionName: "Toggle Compression",
            coalesceTarget: "alpha:Compression"
        ) { $0.setValue("no", for: "Compression") }

        #expect(store.undoStepsRegistered == 1) // the repeat folded into the first
    }

    @Test func differentTargetsDoNotCoalesce() {
        let store = coalescingStore()
        var now = Date(timeIntervalSince1970: 1000)
        store.clock = { now }
        let alpha = store.documents[0].blocks[0].id

        store.updateBlock(
            id: alpha, actionName: "Toggle Compression",
            coalesceTarget: "alpha:Compression"
        ) { $0.setValue("yes", for: "Compression") }
        now = now.addingTimeInterval(0.1)
        store.updateBlock(
            id: alpha, actionName: "Toggle ForwardAgent",
            coalesceTarget: "alpha:ForwardAgent"
        ) { $0.setValue("yes", for: "ForwardAgent") }

        #expect(store.undoStepsRegistered == 2) // distinct targets → distinct steps
    }

    @Test func sameTargetOutsideWindowDoesNotCoalesce() {
        let store = coalescingStore()
        var now = Date(timeIntervalSince1970: 1000)
        store.clock = { now }
        let alpha = store.documents[0].blocks[0].id

        store.updateBlock(
            id: alpha, actionName: "Toggle Compression",
            coalesceTarget: "alpha:Compression"
        ) { $0.setValue("yes", for: "Compression") }
        now = now.addingTimeInterval(1.0) // past the 0.4 s window
        store.updateBlock(
            id: alpha, actionName: "Toggle Compression",
            coalesceTarget: "alpha:Compression"
        ) { $0.setValue("no", for: "Compression") }

        #expect(store.undoStepsRegistered == 2) // window elapsed → a fresh step
    }

    @Test func interveningStructuralEditBreaksCoalescing() {
        let store = coalescingStore()
        let now = Date(timeIntervalSince1970: 1000)
        store.clock = { now } // time frozen: only the edit breaks the burst
        let alpha = store.documents[0].blocks[0].id

        store.updateBlock(
            id: alpha, actionName: "Toggle Compression",
            coalesceTarget: "alpha:Compression"
        ) { $0.setValue("yes", for: "Compression") }
        store.addHost() // non-targeted edit clears the burst
        store.updateBlock(
            id: alpha, actionName: "Toggle Compression",
            coalesceTarget: "alpha:Compression"
        ) { $0.setValue("no", for: "Compression") }

        // toggle + addHost + toggle: the trailing toggle did NOT fold into the first
        // (same target, same instant) because the structural edit reset the burst.
        #expect(store.undoStepsRegistered == 3)
    }

    @Test func editActionNamesAreStable() {
        #expect(EditAction.deleteHost.name == "Delete Host")
        #expect(EditAction.editField("HostName").name == "Edit HostName")
        #expect(EditAction.toggleField("Compression").name == "Toggle Compression")
        #expect(EditAction.importHosts(1).name == "Import 1 Host")
        #expect(EditAction.importHosts(3).name == "Import 3 Hosts")
        #expect(EditAction.newFromTemplate("Bastion").name == "New Bastion")
    }

    // MARK: - config file auto-creation and config.d/ Include injection

    @Test func reloadCreatesConfigFileWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No config file — the directory exists but config does not.
        let configURL = dir.appendingPathComponent("config")
        #expect(!FileManager.default.fileExists(atPath: configURL.path))

        let store = ConfigStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        #expect(
            FileManager.default.fileExists(atPath: configURL.path),
            "reload() must create an empty config file if one does not exist")
        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        #expect(onDisk.isEmpty || onDisk == "")
        #expect(store.documents.count >= 1)
    }

    @Test func reloadAddsConfigDIncludeWhenDirectoryPresent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        let configD = dir.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configD, withIntermediateDirectories: true)
        try write("Host main\n    HostName m.example.com\n", to: configURL)
        try write(
            "Host work\n    HostName w.example.com\n",
            to: configD.appendingPathComponent("work.conf"))

        let store = ConfigStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        // Include directive must be on disk so OpenSSH itself also picks up config.d/.
        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        let hasInclude = onDisk.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("include") && $0.contains("config.d")
        }
        #expect(hasInclude, "config.d/ exists → Include config.d/* must be prepended to config")

        // The Include must be at the top (first non-blank line) so config.d/* entries
        // outrank any later matching blocks in the main file.
        let firstDirectiveLine = onDisk.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(
            firstDirectiveLine?.lowercased().hasPrefix("include") == true,
            "Include config.d/* must be the first line in the config file")

        // Both the main-config host and the config.d host must be loaded.
        let titles = store.allHostBlocks.map { $0.title }.sorted()
        #expect(titles.contains("main"))
        #expect(titles.contains("work"))
    }

    @Test func reloadConfigDIncludeIsIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        let configD = dir.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configD, withIntermediateDirectories: true)
        try write("", to: configURL)
        try write(
            "Host work\n    HostName w.example.com\n",
            to: configD.appendingPathComponent("work.conf"))

        let store = ConfigStore()
        store.useDirectoryForTesting(dir)
        store.reload()
        store.reload() // second call must not add a second Include

        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        let includeCount = onDisk.components(separatedBy: .newlines).filter {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("include") && $0.contains("config.d")
        }.count
        #expect(includeCount == 1, "Include config.d/* must appear exactly once even after multiple reloads")
    }

    @Test func reloadDoesNotAddIncludeWhenConfigDAbsent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        try write("Host main\n    HostName m.example.com\n", to: configURL)
        // No config.d/ directory.

        let store = ConfigStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        #expect(
            !onDisk.lowercased().contains("config.d"),
            "Include must not be added when config.d/ does not exist")
    }

    @Test func editToConfigDBlockSavesToConfigDNotMainConfig() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        let configD = dir.appendingPathComponent("config.d", isDirectory: true)
        let workURL = configD.appendingPathComponent("work.conf")
        try FileManager.default.createDirectory(at: configD, withIntermediateDirectories: true)
        try write("Include config.d/*\n\nHost main\n    HostName m.example.com\n", to: configURL)
        try write("Host work\n    HostName w.example.com\n", to: workURL)

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        // Snapshot disk state before the edit.
        let configBefore = try String(contentsOf: configURL, encoding: .utf8)

        // Find the block that came from config.d/work.conf and edit its HostName.
        guard let workBlock = store.allHostBlocks.first(where: { $0.patterns == ["work"] }) else {
            Issue.record("work block not loaded")
            return
        }
        store.updateBlock(id: workBlock.id, actionName: "Edit HostName") {
            $0.setValue("w-changed.example.com", for: "HostName")
        }
        store.flushPendingSave()

        // work.conf must reflect the change.
        let workOnDisk = try String(contentsOf: workURL, encoding: .utf8)
        #expect(
            workOnDisk.contains("w-changed.example.com"),
            "editing a config.d block must write to config.d/work.conf")

        // The main config file must be untouched.
        let configAfter = try String(contentsOf: configURL, encoding: .utf8)
        #expect(
            configAfter == configBefore,
            "editing a config.d block must NOT write the main config file")
    }

    // MARK: - Moving blocks between documents

    @Test func moveBlockToDocumentMovesBlockAndMarksBothDirty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        let configD = dir.appendingPathComponent("config.d", isDirectory: true)
        let workURL = configD.appendingPathComponent("work.conf")
        try FileManager.default.createDirectory(at: configD, withIntermediateDirectories: true)
        try write("Include config.d/*\n\nHost main\n    HostName m.example.com\n", to: configURL)
        try write("Host work\n    HostName w.example.com\n", to: workURL)

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        guard let workBlock = store.allHostBlocks.first(where: { $0.patterns == ["work"] }) else {
            Issue.record("work block not loaded")
            return
        }
        // Move "work" from config.d/work.conf → main config.
        store.moveBlockToDocument(id: workBlock.id, targetDocumentURL: configURL)

        // In-memory: "work" now lives in documents[0] (main config).
        let mainDoc = store.documents.first(where: { $0.sourceURL == configURL })
        let workDoc = store.documents.first(where: { $0.sourceURL == workURL })
        #expect(
            mainDoc?.blocks.contains(where: { $0.patterns == ["work"] }) == true,
            "block must appear in the target document in memory")
        #expect(
            workDoc?.blocks.contains(where: { $0.patterns == ["work"] }) == false,
            "block must no longer be in the source document in memory")

        // Both documents are dirty (both need to be saved).
        #expect(store.isDirty)
        store.flushPendingSave()

        // On disk: main config now contains "work".
        let configOnDisk = try String(contentsOf: configURL, encoding: .utf8)
        #expect(
            configOnDisk.contains("Host work"),
            "moved block must appear in the target file on disk")

        // On disk: work.conf no longer contains "work".
        let workOnDisk = try String(contentsOf: workURL, encoding: .utf8)
        #expect(
            !workOnDisk.contains("Host work"),
            "moved block must be gone from the source file on disk")
    }

    @Test func moveBlockToDocumentIsUndoable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        let configD = dir.appendingPathComponent("config.d", isDirectory: true)
        let workURL = configD.appendingPathComponent("work.conf")
        try FileManager.default.createDirectory(at: configD, withIntermediateDirectories: true)
        try write("Include config.d/*\n\nHost main\n    HostName m.example.com\n", to: configURL)
        try write("Host work\n    HostName w.example.com\n", to: workURL)

        let store = autosaveOffStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.useDirectoryForTesting(dir)
        store.reload()
        undo.removeAllActions()

        guard let workBlock = store.allHostBlocks.first(where: { $0.patterns == ["work"] }) else {
            Issue.record("work block not loaded")
            return
        }
        store.moveBlockToDocument(id: workBlock.id, targetDocumentURL: configURL)

        #expect(
            store.documents.first(where: { $0.sourceURL == configURL })?
                .blocks.contains(where: { $0.patterns == ["work"] }) == true)

        // Undo must restore "work" to config.d/work.conf.
        undo.undo()

        #expect(
            store.documents.first(where: { $0.sourceURL == workURL })?
                .blocks.contains(where: { $0.patterns == ["work"] }) == true,
            "undo must restore the block to the source document")
        #expect(
            store.documents.first(where: { $0.sourceURL == configURL })?
                .blocks.contains(where: { $0.patterns == ["work"] }) == false,
            "undo must remove the block from the target document")
    }

    /// The "New File…" entry in a host's "Move to File" menu — for when the
    /// target isn't one of the already-open documents.
    @Test func moveBlockToNewFileCreatesFileAndMovesBlockLosslessly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(
            "# pinned bastion\nHost alpha\n    HostName a.example.com\n",
            to: dir.appendingPathComponent("config"))

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        let alpha = try #require(store.allHostBlocks.first { $0.patterns == ["alpha"] })
        let fileURL = try #require(store.moveBlockToNewFile(id: alpha.id, fileName: "alpha.conf"))
        store.flushPendingSave()

        #expect(fileURL == dir.appendingPathComponent("ssh-config-manager.d/alpha.conf"))
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk.contains("Host alpha"))
        #expect(onDisk.contains("# pinned bastion"), "leading comment must travel with the host")

        let configOnDisk = try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
        #expect(!configOnDisk.contains("Host alpha"), "moved block must be gone from the source file")
        #expect(configOnDisk.contains("ssh-config-manager.d/*.conf"), "must wire an Include for the new file")
    }

    @Test func moveBlockToNewFileIsUndoable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        try write("Host alpha\n    HostName a.example.com\n", to: configURL)

        let store = autosaveOffStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.useDirectoryForTesting(dir)
        store.reload()
        undo.removeAllActions()

        let alpha = try #require(store.allHostBlocks.first { $0.patterns == ["alpha"] })
        _ = try #require(store.moveBlockToNewFile(id: alpha.id, fileName: "alpha.conf"))
        #expect(
            store.allHostBlocks.first { $0.patterns == ["alpha"] }?.sourceURL
                == dir.appendingPathComponent("ssh-config-manager.d/alpha.conf"))

        undo.undo()

        #expect(
            store.allHostBlocks.first { $0.patterns == ["alpha"] }?.sourceURL == configURL,
            "undo must restore the block to the original file")
    }

    @Test func moveBlockToSameDocumentIsNoOp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        try write("Host main\n    HostName m.example.com\n", to: configURL)

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()
        let before = store.documents

        guard let block = store.allHostBlocks.first else {
            Issue.record("no blocks loaded")
            return
        }
        store.moveBlockToDocument(id: block.id, targetDocumentURL: configURL)

        #expect(store.documents == before, "moving to the same file must be a no-op")
        #expect(!store.isDirty)
    }

    @Test func editToMainConfigBlockDoesNotWriteConfigDFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        let configD = dir.appendingPathComponent("config.d", isDirectory: true)
        let workURL = configD.appendingPathComponent("work.conf")
        try FileManager.default.createDirectory(at: configD, withIntermediateDirectories: true)
        try write("Include config.d/*\n\nHost main\n    HostName m.example.com\n", to: configURL)
        try write("Host work\n    HostName w.example.com\n", to: workURL)

        let store = autosaveOffStore()
        store.useDirectoryForTesting(dir)
        store.reload()

        let workBefore = try String(contentsOf: workURL, encoding: .utf8)

        guard let mainBlock = store.allHostBlocks.first(where: { $0.patterns == ["main"] }) else {
            Issue.record("main block not loaded")
            return
        }
        store.updateBlock(id: mainBlock.id, actionName: "Edit HostName") {
            $0.setValue("m-changed.example.com", for: "HostName")
        }
        store.flushPendingSave()

        let configOnDisk = try String(contentsOf: configURL, encoding: .utf8)
        #expect(
            configOnDisk.contains("m-changed.example.com"),
            "editing the main config block must write to the main config file")

        let workAfter = try String(contentsOf: workURL, encoding: .utf8)
        #expect(
            workAfter == workBefore,
            "editing the main config block must NOT write config.d files")
    }

    // MARK: - Search filters (sidebar + menu bar)

    @Test func sidebarSearchFiltersHosts() {
        let store = ConfigStore()
        store.loadForTesting([
            SSHConfigParser.parse(
                threeHosts,
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        store.searchText = "bet"
        let groups = store.filteredGroups
        #expect(groups.count == 1)
        #expect(groups[0].blocks.map { $0.title } == ["beta"])
    }

    @Test func menuBarSearchExcludesWildcardAndFilters() {
        let store = ConfigStore()
        store.loadForTesting([
            SSHConfigParser.parse(
                "Host *\n\nHost web\n    HostName w.example\n",
                sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        #expect(store.searchableHosts(matching: "").map { $0.title } == ["web"])
        #expect(store.searchableHosts(matching: "w").map { $0.title } == ["web"])
        #expect(store.searchableHosts(matching: "zzz").isEmpty)
    }

    @Test func copySSHCommandSkipsWildcardPattern() {
        let document = SSHConfigParser.parse(
            "Host * web\n",
            sourceURL: URL(fileURLWithPath: "/tmp/config"))
        let block = document.blocks[0]
        // primaryAlias skips the wildcard, so the copied command targets "web".
        // Asserted via the builder to avoid racing the shared NSPasteboard.
        let alias = block.primaryAlias ?? ""
        #expect(alias == "web")
        let resolved = EffectiveConfigResolver.resolve(target: alias, in: [document])
        #expect(SSHCommandBuilder.explicitCommand(target: alias, resolved: resolved).shellString == "ssh web")
    }
}
