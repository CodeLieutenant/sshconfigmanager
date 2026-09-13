//
//  ConfigHistoryStore.swift
//  sshconfigmanager
//
//  The config version history: a git-style timeline of every meaningful change to
//  the ssh_config (and its includes), persisted in SQLite. Each commit is a node in
//  a tree (`parentID`); editing from an older node forks a branch, so nothing is
//  ever discarded. Content is content-addressed: each file's bytes are hashed and
//  stored once (zlib-compressed), so unchanged files across versions cost nothing
//  and any version is reconstructable in a single decompress — instant restore that
//  never loses data. See `AppDatabase` for the schema.
//
//  Mirrors `AppSettings`' injectable-database pattern so tests can pass a temp-file
//  database (or nil to disable history entirely).
//

import CryptoKit
import Foundation
import Observation
import SSHConfigCore

/// One node in the version timeline (metadata only; file contents live in blobs).
struct ConfigVersion: Identifiable, Equatable, Sendable {
    let id: String
    /// The version this one was edited from. `nil` = a root (a branch start).
    let parentID: String?
    let createdAt: Date
    var name: String?
    /// How the version was produced (see `ConfigVersionSource`).
    let source: String
    /// Diff stats versus the parent, summed across files (for the list display).
    let addedLines: Int
    let removedLines: Int
    let filesChanged: Int
}

/// Why a version was recorded. Stored as the raw string in `config_versions.source`.
enum ConfigVersionSource: String, Sendable {
    case initial // the first baseline captured on load
    case autosave // a settled editing burst written by the app
    case manual // an explicit user snapshot
    case restore // produced by restoring/forking (rarely used; restore is a no-op commit)
    case external // the file changed on disk outside the app
    case imported = "import" // migrated from a legacy .bak backup
    case remote
}

@MainActor
@Observable
final class ConfigHistoryStore {
    /// Key under which the current HEAD version id is stored in the `settings` table.
    static let headSettingKey = "configHistoryHead"
    /// Key marking that the one-time import of legacy `.bak` backups has run.
    static let migratedSettingKey = "configHistoryMigrated"

    /// The timeline, newest-first (the order the history view renders).
    private(set) var versions: [ConfigVersion] = []
    /// The version the working tree currently matches. New commits parent to it;
    /// restoring moves it (and a subsequent edit forks from there).
    private(set) var headID: String?
    /// Whether the legacy `.bak` import has already happened (so it runs once ever).
    private(set) var migratedLegacy = false

    private let database: AppDatabase?
    /// Loads the timeline + HEAD once at startup; every commit awaits it so the no-op
    /// guard sees the right HEAD (mirrors `AppSettings.loadTask`).
    private var bootstrapTask: Task<Void, Never>?
    /// Serial chain so fire-and-forget commits land in submission order (mirrors
    /// `AppSettings.persistTask`).
    private var writeTask: Task<Void, Never>?

    init(database: AppDatabase? = AppDatabase.shared) {
        self.database = database
        #if DEBUG
            // Screenshot/preview harness: seed a presentable timeline (+ snapshot texts
            // so diffs render) and skip the real bootstrap so it isn't clobbered.
            if ScreenshotMode.isActive {
                seedScreenshotHistory()
                return
            }
        #endif
        bootstrapTask = Task { [weak self] in await self?.bootstrap() }
    }

    #if DEBUG
        /// In-memory snapshot text per version, used only in screenshot mode so the diff
        /// pane has content without writing to the database.
        private var screenshotTexts: [String: String] = [:]

