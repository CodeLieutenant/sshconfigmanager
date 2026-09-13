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
    func ensureConfigDInclude(configURL: URL) -> ConfigReadIssue? {
        guard let dir = fileAccess.directoryURL else { return nil }
        let configDURL = dir.appendingPathComponent("config.d", isDirectory: true)
        guard FileManager.default.fileExists(atPath: configDURL.path) else { return nil }

        let text: String
        do {
            text = try fileAccess.readText(at: configURL)
        } catch {
            Log.config.error("failed to add config.d Include: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let alreadyIncluded = text.components(separatedBy: .newlines).contains { line in
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            return lower.hasPrefix("include") && lower.contains("config.d")
        }
        guard !alreadyIncluded else { return nil }

        let directive = "Include config.d/*\n"
        let newText = text.isEmpty ? directive : directive + "\n" + text
        do {
            try fileAccess.writeText(newText, to: configURL, makeBackup: !text.isEmpty)
            Log.config.notice("added 'Include config.d/*' to config (config.d/ directory detected)")
            return nil
        } catch {
            Log.config.error("failed to add config.d Include: \(error.localizedDescription, privacy: .public)")
            return ConfigReadIssue(url: configURL, error: error)
        }
    }

    func prepareGroupFile(fileName: String, in directory: URL?) -> URL? {
        let usingDefaultDirectory = directory == nil
        guard let resolvedDirectory = directory ?? fileAccess.defaultGroupsDirectory else {
            errorMessage = "No location is available for this group's file — grant access to ~/.ssh first."
            return nil
        }
        do {
            try fileAccess.ensureDirectoryExists(at: resolvedDirectory)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        var resolvedFileName = fileName
        if usingDefaultDirectory, (resolvedFileName as NSString).pathExtension.lowercased() != "conf" {
            resolvedFileName = (resolvedFileName as NSString).deletingPathExtension + ".conf"
        }
        return resolvedDirectory.appendingPathComponent(resolvedFileName)
    }

    func pickAdditionalDirectory() -> URL? {
        try? fileAccess.requestAccess(
            toAdditionalDirectory: fileAccess.directoryURL ?? FileManager.default.homeDirectoryForCurrentUser,
            message: "Choose a folder for this group's file. SSH Config Manager will remember it.")
    }

    private func includeValue(for fileURL: URL) -> String {
        SSHFileAccess.portablePath(fileURL.standardizedFileURL.path)
    }

    private func isInDefaultGroupsDirectory(_ fileURL: URL) -> Bool {
        guard let defaultDir = fileAccess.defaultGroupsDirectory else { return false }
        return fileURL.deletingLastPathComponent().standardizedFileURL.path
            == defaultDir.standardizedFileURL.path
    }

    func insertIncludeDirective(for fileURL: URL) {
        guard !documents.isEmpty else { return }
        let value: String
        if isInDefaultGroupsDirectory(fileURL) {
            guard let defaultDir = fileAccess.defaultGroupsDirectory else { return }
            value = SSHFileAccess.portablePath(defaultDir.standardizedFileURL.path) + "/*.conf"
        } else {
            value = includeValue(for: fileURL)
        }
        guard !documents[0].includeDirectives.contains(where: { $0.value == value }) else { return }
        documents[0].appendPreamble(directive: Directive(keyword: "Include", value: value, isDirty: true))
    }

    func removeIncludeDirective(forFilePath filePath: String) {
        guard !isInDefaultGroupsDirectory(URL(fileURLWithPath: filePath)) else { return }
        let value = SSHFileAccess.portablePath(filePath)
        for index in documents.indices {
            documents[index].preamble.removeAll {
                if case .directive(let d) = $0, d.canonicalKeyword == "include", d.value == value { return true }
                return false
            }
        }
    }
}
