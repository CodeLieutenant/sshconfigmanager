import Foundation
import SSHConfigCore
import SSHConfigServices
import SwiftData
import os

extension AppDatabase {
    static let legacyFavoritesKey = "favoriteAliases"
    static let legacyTagsKey = "tagsByAlias"

    func importLegacyDataIfNeeded(from sources: LegacySources) {
        guard storeIsEmpty() else { return }
        importLegacyDefaults(from: sources)
        guard let url = sources.databaseURL, FileManager.default.fileExists(atPath: url.path) else {
            try? save()
            return
        }
        do {
            let reader = try LegacySQLiteReader(url: url)
            importLegacyRows(from: reader)
            reader.close()
            try save()
            Self.retireLegacyDatabase(at: url)
            Log.database.notice("imported legacy SQLite database")
        } catch {
            modelContext.rollback()
            Log.database.error("legacy import failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func storeIsEmpty() -> Bool {
        let counts = [
            try? count(SettingModel.self),
            try? count(TunnelModel.self),
            try? count(ConfigVersionModel.self),
            try? count(HostMetadataModel.self),
        ]
        return counts.allSatisfy { $0 == 0 }
    }

    private func importLegacyDefaults(from sources: LegacySources) {
        let defaults: UserDefaults? =
            if let suite = sources.defaultsSuiteName {
                UserDefaults(suiteName: suite)
            } else if sources.readsStandardDefaults {
                UserDefaults.standard
            } else {
                nil
            }
        guard let defaults else { return }
        var metadata = HostMetadata()
        if let favorites = defaults.array(forKey: Self.legacyFavoritesKey) as? [String] {
            metadata.favoriteAliases = Set(favorites)
        }
        if let tags = defaults.dictionary(forKey: Self.legacyTagsKey) as? [String: [String]] {
            metadata.tagsByAlias = tags
        }
        guard metadata != HostMetadata() else { return }
        writeHostMetadata(metadata)
        defaults.removeObject(forKey: Self.legacyFavoritesKey)
        defaults.removeObject(forKey: Self.legacyTagsKey)
    }

    private func importLegacyRows(from reader: LegacySQLiteReader) {
        if reader.tableExists("settings") {
            for row in reader.rows("SELECT key, value FROM settings") {
                guard let key = row["key"]?.string, let value = row["value"]?.string else { continue }
                modelContext.insert(SettingModel(key: key, value: value))
            }
        }
        if reader.tableExists("tunnels") {
            writeTunnels(Self.legacyTunnels(from: reader))
        }
        if reader.tableExists("host_groups") {
            writeGroups(
                reader.rows("SELECT * FROM host_groups ORDER BY sort_index").compactMap { row in
                    guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let name = row["name"]?.string
                    else { return nil }
                    return PersistedGroup(
                        id: id, name: name, filePath: row["file_path"]?.string, sortIndex: row["sort_index"]?.int ?? 0)
                })
        }
        if reader.tableExists("host_key_checks") {
            for row in reader.rows("SELECT * FROM host_key_checks") {
                guard let groupID = row["group_id"]?.string, let checkedAt = row["checked_at"]?.double else { continue }
                modelContext.insert(
                    HostKeyCheckModel(
                        groupID: groupID,
                        hostTitle: row["host_title"]?.string ?? groupID,
                        displayName: row["display_name"]?.string ?? groupID,
                        hostToken: row["host_token"]?.string ?? "",
                        keyType: row["key_type"]?.string ?? "",
                        fingerprint: row["fingerprint"]?.string ?? "",
                        serverOpenSSH: row["server_openssh"]?.string ?? "",
                        outcome: row["outcome"]?.string ?? "",
                        checkedAt: Date(timeIntervalSince1970: checkedAt)))
            }
        }
        if reader.tableExists("config_versions") {
            importLegacyHistory(from: reader)
        }
    }

    private static func legacyTunnels(from reader: LegacySQLiteReader) -> [TunnelPreset] {
        var mappingsByTunnel: [String: [PortMapping]] = [:]
        if reader.tableExists("port_mappings") {
            for row in reader.rows("SELECT * FROM port_mappings ORDER BY position") {
                guard let tunnelID = row["tunnel_id"]?.string,
                    let id = row["id"]?.string.flatMap(UUID.init(uuidString:))
                else { continue }
                mappingsByTunnel[tunnelID, default: []].append(
                    PortMapping(
                        id: id,
                        bindAddress: row["bind_address"]?.string ?? "",
                        listenPort: row["listen_port"]?.int ?? 0,
                        targetHost: row["target_host"]?.string ?? "localhost",
                        targetPort: row["target_port"]?.int ?? 0,
                        hasWebUI: row["has_web_ui"]?.bool ?? false))
            }
        }
        return reader.rows("SELECT * FROM tunnels ORDER BY position").compactMap { row in
            guard let idText = row["id"]?.string, let id = UUID(uuidString: idText),
                let mode = row["mode"]?.string.flatMap(TunnelMode.init(rawValue:))
            else { return nil }
            return TunnelPreset(
                id: id,
                name: row["name"]?.string ?? "",
                hostAlias: row["host_alias"]?.string ?? "",
                mode: mode,
                mappings: mappingsByTunnel[idText] ?? [],
                autostart: row["autostart"]?.bool ?? false)
        }
    }

    private func importLegacyHistory(from reader: LegacySQLiteReader) {
        if reader.tableExists("config_blobs") {
            for row in reader.rows("SELECT hash, data, size FROM config_blobs") {
                guard let hash = row["hash"]?.string, let data = row["data"]?.data else { continue }
                modelContext.insert(ConfigBlobModel(blobHash: hash, data: data, size: row["size"]?.int ?? data.count))
            }
        }
        var filesByVersion: [String: [ConfigVersionFileModel]] = [:]
        if reader.tableExists("config_version_files") {
            for row in reader.rows("SELECT version_id, rel_path, blob_hash FROM config_version_files") {
                guard let versionID = row["version_id"]?.string, let path = row["rel_path"]?.string,
                    let hash = row["blob_hash"]?.string
                else { continue }
                filesByVersion[versionID, default: []]
                    .append(ConfigVersionFileModel(relativePath: path, blobHash: hash))
            }
        }
        for row in reader.rows("SELECT * FROM config_versions") {
            guard let id = row["id"]?.string, let createdAt = row["created_at"]?.double,
                let source = row["source"]?.string
            else { continue }
            let model = ConfigVersionModel(
                versionID: id,
                parentID: row["parent_id"]?.string,
                createdAt: Date(timeIntervalSince1970: createdAt),
                name: row["name"]?.string,
                source: source,
                addedLines: row["added_lines"]?.int ?? 0,
                removedLines: row["removed_lines"]?.int ?? 0,
                filesChanged: row["files_changed"]?.int ?? 0)
            modelContext.insert(model)
            model.files = filesByVersion[id] ?? []
        }
    }

    private static func retireLegacyDatabase(at url: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: source.path + ".imported")
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: source, to: destination)
        }
    }
}
