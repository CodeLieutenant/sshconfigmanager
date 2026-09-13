import Foundation
import SSHConfigCore
import SSHConfigServices

/// Favorites, tags and groups.
///
/// None of this belongs in ssh_config — the parser is lossless and app-only data
/// must never leak into the file ssh reads. The macOS build keeps it in
/// UserDefaults; Linux keeps one JSON file, keyed by the host's primary alias.
public struct HostMetadata: Codable, Equatable {
    public var favorites: Set<String> = []
    public var tagsByAlias: [String: [String]] = [:]
    public var groups: [PersistedGroupRecord] = []
    public var groupingMode: String = "flat"
    public var collapsedGroups: Set<String> = []

    public init() {}

    /// `PersistedGroup` is not Codable-friendly across the package boundary, so
    /// the file keeps its own record and converts.
    public struct PersistedGroupRecord: Codable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var filePath: String?
        public var sortIndex: Int

        public init(id: UUID = UUID(), name: String, filePath: String? = nil, sortIndex: Int) {
            self.id = id
            self.name = name
            self.filePath = filePath
            self.sortIndex = sortIndex
        }

        public var persisted: PersistedGroup {
            .init(id: id, name: name, filePath: filePath, sortIndex: sortIndex)
        }
    }

    public var persistedGroups: [PersistedGroup] {
        groups.map(\.persisted)
    }

    public var mode: GroupingMode {
        GroupingMode(rawValue: groupingMode) ?? .flat
    }

    public func tags(for alias: String) -> [String] {
        // The group/<name> tag is how a virtual group is recorded. It is machinery,
        // not something the user typed, so it never appears in the tag UI.
        (tagsByAlias[alias] ?? []).filter { !$0.hasPrefix(GroupResolver.groupTagPrefix) }
    }

    public func isFavorite(_ alias: String) -> Bool {
        favorites.contains(alias)
    }

    public var allTags: [String] {
        Set(tagsByAlias.values.flatMap { $0 })
            .filter { !$0.hasPrefix(GroupResolver.groupTagPrefix) }
            .sorted()
    }

    public mutating func toggleFavorite(_ alias: String) {
        if favorites.contains(alias) {
            favorites.remove(alias)
        } else {
            favorites.insert(alias)
        }
        save()
    }

    public mutating func setTags(_ tags: [String], for alias: String) {
        let groupTags = (tagsByAlias[alias] ?? []).filter {
            $0.hasPrefix(GroupResolver.groupTagPrefix)
        }
        tagsByAlias[alias] = tags + groupTags
        save()
    }

    public mutating func setGroup(_ group: PersistedGroupRecord?, for alias: String) {
        var tags = (tagsByAlias[alias] ?? []).filter {
            !$0.hasPrefix(GroupResolver.groupTagPrefix)
        }
        if let group {
            tags.append("\(GroupResolver.groupTagPrefix)\(group.name)")
        }
        tagsByAlias[alias] = tags
        save()
    }

    public func group(for alias: String) -> PersistedGroupRecord? {
        let tag = (tagsByAlias[alias] ?? []).first {
            $0.hasPrefix(GroupResolver.groupTagPrefix)
        }
        guard let name = tag?.dropFirst(GroupResolver.groupTagPrefix.count) else { return nil }
        return groups.first { $0.name == name }
    }

    public mutating func addGroup(named name: String, filePath: String? = nil) {
        guard !groups.contains(where: { $0.name == name }) else { return }
        groups.append(.init(name: name, filePath: filePath, sortIndex: groups.count))
        save()
    }

    public mutating func removeGroup(named name: String) {
        groups.removeAll { $0.name == name }
        for (alias, tags) in tagsByAlias {
            tagsByAlias[alias] = tags.filter { $0 != "\(GroupResolver.groupTagPrefix)\(name)" }
        }
        save()
    }

    public mutating func renameGroup(from old: String, to new: String) {
        guard let index = groups.firstIndex(where: { $0.name == old }) else { return }
        groups[index].name = new
        for (alias, tags) in tagsByAlias {
            tagsByAlias[alias] = tags.map {
                $0 == "\(GroupResolver.groupTagPrefix)\(old)"
                    ? "\(GroupResolver.groupTagPrefix)\(new)" : $0
            }
        }
        save()
    }
}

extension HostMetadata {
    public static var path: String {
        let base =
            ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? "\(SSHDirectory.home)/.config"
        return "\(base)/sshmanager/hosts.json"
    }

    public static func load() -> HostMetadata {
        guard let data = FileManager.default.contents(atPath: path),
            let metadata = try? JSONDecoder().decode(HostMetadata.self, from: data)
        else { return HostMetadata() }
        return metadata
    }

    public func save() {
        let directory = URL(fileURLWithPath: Self.path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
    }
}
