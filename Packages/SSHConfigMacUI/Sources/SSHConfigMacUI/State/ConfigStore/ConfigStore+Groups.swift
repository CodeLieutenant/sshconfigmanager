import AppKit
import Foundation
import Observation
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigEngine
import SSHConfigServices
import Security
import SwiftUI
@preconcurrency import UserNotifications

extension ConfigStore {
    private func nextGroupName() -> String {
        let used = Set(groups.map(\.name))
        var n = 1
        while used.contains("Group-\(n)") { n += 1 }
        return "Group-\(n)"
    }

    private func nextGroupSortIndex() -> Int { (groups.map(\.sortIndex).max() ?? -1) + 1 }

    func group(id: PersistedGroup.ID) -> PersistedGroup? { groups.first { $0.id == id } }

    func group(named name: String) -> PersistedGroup? {
        groups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    func createGroup() -> PersistedGroup.ID {
        let group = PersistedGroup(name: nextGroupName(), filePath: nil, sortIndex: nextGroupSortIndex())
        mutate(EditAction.createGroup(group.name).name) {
            groups.append(group)
        }
        groupsMutatedBeforeLoad = true
        persistGroups()
        if groupingMode == .flat { groupingMode = .byTag }
        return group.id
    }

    @discardableResult
    func createFileBackedGroup(name: String, fileName: String, in directory: URL? = nil) -> PersistedGroup.ID? {
        guard let fileURL = prepareGroupFile(fileName: fileName, in: directory) else { return nil }
        let group = PersistedGroup(
            name: name, filePath: fileURL.standardizedFileURL.path,
            sortIndex: nextGroupSortIndex())
        mutate(EditAction.createGroup(name).name) {
            documents.append(SSHConfigDocument(sourceURL: fileURL))
            insertIncludeDirective(for: fileURL)
            groups.append(group)
        }
        groupsMutatedBeforeLoad = true
        persistGroups()
        if groupingMode == .flat { groupingMode = .byTag }
        return group.id
    }

    func extractGroupToFile(_ groupID: PersistedGroup.ID, fileName: String, in directory: URL? = nil) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), !groups[index].isFileBacked,
            let fileURL = prepareGroupFile(fileName: fileName, in: directory)
        else { return }
        let name = groups[index].name
        let tag = GroupResolver.groupTagPrefix + name
        let memberIDs =
            allHostBlocks
            .filter { tagsByAlias[alias(of: $0), default: []].contains(tag) }
            .map(\.id)