        private func seedScreenshotHistory() {
            // An evolving config; the HEAD change (v6 vs v5) rewrites the staging-api
            // block so the selected diff shows several additions AND removals — i.e. the
            // diff viewer at its best, not a one-line change.
            let pwBare = "Host production-web\n    HostName web.prod.example.com\n    User deploy\n"
            let pw = pwBare + "    Port 22\n"
            let bastion = "\nHost db-bastion\n    HostName bastion.example.com\n    User admin\n"
            let bastionK = bastion + "    IdentityFile ~/.ssh/id_ed25519\n"
            let stagingOld =
                "\nHost staging-api\n    HostName api.staging.example.com\n    User deploy\n    Port 2222\n    IdentityFile ~/.ssh/id_rsa\n"
            let stagingNew =
                "\nHost staging-api\n    HostName api.staging.example.com\n    User ci-runner\n    ProxyJump db-bastion\n    ForwardAgent yes\n    IdentityFile ~/.ssh/id_ed25519\n"

            let t1 = pwBare
            let t2 = pw
            let t3 = pw + bastion
            let t4 = pw + bastionK
            let t5 = pw + bastionK + stagingOld
            let t6 = pw + bastionK + stagingNew
            screenshotTexts = ["v1": t1, "v2": t2, "v3": t3, "v4": t4, "v5": t5, "v6": t6]

            let now = Date()
            func ver(
                _ id: String, _ parent: String?, _ ago: TimeInterval, _ name: String?,
                _ source: ConfigVersionSource, _ add: Int, _ rem: Int
            ) -> ConfigVersion {
                ConfigVersion(
                    id: id, parentID: parent, createdAt: now.addingTimeInterval(-ago),
                    name: name, source: source.rawValue,
                    addedLines: add, removedLines: rem, filesChanged: 1)
            }
            // Newest-first (the order the timeline renders). HEAD (v6) auto-selects.
            versions = [
                ver("v6", "v5", 300, "Harden staging-api: bastion + agent", .manual, 4, 3),
                ver("v5", "v4", 5_400, "Add staging-api", .autosave, 5, 0),
                ver("v4", "v3", 90_000, "Add db-bastion identity key", .manual, 1, 0),
                ver("v3", "v2", 176_400, nil, .external, 3, 0),
                ver("v2", "v1", 262_800, "Pin production-web port", .autosave, 1, 0),
                ver("v1", nil, 349_200, "Initial import", .initial, 0, 0),
            ]
            headID = "v6"
        }
    #endif

    // MARK: - Loading

    /// Loads the timeline and HEAD from the database.
    private func bootstrap() async {
        guard let database else { return }
        versions = (try? await database.loadVersions()) ?? []
        let settings = (try? await database.loadSettings()) ?? [:]
        headID = settings[Self.headSettingKey]
        migratedLegacy = settings[Self.migratedSettingKey] == "1"
    }

    /// Awaits the initial load (call before reading `headID`/`versions` at launch).
    func waitUntilLoaded() async { await bootstrapTask?.value }

    /// Records that the legacy `.bak` import has completed.
    func markLegacyMigrated() async {
        migratedLegacy = true
        try? await database?.setSetting(Self.migratedSettingKey, "1")
    }

    /// Re-reads the timeline list (HEAD is kept authoritative locally).
    func refresh() async {
        #if DEBUG
            if ScreenshotMode.isActive { return } // keep the seeded timeline
        #endif
        guard let database else { return }
        versions = (try? await database.loadVersions()) ?? []
    }

    // MARK: - Committing

