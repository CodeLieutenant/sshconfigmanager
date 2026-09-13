//
//  PersistedGroup.swift
//  sshconfigmanager
//
//  A user-visible sidebar group. Always has a stable identity and a display name;
//  `filePath` is set only for groups backed by a real `Include`d file. Stored as
//  an absolute path (not relative to the granted `~/.ssh` directory, unlike
//  `ConfigStore.relPath(for:)`/version-history manifests) because a group's file
//  is fully allowed to live outside `~/.ssh` via an extra security-scoped
//  bookmark — `relPath(for:)`'s granted-directory-relative scheme has no way to
//  represent that. A group with no `filePath` is "virtual" — its membership lives
//  in the `group/<name>` tag on each host, same as before this feature existed.
//

import Foundation

public struct PersistedGroup: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var filePath: String?
    public var sortIndex: Int

    public var isFileBacked: Bool { filePath != nil }
    public var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }

    public init(id: UUID = UUID(), name: String, filePath: String? = nil, sortIndex: Int) {
        self.id = id
        self.name = name
        self.filePath = filePath
        self.sortIndex = sortIndex
    }
}
