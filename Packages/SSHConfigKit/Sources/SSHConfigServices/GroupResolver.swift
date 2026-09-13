//
//  GroupResolver.swift
//  sshconfigmanager
//
//  Pure logic for grouping HostBlocks into named folder buckets for the sidebar
//  tree. No I/O, no SwiftUI — safe to unit-test directly.
//
//  A host's group membership is resolved with structural membership taking
//  priority over its tag: if the host's block physically lives in a file-backed
//  group's document, it belongs to that group regardless of any `"group/<name>"`
//  tag it might also carry. Only when no file-backed group claims it does the tag
//  apply. This lets `extractGroupToFile` promote a virtual group to file-backed
//  without needing to clear every member's tag (which would otherwise need its own
//  undo bookkeeping) — the stale tag just goes dormant, and would only resurface if
//  the host were later moved back out of every file-backed document by hand.
//

import Foundation
import SSHConfigCore

// MARK: - GroupingMode

/// The strategy the sidebar uses to organise the host list.
public enum GroupingMode: String, CaseIterable {
    /// No grouping — hosts appear flat, partitioned by source document (existing behaviour).
    case flat
    /// Group by `PersistedGroup` (structural membership for file-backed groups,
    /// `"group/<name>"` tag for virtual ones). Hosts matching neither go to "Ungrouped".
    case byTag
}

// MARK: - HostGroup

/// A named bucket of host blocks derived by `GroupResolver` — a transient view, never
/// stored (the durable form is `PersistedGroup`).
public struct HostGroup: Identifiable, Equatable {
    /// Stable identity: "Ungrouped" maps to a reserved sentinel so it always sorts last.
    public var id: String { isUngrouped ? "__ungrouped__" : (groupID?.uuidString ?? name) }
    public let groupID: PersistedGroup.ID?
    public let name: String
    public var blocks: [HostBlock]
    /// `true` for the implicit catch-all that holds hosts matching no group.
    public let isUngrouped: Bool
    /// Set when this group is backed by a real `Include`d file (absolute path).
    public let filePath: String?

    public var isFileBacked: Bool { filePath != nil }
}

// MARK: - GroupResolver

public enum GroupResolver {
    public static let groupTagPrefix = "group/"

    /// Partition `blocks` into named `HostGroup`s according to `mode`.
    ///
    /// - `mode == .flat` — returns an empty array; the caller falls back to the
    ///   existing document-partitioned rendering.
    /// - `mode == .byTag` — every `PersistedGroup` appears (even with zero members,
    ///   so an empty group stays visible), ordered by `sortIndex`; hosts matching
    ///   none land in an "Ungrouped" group at the end.
    ///
    /// `tagMap` is keyed by primary alias (the key `ConfigStore` uses for `tagsByAlias`).
    public static func resolve(
        blocks: [HostBlock],
        mode: GroupingMode,
        tagMap: [String: [String]],
        groups: [PersistedGroup]
    ) -> [HostGroup] {
        switch mode {
        case .flat:
            return []
        case .byTag:
            return resolveByGroups(blocks: blocks, tagMap: tagMap, groups: groups)
        }
    }

    /// The group `block` currently belongs to, applying the structural-over-tag
    /// priority rule described at the top of this file. `tags` is `tagMap[alias]`.
    public static func currentGroup(for block: HostBlock, groups: [PersistedGroup], tags: [String]) -> PersistedGroup? {
        let path = block.sourceURL.standardizedFileURL.path
        if let fileGroup = groups.first(where: { $0.filePath == path }) { return fileGroup }
        guard let groupTag = tags.first(where: { $0.hasPrefix(groupTagPrefix) }) else { return nil }
        let name = String(groupTag.dropFirst(groupTagPrefix.count))
        guard !name.isEmpty else { return nil }
        return groups.first { $0.name == name }
    }

    private static func resolveByGroups(
        blocks: [HostBlock],
        tagMap: [String: [String]],
        groups: [PersistedGroup]
    ) -> [HostGroup] {
        let ordered = groups.sorted { $0.sortIndex < $1.sortIndex }
        var blocksByGroupID: [PersistedGroup.ID: [HostBlock]] = [:]
        var ungrouped: [HostBlock] = []

        for block in blocks {
            // Must match the key that ConfigStore.alias(of:) writes: patterns.first ?? "".
            let alias = block.patterns.first ?? ""
            let tags = tagMap[alias] ?? []
            if let match = currentGroup(for: block, groups: ordered, tags: tags) {
                blocksByGroupID[match.id, default: []].append(block)
            } else {
                ungrouped.append(block)
            }
        }

        var result = ordered.map { group in
            HostGroup(
                groupID: group.id, name: group.name, blocks: blocksByGroupID[group.id] ?? [],
                isUngrouped: false, filePath: group.filePath)
        }
        if !ungrouped.isEmpty {
            result.append(
                HostGroup(
                    groupID: nil, name: "Ungrouped", blocks: ungrouped,
                    isUngrouped: true, filePath: nil))
        }
        return result
    }
}