        mutate(EditAction.extractGroupToFile(name).name) {
            documents.append(SSHConfigDocument(sourceURL: fileURL))
            insertIncludeDirective(for: fileURL)
            for id in memberIDs { performMoveBlockToDocument(id: id, targetURL: fileURL) }
            groups[index].filePath = fileURL.standardizedFileURL.path
        }
        persistGroups()
    }

    func deleteGroup(_ groupID: PersistedGroup.ID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = groups[index]
        mutate(EditAction.deleteGroup(group.name).name) {
            groups.remove(at: index)
            if let path = group.filePath {
                removeIncludeDirective(forFilePath: path)
                documents.removeAll { $0.sourceURL.standardizedFileURL.path == path }
            }
            if !group.isFileBacked { stripGroupTag(group.name) }
        }
        if group.isFileBacked {
            flushPendingSave()
        }
        collapsedGroupNames.remove(group.id.uuidString)
        persistGroups()
    }

    private func stripGroupTag(_ name: String) {
        let tag = GroupResolver.groupTagPrefix + name
        for key in Array(tagsByAlias.keys) {
            guard var tags = tagsByAlias[key], tags.contains(tag) else { continue }
            tags.removeAll { $0 == tag }
            tagsByAlias[key] = tags.isEmpty ? nil : tags
        }
        persistHostMetadata()
    }

    func assignToGroup(blockID: HostBlock.ID, group: PersistedGroup) {
        guard let b = block(id: blockID) else { return }
        mutate(EditAction.moveHostToGroup(group.name).name) {
            if let targetURL = group.fileURL {
                performMoveBlockToDocument(id: blockID, targetURL: targetURL)
            } else if let mainURL = mainDocumentURL, b.sourceURL != mainURL,
                groups.contains(where: { $0.fileURL?.standardizedFileURL.path == b.sourceURL.standardizedFileURL.path })
            {
                performMoveBlockToDocument(id: blockID, targetURL: mainURL)
            }
            if !group.isFileBacked {
                var tags = tagsByAlias[alias(of: b), default: []]
                tags.removeAll { $0.hasPrefix(GroupResolver.groupTagPrefix) }
                tags.append(GroupResolver.groupTagPrefix + group.name)
                setTags(tags, for: b)
            }
        }
        if groupingMode == .flat { groupingMode = .byTag }
    }

    func dropHost(draggedID: HostBlock.ID, onto targetID: HostBlock.ID) {
        guard draggedID != targetID, let target = block(id: targetID) else { return }
        if let existing = GroupResolver.currentGroup(for: target, groups: groups, tags: tags(for: target)) {
            assignToGroup(blockID: draggedID, group: existing)
        } else {
            let newGroup = self.group(id: createGroup())
            guard let newGroup else { return }
            assignToGroup(blockID: targetID, group: newGroup)
            assignToGroup(blockID: draggedID, group: newGroup)
        }
    }

    func dropHost(draggedID: HostBlock.ID, intoGroup groupID: PersistedGroup.ID) {
        guard let group = group(id: groupID) else { return }
        assignToGroup(blockID: draggedID, group: group)
    }

    func renameGroup(_ groupID: PersistedGroup.ID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == groupID }),
            groups[index].name != trimmed,
            !groups.contains(where: { $0.id != groupID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        let oldName = groups[index].name
        let isFileBacked = groups[index].isFileBacked
        mutate(EditAction.renameGroup(trimmed).name) {
            groups[index].name = trimmed
            guard !isFileBacked else { return }
            let oldTag = GroupResolver.groupTagPrefix + oldName
            let newTag = GroupResolver.groupTagPrefix + trimmed
            for key in Array(tagsByAlias.keys) {
                guard let tags = tagsByAlias[key], tags.contains(oldTag) else { continue }
                tagsByAlias[key] = tags.map { $0 == oldTag ? newTag : $0 }
            }
            persistHostMetadata()
        }
        persistGroups()
    }

    func expandAllGroups() { collapsedGroupNames.removeAll() }

    func collapseAllGroups() {
        for group in groups { collapsedGroupNames.insert(group.id.uuidString) }
    }

    var allGroupNames: [String] { groups.map(\.name).sorted() }

    func moveToNewGroup(blockID: HostBlock.ID) {
        guard let newGroup = group(id: createGroup()) else { return }
        assignToGroup(blockID: blockID, group: newGroup)
    }

    func removeFromGroup(blockID: HostBlock.ID) {
        guard let b = block(id: blockID) else { return }
        mutate(EditAction.moveHostToGroup("Ungrouped").name) {
            if let mainURL = mainDocumentURL, b.sourceURL != mainURL,
                groups.contains(where: {
                    $0.fileURL?.standardizedFileURL.path == b.sourceURL.standardizedFileURL.path
                })
            {
                performMoveBlockToDocument(id: blockID, targetURL: mainURL)
            }
            var tags = tagsByAlias[alias(of: b), default: []]
            tags.removeAll { $0.hasPrefix(GroupResolver.groupTagPrefix) }
            setTags(tags, for: b)
        }
    }

    func isInGroup(_ block: HostBlock) -> Bool {
        GroupResolver.currentGroup(for: block, groups: groups, tags: tags(for: block)) != nil
    }

    func loadGroupsFromDatabase() async {
        defer { groupsInitialLoadCompleted = true }
        guard let database else { return }
        let loaded = (try? await database.loadGroups()) ?? []
        if !groupsMutatedBeforeLoad { groups = loaded }
        let metadata = (try? await database.loadHostMetadata()) ?? AppDatabase.HostMetadata()
        if !hostMetadataMutatedBeforeLoad {
            favoriteAliases = metadata.favoriteAliases
            tagsByAlias = metadata.tagsByAlias
        }
    }

    func persistGroups() {
        guard let database else { return }
        let snapshot = groups
        Task { try? await database.replaceGroups(snapshot) }
    }

    func startGroupsOnLaunch() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.groupsLoadTask?.value
            self.performGroupAutoDiscovery()
            self.pruneOrphanedFileBackedGroups()
            self.persistGroups()
        }
    }

    func performGroupAutoDiscovery() {
        var added = false
        var knownFilePaths = Set(groups.compactMap(\.filePath))
        var knownNames = Set(groups.map(\.name))
        var nextIndex = (groups.map(\.sortIndex).max() ?? -1) + 1

        for document in documents.dropFirst() {
            let path = document.sourceURL.standardizedFileURL.path
            guard !knownFilePaths.contains(path) else { continue }
            let stem = document.sourceURL.deletingPathExtension().lastPathComponent
            let name = uniqueGroupName(from: stem.isEmpty ? document.displayName : stem, existing: knownNames)
            groups.append(PersistedGroup(name: name, filePath: path, sortIndex: nextIndex))
            knownFilePaths.insert(path)
            knownNames.insert(name)
            nextIndex += 1
            added = true
        }

        let orphanTagNames = Set(
            tagsByAlias.values.flatMap { $0 }
                .filter { $0.hasPrefix(GroupResolver.groupTagPrefix) }
                .map { String($0.dropFirst(GroupResolver.groupTagPrefix.count)) }
                .filter { !$0.isEmpty }
        ).subtracting(knownNames)
        for name in orphanTagNames.sorted() {
            groups.append(PersistedGroup(name: name, filePath: nil, sortIndex: nextIndex))
            knownNames.insert(name)
            nextIndex += 1
            added = true
        }

        if added { groupsMutatedBeforeLoad = true }
    }

    func pruneOrphanedFileBackedGroups() {
        let knownPaths = Set(documents.map { $0.sourceURL.standardizedFileURL.path })
        let before = groups.count
        let orphaned = groups.filter { group in
            guard let path = group.filePath else { return false }
            return !knownPaths.contains(path)
        }
        guard !orphaned.isEmpty else { return }
        let orphanedIDs = Set(orphaned.map(\.id))
        groups.removeAll { orphanedIDs.contains($0.id) }
        groupsMutatedBeforeLoad = true
        Log.config.notice("pruned \(before - self.groups.count) orphaned group(s) with no backing file")
    }

    private func uniqueGroupName(from base: String, existing: Set<String>) -> String {
        let title = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .capitalized
        guard existing.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) else { return title }
        var suffix = 2
        while existing.contains(where: { $0.caseInsensitiveCompare("\(title) \(suffix)") == .orderedSame }) {
            suffix += 1
        }
        return "\(title) \(suffix)"
    }
}
