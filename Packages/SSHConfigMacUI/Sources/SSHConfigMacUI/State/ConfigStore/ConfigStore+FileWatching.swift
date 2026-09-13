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
    func captureModificationDates() {
        for document in documents {
            modificationDates[document.sourceURL] = modificationDate(of: document.sourceURL)
        }
    }

    func modificationDate(of url: URL) -> Date? {
        let resolved = url.resolvingSymlinksInPath().path
        return (try? FileManager.default.attributesOfItem(atPath: resolved)[.modificationDate]) as? Date
    }

    @discardableResult
    func checkForExternalChanges(trigger: String = "focus-regain") -> Bool {
        guard hasAccess else { return false }
        if isDirty {
            if autosaveEnabled {
                flushPendingSave()
            } else {
                return documents.contains { document in
                    modificationDate(of: document.sourceURL) != modificationDates[document.sourceURL]
                }
            }
        }
        let changed = documents.contains { document in
            modificationDate(of: document.sourceURL) != modificationDates[document.sourceURL]
        }
        if changed { reload(trigger: trigger) }
        return changed
    }

    func updateFileWatchers() {
        guard hasAccess, settings.liveFileWatchEnabled else {
            stopFileWatchers()
            return
        }

        let currentURLs = Set(documents.map(\.sourceURL))
        for url in watchedDocumentURLs where !currentURLs.contains(url) {
            fileWatcher.remove(url: url)
        }
        for url in currentURLs where !watchedDocumentURLs.contains(url) {
            fileWatcher.add(url: url) { [weak self] in self?.handleConfigFileChanged() }
        }
        watchedDocumentURLs = currentURLs

        if knownHostsFileURL != watchedKnownHostsURL {
            if let old = watchedKnownHostsURL { fileWatcher.remove(url: old) }
            watchedKnownHostsURL = knownHostsFileURL
            if let url = watchedKnownHostsURL {
                fileWatcher.add(url: url) { [weak self] in self?.handleKnownHostsFileChanged() }
            }
        }
    }

    func stopFileWatchers() {
        fileWatcher.removeAll()
        watchedDocumentURLs.removeAll()
        watchedKnownHostsURL = nil
        configChangeCoalesceTask?.cancel()
        configChangeCoalesceTask = nil
    }

    private func handleConfigFileChanged() {
        configChangeCoalesceTask?.cancel()
        configChangeCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.performConfigFileChangeCheck()
        }
    }

    private func performConfigFileChangeCheck() {
        let willReload = !(isDirty && !autosaveEnabled)
        guard checkForExternalChanges(trigger: "external-file-change") else { return }
        let recordedToHistory = willReload && historyLaunchStarted && settings.configHistoryEnabled
        notifyConfigChanged(recordedToHistory: recordedToHistory)
    }

    private func handleKnownHostsFileChanged() {
        guard let url = knownHostsFileURL else { return }
        guard let text = try? fileAccess.readText(at: url) else { return }
        let fresh = KnownHostsService.parse(text)
        guard fresh.map(\.raw) != knownHosts.map(\.raw) else { return }
        let summary = KnownHostsService.diff(old: knownHosts, new: fresh)
        knownHosts = fresh
        guard !summary.isEmpty else { return }
        externalKnownHostsChange = summary
        notifyKnownHostsChanged(summary)
    }

    static let knownHostsChangeCategoryIdentifier = "knownHostsFileChanged"
    static let configChangeCategoryIdentifier = "configFileChanged"

    private func notifyKnownHostsChanged(_ summary: KnownHostsChangeSummary) {
        let parts = [
            summary.added.isEmpty ? nil : "\(summary.added.count) added",
            summary.removed.isEmpty ? nil : "\(summary.removed.count) removed",
        ].compactMap { $0 }
        deliverLiveFileWatchNotification(
            title: "known_hosts changed",
            body: "\(parts.joined(separator: ", ")) outside SSH Config Manager.",
            category: Self.knownHostsChangeCategoryIdentifier)
    }

    private func notifyConfigChanged(recordedToHistory: Bool) {
        let body =
            recordedToHistory
            ? "Your SSH config was edited outside SSH Config Manager. The change was recorded in Version History."
            : "Your SSH config was edited outside SSH Config Manager."
        deliverLiveFileWatchNotification(
            title: "SSH config changed", body: body, category: Self.configChangeCategoryIdentifier)
    }

    private func deliverLiveFileWatchNotification(title: String, body: String, category: String) {
        guard settings.liveFileWatchNotificationsEnabled else { return }
        let mayRequest = !didRequestFileWatchNotificationAuth
        if mayRequest { didRequestFileWatchNotificationAuth = true }
        Task {
            await Self.deliverNotification(
                title: title, body: body, category: category,
                mayRequestAuthorization: mayRequest)
        }
    }

    private static func deliverNotification(
        title: String, body: String, category: String,
        mayRequestAuthorization: Bool
    ) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        let authorized: Bool
        switch status {
        case .authorized, .provisional: authorized = true
        case .notDetermined where mayRequestAuthorization:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: authorized = false
        }
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        try? await center.add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
