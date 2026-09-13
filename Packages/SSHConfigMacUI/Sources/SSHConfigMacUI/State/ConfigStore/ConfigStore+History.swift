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
    private func currentTrackedFiles() -> [(relPath: String, text: String)] {
        documents.map { (relPath(for: $0.sourceURL), SSHConfigSerializer.serialize($0)) }
    }

    func trackedFilesSnapshot() -> [(relPath: String, text: String)] { currentTrackedFiles() }

    func applyRemoteSnapshot(_ files: [(relPath: String, text: String)]) throws {
        let allowed = Set(documents.map { relPath(for: $0.sourceURL) }).union(["config"])
        var applied: [(relPath: String, text: String)] = []
        for (relPath, text) in files {
            guard Self.isAcceptableSnapshotPath(relPath, allowed: allowed) else { continue }
            guard let url = url(forRelPath: relPath) else { continue }
            try fileAccess.writeText(text, to: url, makeBackup: false)
            applied.append((relPath: relPath, text: text))
        }
        reload()
        guard settings.configHistoryEnabled, !applied.isEmpty else { return }
        history.scheduleCommit(files: applied, source: .remote, maxVersions: settings.maxConfigVersions)
    }

    static func isAcceptableSnapshotPath(_ rel: String, allowed: Set<String>) -> Bool {
        if rel.hasPrefix("/") { return allowed.contains(rel) }
        if rel.split(separator: "/").contains("..") { return false }
        let basename = (rel as NSString).lastPathComponent
        if isSensitiveSSHFilename(basename), !allowed.contains(rel) { return false }
        return allowed.contains(rel)
    }

    static func isSensitiveSSHFilename(_ name: String) -> Bool {
        if name == "authorized_keys" || name == "authorized_keys2" { return true }
        if name == "known_hosts" || name == "known_hosts2" { return true }
        if name.hasPrefix("id_") { return true }
        if name.hasSuffix(".pub") { return true }
        return false
    }

    func relPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let base = fileAccess.directoryURL?.standardizedFileURL.path else {
            return path
        }
        if path == base { return url.lastPathComponent }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        return path
    }

    func url(forRelPath rel: String) -> URL? {
        if rel.hasPrefix("/") { return URL(fileURLWithPath: rel) }
        return fileAccess.directoryURL?.appendingPathComponent(rel)
    }

    func recordHistory(_ source: ConfigVersionSource) {
        guard settings.configHistoryEnabled else { return }
        let files = currentTrackedFiles()
        guard !files.isEmpty else { return }
        history.scheduleCommit(files: files, source: source, maxVersions: settings.maxConfigVersions)
    }

    func startHistoryOnLaunch() {
        guard !historyLaunchStarted else { return }
        historyLaunchStarted = true
        guard settings.configHistoryEnabled else { return }
        let max = settings.maxConfigVersions
        let legacy = legacyBackupsOldestFirst()
        let baseline = currentTrackedFiles()
        historyLaunchTask = Task { @MainActor in
            await history.waitUntilLoaded()
            if !history.migratedLegacy {
                for backup in legacy {
                    history.scheduleCommit(files: [backup], source: .imported, maxVersions: max)
                }
                await history.markLegacyMigrated()
            }
            if !baseline.isEmpty {
                history.scheduleCommit(files: baseline, source: .initial, maxVersions: max)
            }
        }
    }

    private func legacyBackupsOldestFirst() -> [(relPath: String, text: String)] {
        guard let mainName = mainDocumentURL?.lastPathComponent else { return [] }
        let relPath = relPath(for: mainDocumentURL ?? URL(fileURLWithPath: mainName))
        return fileAccess.backups(forFileNamed: mainName)
            .sorted { $0.date < $1.date }
            .compactMap { info in
                guard let text = try? fileAccess.readBackup(info) else { return nil }
                return (relPath, text)
            }
    }

    func restoreVersion(_ versionID: String) {
        Task { @MainActor in await performRestore(versionID) }
    }

    func performRestore(_ versionID: String) async {
        do {
            let files = try await history.restore(to: versionID)
            let targetRelPaths = Set(files.map(\.relPath))
            for document in documents {
                let rel = relPath(for: document.sourceURL)
                guard !targetRelPaths.contains(rel) else { continue }
                try? fileAccess.deleteFile(at: document.sourceURL, makeBackup: false)
                groups.removeAll {
                    $0.fileURL?.standardizedFileURL.path == document.sourceURL.standardizedFileURL.path
                }
            }
            persistGroups()
            for (rel, text) in files {
                guard let url = url(forRelPath: rel) else { continue }
                try fileAccess.writeText(text, to: url, makeBackup: false)
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var workingTreeDisplayText: String {
        ConfigHistoryStore.combinedDisplay(currentTrackedFiles())
    }

    func currentText(forRelPath relPath: String) -> String? {
        guard let document = documents.first(where: { self.relPath(for: $0.sourceURL) == relPath }) else {
            return nil
        }
        return SSHConfigSerializer.serialize(document)
    }

    func isMainConfigRelPath(_ relPath: String) -> Bool {
        guard let main = documents.first else { return false }
        return self.relPath(for: main.sourceURL) == relPath
    }

    func groupName(forRelPath relPath: String) -> String? {
        guard let path = url(forRelPath: relPath)?.standardizedFileURL.path else { return nil }
        return groups.first { $0.fileURL?.standardizedFileURL.path == path }?.name
    }

    func snapshotNow(name: String? = nil) {
        flushPendingSave()
        recordHistory(.manual)
        guard let name else { return }
        Task { @MainActor in await applySnapshotName(name) }
    }

    func applySnapshotName(_ name: String) async {
        await history.waitForPendingWrites()
        guard let headID = history.headID else { return }
        await history.rename(headID, to: name)
    }

    func renameVersion(_ versionID: String, to name: String?) {
        Task { await history.rename(versionID, to: name) }
    }

    func clearHistory() {
        Task { await history.clearHistory() }
    }
}