    /// Records a new version capturing `files` (each a `(relPath, text)` of a tracked
    /// document), parented to the current HEAD. Ordered and fire-and-forget — the
    /// caller doesn't await. A no-op if nothing changed since HEAD.
    func scheduleCommit(
        files: [(relPath: String, text: String)],
        source: ConfigVersionSource,
        name: String? = nil,
        maxVersions: Int
    ) {
        #if DEBUG
            if ScreenshotMode.isActive { return } // don't write the fixture into the real DB
        #endif
        let previous = writeTask
        writeTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.commit(files: files, source: source, name: name, maxVersions: maxVersions)
        }
    }

    /// Awaitable commit (used by tests and where ordering with a following read
    /// matters). Returns once the version is persisted.
    func commit(
        files: [(relPath: String, text: String)],
        source: ConfigVersionSource,
        name: String? = nil,
        maxVersions: Int
    ) async {
        guard let database else { return }
        await bootstrapTask?.value // ensure HEAD/versions are loaded first

        // Encode every file: content hash, compressed payload, uncompressed size.
        var payloads: [AppDatabase.BlobPayload] = []
        var newManifest: [String: String] = [:] // relPath -> content hash
        var newTexts: [String: String] = [:]
        for (relPath, text) in files {
            let raw = Data(text.utf8)
            let hash = Self.sha256Hex(raw)
            newManifest[relPath] = hash
            newTexts[relPath] = text
            payloads.append(
                .init(
                    relPath: relPath, hash: hash,
                    compressed: Self.encode(raw), size: raw.count))
        }

        // The HEAD manifest, for the no-op guard and the diff stats.
        var oldManifest: [String: String] = [:]
        if let headID {
            let headFiles = (try? await database.versionFiles(headID)) ?? []
            oldManifest = Dictionary(
                headFiles.map { ($0.relPath, $0.blobHash) },
                uniquingKeysWith: { first, _ in first })
            // Nothing changed since HEAD — don't clutter the timeline.
            if oldManifest == newManifest { return }
        }

        // Diff stats versus the parent, summed over the files that actually changed.
        var added = 0
        var removed = 0
        var changed = 0
        for path in Set(newManifest.keys).union(oldManifest.keys) {
            let newHash = newManifest[path]
            let oldHash = oldManifest[path]
            guard newHash != oldHash else { continue }
            changed += 1
            let oldText: String
            if let oldHash { oldText = (await text(forBlob: oldHash)) ?? "" } else { oldText = "" }
            let stats = TextDiff.stat(old: oldText, new: newTexts[path] ?? "")
            added += stats.added
            removed += stats.removed
        }

        // The very first node (no parent) reads as the baseline, unless it's a
        // migrated backup forming the start of the imported chain.
        let effectiveSource = (headID == nil && source != .imported) ? .initial : source
        let version = ConfigVersion(
            id: UUID().uuidString, parentID: headID, createdAt: Date(),
            name: name, source: effectiveSource.rawValue,
            addedLines: added, removedLines: removed, filesChanged: changed)

        do {
            try await database.insertVersion(version, files: payloads, headKey: Self.headSettingKey)
            headID = version.id
            try? await database.pruneToCap(maxVersions, head: version.id)
            await refresh()
        } catch {
            // History is best-effort; never surface a commit failure to the user's edit.
        }
    }

    // MARK: - Restore & reconstruction

    /// Materializes `versionID`: returns each tracked file's `(relPath, text)` as it
    /// was at that version, and moves HEAD there (so a later edit forks from it). The
    /// caller writes the texts to disk. Non-destructive — no versions are deleted.
    func restore(to versionID: String) async throws -> [(relPath: String, text: String)] {
        guard let database else { return [] }
        let manifest = try await database.versionFiles(versionID)
        var result: [(relPath: String, text: String)] = []
        for (relPath, blobHash) in manifest {
            result.append((relPath, (await text(forBlob: blobHash)) ?? ""))
        }
        try await database.setSetting(Self.headSettingKey, versionID)
        headID = versionID
        return result
    }

    /// Reconstructs all of a version's files (sorted by path) — for the diff pane.
    func reconstruct(_ versionID: String) async -> [(relPath: String, text: String)] {
        guard let database, let manifest = try? await database.versionFiles(versionID) else { return [] }
        var result: [(relPath: String, text: String)] = []
        for (relPath, blobHash) in manifest {
            result.append((relPath, (await text(forBlob: blobHash)) ?? ""))
        }
        return result
    }

    /// A version's full content as one display string (for diffing/viewing).
    func displayText(for versionID: String) async -> String {
        #if DEBUG
            if let seeded = screenshotTexts[versionID] { return seeded }
        #endif
        return Self.combinedDisplay(await reconstruct(versionID))
    }

    /// Flattens a multi-file snapshot into one string for display/diff. A single file
    /// is shown verbatim; multiple files get `# ===== <path> =====` separators.
    static func combinedDisplay(_ files: [(relPath: String, text: String)]) -> String {
        let sorted = files.sorted { $0.relPath < $1.relPath }
        if sorted.count <= 1 { return sorted.first?.text ?? "" }
        return sorted.map { "# ===== \($0.relPath) =====\n\($0.text)" }.joined(separator: "\n")
    }

    /// The decompressed text of a single blob.
    private func text(forBlob hash: String) async -> String? {
        guard let database, let data = try? await database.blobData(hash) else { return nil }
        return Self.decode(data)
    }

    // MARK: - Per-file browsing

    /// How a single tracked file changed within a version, relative to its parent.
    enum FileChangeKind: String, Sendable {
        case added, modified, removed
    }

    /// One tracked file's status within a version's commit (metadata only — see
    /// `fileText(_:at:)` for content).
    struct FileChange: Identifiable, Equatable, Sendable {
        var id: String { relPath }
        let relPath: String
        let kind: FileChangeKind
    }

    /// Which tracked files actually changed in `versionID` relative to its parent —
    /// the per-file breakdown behind the aggregate `addedLines`/`removedLines`/
    /// `filesChanged` already on `ConfigVersion`. Reuses the manifest each commit
    /// already writes (`config_version_files`), so no schema change was needed to
    /// surface it. Powers the version history UI's per-file list, so a change to an
    /// `Include`d group file is visible on its own instead of only inside the
    /// flattened `combinedDisplay` blob.
    func fileChanges(for versionID: String) async -> [FileChange] {
        #if DEBUG
            if ScreenshotMode.isActive {
                guard let version = versions.first(where: { $0.id == versionID }), version.filesChanged > 0
                else { return [] }
                return [FileChange(relPath: "config", kind: .modified)]
            }
        #endif
        guard let database, let version = versions.first(where: { $0.id == versionID }) else { return [] }
        let newManifest = (try? await database.versionFiles(versionID)) ?? []
        let newByPath = Dictionary(
            newManifest.map { ($0.relPath, $0.blobHash) },
            uniquingKeysWith: { first, _ in first })
        var oldByPath: [String: String] = [:]
        if let parentID = version.parentID {
            let oldManifest = (try? await database.versionFiles(parentID)) ?? []
            oldByPath = Dictionary(
                oldManifest.map { ($0.relPath, $0.blobHash) },
                uniquingKeysWith: { first, _ in first })
        }
        return Set(newByPath.keys).union(oldByPath.keys).sorted().compactMap { path in
            let newHash = newByPath[path]
            let oldHash = oldByPath[path]
            guard newHash != oldHash else { return nil }
            let kind: FileChangeKind = oldHash == nil ? .added : (newHash == nil ? .removed : .modified)
            return FileChange(relPath: path, kind: kind)
        }
    }

    /// One tracked file's text as of `versionID` — `""` if that version didn't
    /// track the file (e.g. before it existed, or after it was removed). The
    /// single-file analogue of `reconstruct(_:)`.
    func fileText(_ relPath: String, at versionID: String) async -> String {
        #if DEBUG
            if let seeded = screenshotTexts[versionID] { return seeded }
        #endif
        guard let database else { return "" }
        let manifest = (try? await database.versionFiles(versionID)) ?? []
        guard let hash = manifest.first(where: { $0.relPath == relPath })?.blobHash else { return "" }
        return (await text(forBlob: hash)) ?? ""
    }

    // MARK: - Editing the timeline

    /// Sets or clears a version's user-given name.
    func rename(_ versionID: String, to name: String?) async {
        guard let database else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try? await database.renameVersion(versionID, name: value)
        await refresh()
    }

    /// Wipes the entire history and clears HEAD.
    func clearHistory() async {
        guard let database else { return }
        try? await database.clearHistory(headKey: Self.headSettingKey)
        headID = nil
        versions = []
    }

    // MARK: - Test support

    /// Awaits any in-flight fire-and-forget commit (tests).
    func waitForPendingWrites() async { await writeTask?.value }

    // MARK: - Codec (content-addressing + compression)

    /// SHA-256 (hex) of the raw, uncompressed bytes — the content address.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Encodes bytes for storage with a 1-byte mode header: `0x01` = zlib, `0x00` =
    /// stored raw. The header makes decoding robust even for inputs the compressor
    /// would refuse (empty) or expand (tiny).
    static func encode(_ raw: Data) -> Data {
        guard !raw.isEmpty else { return Data([0x00]) }
        if let zlib = try? (raw as NSData).compressed(using: .zlib) as Data {
            return Data([0x01]) + zlib
        }
        return Data([0x00]) + raw
    }

    /// Reverses `encode`, yielding UTF-8 text.
    static func decode(_ stored: Data) -> String {
        guard let marker = stored.first else { return "" }
        let body = Data(stored.dropFirst())
        if marker == 0x01, let raw = try? (body as NSData).decompressed(using: .zlib) as Data {
            return String(decoding: raw, as: UTF8.self)
        }
        return String(decoding: body, as: UTF8.self)
    }
}
