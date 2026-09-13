//
//  VirtualGroupUndoTests.swift
//  sshconfigmanagerTests
//
//  Reproducer: undo left *virtual* (tag-based) group membership inconsistent.
//
//  `GroupFileLifecycleTests` covers the file-backed case thoroughly — file, hosts
//  and group row all come back together. A virtual group has no file: its whole
//  membership is the members' `group/<name>` tags in `tagsByAlias`, and that
//  dictionary was not part of `EditorSnapshot`. So every group operation undid only
//  half of itself:
//
//   • undo a rename  → group name reverts, members stay tagged `group/<newName>`,
//                      `GroupResolver` finds no group by that name, hosts silently
//                      fall into "Ungrouped"
//   • undo a delete  → the group row comes back empty
//   • undo an assign → the host stays in the group it was just moved into
//   • undo "remove from group" → nothing happened at all: with no document change
//                      there was no `mutate`, so no undo step was ever registered
//

import Foundation
import SSHConfigCore
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

@MainActor
struct VirtualGroupUndoTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshvgroups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Autosave-off, database-less store — matches `GroupFileLifecycleTests`.
    private func autosaveOffStore() -> ConfigStore {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        return ConfigStore(settings: settings)
    }

    private func storeWithOneHost(alias: String) throws -> (ConfigStore, UndoManager, URL, HostBlock) {
        let dir = try makeTempDir()
        try "Host \(alias)\n    HostName h.example.com\n"
            .write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let store = autosaveOffStore()
        let undo = UndoManager()
        store.undoManager = undo
        store.useDirectoryForTesting(dir)
        store.reload()
        let block = store.allHostBlocks.first { $0.patterns == [alias] }
        return (store, undo, dir, block!)
    }

    /// The group a host currently resolves into, the same way the sidebar computes it.
    private func resolvedGroupName(_ store: ConfigStore, _ blockID: HostBlock.ID) -> String? {
        guard let block = store.block(id: blockID) else { return nil }
        return GroupResolver.currentGroup(
            for: block, groups: store.groups, tags: store.tags(for: block))?.name
    }

    // MARK: - Rename

    @Test func undoingAVirtualGroupRenameKeepsItsMembers() throws {
        let alias = "vg-rename-\(UUID().uuidString.prefix(8))"
        let (store, undo, dir, block) = try storeWithOneHost(alias: alias)
        defer { try? FileManager.default.removeItem(at: dir) }

        let groupID = store.createGroup()
        let group = try #require(store.group(id: groupID))
        store.assignToGroup(blockID: block.id, group: group)
        #expect(resolvedGroupName(store, block.id) == group.name)
        undo.removeAllActions()

        store.renameGroup(groupID, to: "Renamed")
        #expect(resolvedGroupName(store, block.id) == "Renamed")

        undo.undo()
        #expect(store.group(id: groupID)?.name == group.name, "undo must restore the group name")
        #expect(
            resolvedGroupName(store, block.id) == group.name,
            "undo must take the members' tags back with the name — not drop them into Ungrouped")
    }

    @Test func redoingAVirtualGroupRenameKeepsItsMembers() throws {
        let alias = "vg-redo-\(UUID().uuidString.prefix(8))"
        let (store, undo, dir, block) = try storeWithOneHost(alias: alias)
        defer { try? FileManager.default.removeItem(at: dir) }

        let groupID = store.createGroup()
        store.assignToGroup(blockID: block.id, group: try #require(store.group(id: groupID)))
        undo.removeAllActions()
        store.renameGroup(groupID, to: "Renamed")
        undo.undo()
        undo.redo()

        #expect(store.group(id: groupID)?.name == "Renamed")
        #expect(resolvedGroupName(store, block.id) == "Renamed")
    }

    // MARK: - Delete

    @Test func undoingAVirtualGroupDeleteRestoresItsMembers() throws {
        let alias = "vg-del-\(UUID().uuidString.prefix(8))"
        let (store, undo, dir, block) = try storeWithOneHost(alias: alias)
        defer { try? FileManager.default.removeItem(at: dir) }

        let groupID = store.createGroup()
        let group = try #require(store.group(id: groupID))
        store.assignToGroup(blockID: block.id, group: group)
        undo.removeAllActions()

        store.deleteGroup(groupID)
        #expect(store.group(id: groupID) == nil)
        #expect(resolvedGroupName(store, block.id) == nil)

        undo.undo()
        #expect(store.group(id: groupID) != nil, "undo must restore the group row")
        #expect(
            resolvedGroupName(store, block.id) == group.name,
            "undo must restore membership too — a group that comes back empty is not undone")
    }

    // MARK: - Assign / remove

    @Test func undoingAnAssignTakesTheHostBackOut() throws {
        let alias = "vg-assign-\(UUID().uuidString.prefix(8))"
        let (store, undo, dir, block) = try storeWithOneHost(alias: alias)
        defer { try? FileManager.default.removeItem(at: dir) }

        let groupID = store.createGroup()
        let group = try #require(store.group(id: groupID))
        undo.removeAllActions()

        store.assignToGroup(blockID: block.id, group: group)
        #expect(resolvedGroupName(store, block.id) == group.name)

        undo.undo()
        #expect(resolvedGroupName(store, block.id) == nil, "undo must remove the group tag it added")
    }

    /// Leaving a virtual group changes no document, so the old code took no `mutate`
    /// path and registered no undo step — ⌘Z did nothing (or, worse, reverted an
    /// unrelated earlier edit).
    @Test func removingFromAVirtualGroupIsUndoable() throws {
        let alias = "vg-remove-\(UUID().uuidString.prefix(8))"
        let (store, undo, dir, block) = try storeWithOneHost(alias: alias)
        defer { try? FileManager.default.removeItem(at: dir) }

        let groupID = store.createGroup()
        let group = try #require(store.group(id: groupID))
        store.assignToGroup(blockID: block.id, group: group)
        undo.removeAllActions()

        store.removeFromGroup(blockID: block.id)
        #expect(resolvedGroupName(store, block.id) == nil)
        #expect(undo.canUndo, "leaving a virtual group must register an undo step")

        undo.undo()
        #expect(resolvedGroupName(store, block.id) == group.name, "undo must put the host back in its group")
    }
}
