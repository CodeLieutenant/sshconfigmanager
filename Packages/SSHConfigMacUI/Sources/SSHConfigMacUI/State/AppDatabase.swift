import Foundation
import SSHConfigCore
import SSHConfigServices
import SwiftData
import os

actor AppDatabase: ModelActor {
    struct HostKeyCheckRecord: Sendable, Equatable {
        let groupID: String
        let hostTitle: String
        let displayName: String
        let hostToken: String
        let keyType: String
        let fingerprint: String
        let serverOpenSSH: String
        let outcome: String
        let checkedAt: Date
    }

    struct BlobPayload: Sendable {
        let relPath: String
        let hash: String
        let compressed: Data
        let size: Int
    }

    struct HostMetadata: Sendable, Equatable {
        var favoriteAliases: Set<String> = []
        var tagsByAlias: [String: [String]] = [:]
    }

    struct LegacySources: Sendable {
        var databaseURL: URL?
        var defaultsSuiteName: String?
        var readsStandardDefaults = false
    }

    static let hostKeyCheckCap = 5000

    static var supportDirectory: URL? {
        guard
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let directory = support.appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory
    }

    static let storeURL: URL? = supportDirectory?.appendingPathComponent("SSHConfigManager.store")
    static let legacyDatabaseURL: URL? = supportDirectory?.appendingPathComponent("sshconfigmanager.sqlite3")

    static let shared: AppDatabase? = storeURL.flatMap {
        try? AppDatabase(
            url: $0, legacy: LegacySources(databaseURL: legacyDatabaseURL, readsStandardDefaults: true))
    }

    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor
    private let legacy: LegacySources
    private var isPrepared = false

    init(url: URL, legacy: LegacySources = LegacySources()) throws {
        let configuration = ModelConfiguration(schema: Schema(versionedSchema: SchemaV1.self), url: url)
        try self.init(configuration: configuration, legacy: legacy)
    }

    static func inMemory() throws -> AppDatabase {
        try AppDatabase(
            configuration: ModelConfiguration(
                schema: Schema(versionedSchema: SchemaV1.self), isStoredInMemoryOnly: true),
            legacy: LegacySources())
    }

    private init(configuration: ModelConfiguration, legacy: LegacySources) throws {
        let container = try ModelContainer(
            for: Schema(versionedSchema: SchemaV1.self),
            migrationPlan: PersistenceMigrationPlan.self,
            configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.legacy = legacy
    }

    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        importLegacyDataIfNeeded(from: legacy)
    }

    func save() throws {
        guard modelContext.hasChanges else { return }
        try modelContext.save()
    }

    func fetch<Model: PersistentModel>(
        _ predicate: Predicate<Model>? = nil,
        sortBy: [SortDescriptor<Model>] = [],
        limit: Int? = nil
    ) throws -> [Model] {
        var descriptor = FetchDescriptor<Model>(predicate: predicate, sortBy: sortBy)
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    func count<Model: PersistentModel>(_ type: Model.Type, _ predicate: Predicate<Model>? = nil) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Model>(predicate: predicate))
    }

    func isEmpty() throws -> Bool {
        prepare()
        return try count(TunnelModel.self) == 0
    }

    func load() throws -> [TunnelPreset] {
        prepare()
        let models: [TunnelModel] = try fetch(sortBy: [SortDescriptor(\.position)])
        let presets = models.compactMap(TunnelPreset.init)
        Log.database.notice("loaded \(presets.count) tunnel preset(s)")
        return presets
    }

    func replaceAll(_ presets: [TunnelPreset]) throws {
        prepare()
        writeTunnels(presets)
        try save()
        Log.database.notice("stored \(presets.count) tunnel preset(s)")
    }

    func writeTunnels(_ presets: [TunnelPreset]) {
        let models = (try? fetch() as [TunnelModel]) ?? []
        var existing = Dictionary(models.map { ($0.tunnelID, $0) }, uniquingKeysWith: { first, _ in first })
        for (position, preset) in presets.enumerated() {
            let model: TunnelModel
            if let current = existing.removeValue(forKey: preset.id) {
                current.update(from: preset, position: position)
                model = current
            } else {
                model = TunnelModel(preset, position: position)
                modelContext.insert(model)
            }
            for mapping in model.mappings {
                modelContext.delete(mapping)
            }
            model.mappings = preset.mappings.enumerated().map { position, mapping in
                PortMappingModel(mapping, position: position)
            }
        }
        for stale in existing.values {
            modelContext.delete(stale)
        }
    }

    func loadGroups() throws -> [PersistedGroup] {
        prepare()
        let models: [HostGroupModel] = try fetch(sortBy: [SortDescriptor(\.sortIndex)])
        return models.map(PersistedGroup.init)
    }

    func replaceGroups(_ groups: [PersistedGroup]) throws {
        prepare()
        writeGroups(groups)
        try save()
    }

    func writeGroups(_ groups: [PersistedGroup]) {
        let models = (try? fetch() as [HostGroupModel]) ?? []
        var existing = Dictionary(models.map { ($0.groupID, $0) }, uniquingKeysWith: { first, _ in first })
        for group in groups {
            if let current = existing.removeValue(forKey: group.id) {
                current.update(from: group)
            } else {
                modelContext.insert(HostGroupModel(group))
            }
        }
        for stale in existing.values {
            modelContext.delete(stale)
        }
    }

    func loadHostMetadata() throws -> HostMetadata {
        prepare()
        var metadata = HostMetadata()
        for model in try fetch() as [HostMetadataModel] {
            if model.isFavorite { metadata.favoriteAliases.insert(model.alias) }
            if !model.tags.isEmpty { metadata.tagsByAlias[model.alias] = model.tags }
        }
        return metadata
    }

    func replaceHostMetadata(_ metadata: HostMetadata) throws {
        prepare()
        writeHostMetadata(metadata)
        try save()
    }

    func writeHostMetadata(_ metadata: HostMetadata) {
        let models = (try? fetch() as [HostMetadataModel]) ?? []
        var byAlias = Dictionary(models.map { ($0.alias, $0) }, uniquingKeysWith: { first, _ in first })
        for alias in metadata.favoriteAliases.union(metadata.tagsByAlias.keys) {
            let isFavorite = metadata.favoriteAliases.contains(alias)
            let tags = metadata.tagsByAlias[alias] ?? []
            if let model = byAlias.removeValue(forKey: alias) {
                model.isFavorite = isFavorite
                model.tags = tags
            } else {
                modelContext.insert(HostMetadataModel(alias: alias, isFavorite: isFavorite, tags: tags))
            }
        }
        for stale in byAlias.values {
            modelContext.delete(stale)
        }
    }

    func loadSettings() throws -> [String: String] {
        prepare()
        let models: [SettingModel] = try fetch()
        return Dictionary(models.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    func setSetting(_ key: String, _ value: String) throws {
        prepare()
        writeSetting(key, value)
        try save()
    }

    func writeSetting(_ key: String, _ value: String) {
        let models = (try? fetch(#Predicate<SettingModel> { $0.key == key }, limit: 1)) ?? []
        if let model = models.first {
            model.value = value
        } else {
            modelContext.insert(SettingModel(key: key, value: value))
        }
    }

    func recordHostKeyChecks(_ records: [HostKeyCheckRecord], cap: Int = hostKeyCheckCap) throws {
        prepare()
        guard !records.isEmpty else { return }
        for record in records {
            modelContext.insert(HostKeyCheckModel(record))
        }
        try save()

        let overflow = try count(HostKeyCheckModel.self) - cap
        guard overflow > 0 else { return }
        let oldest: [HostKeyCheckModel] = try fetch(sortBy: [SortDescriptor(\.checkedAt)], limit: overflow)
        for model in oldest {
            modelContext.delete(model)
        }
        try save()
    }

    func loadLatestHostKeyChecks() throws -> [HostKeyCheckRecord] {
        prepare()
        let models: [HostKeyCheckModel] = try fetch(sortBy: [SortDescriptor(\.checkedAt, order: .reverse)])
        var seen: Set<String> = []
        return models.compactMap { model in
            guard seen.insert(model.groupID).inserted else { return nil }
            return HostKeyCheckRecord(model)
        }
    }

    func loadHostKeyHistory(groupID: String, limit: Int = 50) throws -> [HostKeyCheckRecord] {
        prepare()
        let models: [HostKeyCheckModel] = try fetch(
            #Predicate { $0.groupID == groupID },
            sortBy: [SortDescriptor(\.checkedAt, order: .reverse)],
            limit: limit)
        return models.map(HostKeyCheckRecord.init)
    }

    func insertVersion(_ version: ConfigVersion, files: [BlobPayload], headKey: String) throws {
        prepare()
        for file in files {
            insertBlobIfMissing(hash: file.hash, data: file.compressed, size: file.size)
        }
        let model = ConfigVersionModel(version)
        modelContext.insert(model)
        model.files = files.map { ConfigVersionFileModel(relativePath: $0.relPath, blobHash: $0.hash) }
        writeSetting(headKey, version.id)
        try save()
    }

    func insertBlobIfMissing(hash: String, data: Data, size: Int) {
        let existing = (try? count(ConfigBlobModel.self, #Predicate { $0.blobHash == hash })) ?? 0
        guard existing == 0 else { return }
        modelContext.insert(ConfigBlobModel(blobHash: hash, data: data, size: size))
    }

    func loadVersions() throws -> [ConfigVersion] {
        prepare()
        let models: [ConfigVersionModel] = try fetch(sortBy: [
            SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.versionID, order: .reverse),
        ])
        return models.map(ConfigVersion.init)
    }

    func versionFiles(_ versionID: String) throws -> [(relPath: String, blobHash: String)] {
        prepare()
        guard let version = try versionModel(versionID) else { return [] }
        return version.files
            .sorted { $0.relativePath < $1.relativePath }
            .map { ($0.relativePath, $0.blobHash) }
    }

    private func versionModel(_ versionID: String) throws -> ConfigVersionModel? {
        try fetch(#Predicate<ConfigVersionModel> { $0.versionID == versionID }, limit: 1).first
    }

    func blobData(_ hash: String) throws -> Data? {
        prepare()
        return try fetch(#Predicate<ConfigBlobModel> { $0.blobHash == hash }, limit: 1).first?.data
    }

    func renameVersion(_ versionID: String, name: String?) throws {
        prepare()
        try versionModel(versionID)?.name = name
        try save()
    }

    func versionCount() throws -> Int {
        prepare()
        return try count(ConfigVersionModel.self)
    }

    func blobCount() throws -> Int {
        prepare()
        return try count(ConfigBlobModel.self)
    }

    func pruneToCap(_ cap: Int, head: String?) throws {
        prepare()
        guard cap > 0 else { return }
        let overflow = try count(ConfigVersionModel.self) - cap
        guard overflow > 0 else { return }

        let order = [SortDescriptor(\ConfigVersionModel.createdAt), SortDescriptor(\ConfigVersionModel.versionID)]
        let victims: [ConfigVersionModel]
        if let head {
            victims = try fetch(#Predicate { $0.versionID != head }, sortBy: order, limit: overflow)
        } else {
            victims = try fetch(sortBy: order, limit: overflow)
        }

        for victim in victims {
            let victimID = victim.versionID
            let children: [ConfigVersionModel] = try fetch(#Predicate { $0.parentID == victimID })
            for child in children {
                child.parentID = victim.parentID
            }
            modelContext.delete(victim)
            try save()
        }

        let referenced = Set((try fetch() as [ConfigVersionFileModel]).map(\.blobHash))
        for blob in try fetch() as [ConfigBlobModel] where !referenced.contains(blob.blobHash) {
            modelContext.delete(blob)
        }
        try save()
    }

    func clearHistory(headKey: String) throws {
        prepare()
        for version in try fetch() as [ConfigVersionModel] {
            modelContext.delete(version)
        }
        for blob in try fetch() as [ConfigBlobModel] {
            modelContext.delete(blob)
        }
        for setting in try fetch(#Predicate<SettingModel> { $0.key == headKey }) {
            modelContext.delete(setting)
        }
        try save()
    }
}
