import Foundation
import SQLite3
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
struct LegacyImportTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("legacy-import-\(UUID().uuidString)", isDirectory: true)

    private static let tunnelID = UUID()
    private static let mappingID = UUID()
    private static let groupID = UUID()

    private func makeLegacyDatabase() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sshconfigmanager.sqlite3")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let statements = [
            "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "CREATE TABLE tunnels (id TEXT PRIMARY KEY, position INTEGER NOT NULL, name TEXT NOT NULL, host_alias TEXT NOT NULL, mode TEXT NOT NULL, autostart INTEGER NOT NULL)",
            "CREATE TABLE port_mappings (id TEXT PRIMARY KEY, tunnel_id TEXT NOT NULL, position INTEGER NOT NULL, bind_address TEXT NOT NULL, listen_port INTEGER NOT NULL, target_host TEXT NOT NULL, target_port INTEGER NOT NULL, has_web_ui INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE config_blobs (hash TEXT PRIMARY KEY, data BLOB NOT NULL, size INTEGER NOT NULL)",
            "CREATE TABLE config_versions (id TEXT PRIMARY KEY, parent_id TEXT, created_at REAL NOT NULL, name TEXT, source TEXT NOT NULL, added_lines INTEGER NOT NULL DEFAULT 0, removed_lines INTEGER NOT NULL DEFAULT 0, files_changed INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE config_version_files (version_id TEXT NOT NULL, rel_path TEXT NOT NULL, blob_hash TEXT NOT NULL, PRIMARY KEY (version_id, rel_path))",
            "CREATE TABLE host_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL, file_path TEXT, sort_index INTEGER NOT NULL)",
            "CREATE TABLE host_key_checks (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id TEXT NOT NULL, host_title TEXT NOT NULL, display_name TEXT NOT NULL, host_token TEXT NOT NULL, key_type TEXT NOT NULL, fingerprint TEXT NOT NULL, server_openssh TEXT NOT NULL, outcome TEXT NOT NULL, checked_at REAL NOT NULL)",
            "INSERT INTO settings VALUES ('autosaveEnabled', '0'), ('configHistoryHead', 'v2')",
            "INSERT INTO tunnels VALUES ('\(Self.tunnelID.uuidString)', 0, 'Postgres', 'bastion', 'local', 1)",
            "INSERT INTO port_mappings VALUES ('\(Self.mappingID.uuidString)', '\(Self.tunnelID.uuidString)', 0, '127.0.0.1', 5432, 'db.internal', 5432, 1)",
            "INSERT INTO config_blobs VALUES ('hash-a', X'0102', 2), ('hash-b', X'0304', 2)",
            "INSERT INTO config_versions VALUES ('v1', NULL, 100, NULL, 'initial', 3, 0, 1), ('v2', 'v1', 200, 'Named', 'manual', 1, 1, 1)",
            "INSERT INTO config_version_files VALUES ('v1', 'config', 'hash-a'), ('v2', 'config', 'hash-b')",
            "INSERT INTO host_groups VALUES ('\(Self.groupID.uuidString)', 'Production', NULL, 0)",
            "INSERT INTO host_key_checks (group_id, host_title, display_name, host_token, key_type, fingerprint, server_openssh, outcome, checked_at) VALUES ('bastion', 'bastion', 'bastion', 'bastion', 'ssh-ed25519', 'SHA256:x', 'OpenSSH_9.8', 'match', 300)",
        ]
        for sql in statements {
            try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
        }
        return url
    }

    @Test func importsEveryLegacyTable() async throws {
        let legacyURL = try makeLegacyDatabase()
        let database = try AppDatabase(
            url: directory.appendingPathComponent("SSHConfigManager.store"),
            legacy: AppDatabase.LegacySources(databaseURL: legacyURL))

        let settings = try await database.loadSettings()
        #expect(settings["autosaveEnabled"] == "0")
        #expect(settings[ConfigHistoryStore.headSettingKey] == "v2")

        let tunnels = try await database.load()
        let tunnel = try #require(tunnels.first)
        #expect(tunnels.count == 1)
        #expect(tunnel.id == Self.tunnelID)
        #expect(tunnel.autostart)
        #expect(tunnel.mappings.first?.id == Self.mappingID)
        #expect(tunnel.mappings.first?.hasWebUI == true)

        let versions = try await database.loadVersions()
        #expect(versions.map(\.id) == ["v2", "v1"])
        #expect(versions.first?.parentID == "v1")
        #expect(versions.first?.name == "Named")
        #expect(try await database.versionFiles("v2").first?.blobHash == "hash-b")
        #expect(try await database.blobData("hash-a") == Data([0x01, 0x02]))

        #expect(try await database.loadGroups().first?.id == Self.groupID)
        #expect(try await database.loadLatestHostKeyChecks().first?.fingerprint == "SHA256:x")

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyURL.path + ".imported"))
    }

    @Test func importsFavoritesAndTagsFromDefaults() async throws {
        let suite = "legacy-import-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["bastion"], forKey: AppDatabase.legacyFavoritesKey)
        defaults.set(["bastion": ["production"], "web": ["group/Web"]], forKey: AppDatabase.legacyTagsKey)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase(
            url: directory.appendingPathComponent("SSHConfigManager.store"),
            legacy: AppDatabase.LegacySources(defaultsSuiteName: suite))

        let metadata = try await database.loadHostMetadata()
        #expect(metadata.favoriteAliases == ["bastion"])
        #expect(metadata.tagsByAlias == ["bastion": ["production"], "web": ["group/Web"]])
        #expect(defaults.object(forKey: AppDatabase.legacyTagsKey) == nil)
    }

    @Test func skipsImportWhenStoreAlreadyHasData() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("SSHConfigManager.store")
        let existing = try AppDatabase(url: storeURL)
        try await existing.setSetting("autosaveEnabled", "1")

        let legacyURL = try makeLegacyDatabase()
        let reopened = try AppDatabase(url: storeURL, legacy: AppDatabase.LegacySources(databaseURL: legacyURL))
        #expect(try await reopened.loadSettings()["autosaveEnabled"] == "1")
        #expect(try await reopened.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    }
}
