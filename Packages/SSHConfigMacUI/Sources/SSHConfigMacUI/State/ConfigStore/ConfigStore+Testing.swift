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
    #if DEBUG
        func loadForTesting(_ documents: [SSHConfigDocument]) {
            self.documents = documents
            self._inclusionPaths = [:]
            self.configReadIssues = []
            self.symlinkAccessQueue = []
            dirtyURLs.removeAll()
        }

        func useDirectoryForTesting(_ url: URL) {
            fileAccess.useDirectoryForTesting(url)
            hasAccess = true
            grantedDirectoryName = url.lastPathComponent
        }

        func useAdditionalDirectoryForTesting(_ url: URL) {
            fileAccess.useAdditionalDirectoryForTesting(url)
        }

        func runHistoryLaunchForTesting() async {
            startHistoryOnLaunch()
            await historyLaunchTask?.value
            await history.waitForPendingWrites()
        }

        func recordHistoryForTesting(_ source: ConfigVersionSource) async {
            historyLaunchStarted = true
            recordHistory(source)
            await history.waitForPendingWrites()
        }

        func restoreVersionForTesting(_ versionID: String) async {
            await performRestore(versionID)
        }

        func snapshotNowForTesting(name: String? = nil) async {
            flushPendingSave()
            recordHistory(.manual)
            await history.waitForPendingWrites()
            if let name { await applySnapshotName(name) }
        }

        func waitForGroupsLoadedForTesting() async {
            await groupsLoadTask?.value
        }

        static func uiTestDirectory(
            arguments: [String] = ProcessInfo.processInfo.arguments
        ) -> URL? {
            guard let index = arguments.firstIndex(of: "--uitest-ssh-dir"),
                index + 1 < arguments.count
            else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }

        static func createSeededUITestDirectory() -> URL? {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("uitest-ssh", isDirectory: true)
            try? FileManager.default.removeItem(at: base)
            do {
                try seedUITestSSHDirectory(in: base)
                return base
            } catch {
                return nil
            }
        }

        static func seedUITestSSHDirectory(in base: URL) throws {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)

            let privatePEM = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
            func write(_ text: String, _ name: String, mode: Int) throws {
                let url = base.appendingPathComponent(name)
                try text.write(to: url, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            }

            try write(
                "Host web\n    HostName web.example.com\n    IdentityFile ~/.ssh/weakrsa\n",
                "config", mode: 0o600)
            try write(uiTestRSAPublicLine(bits: 1024), "weakrsa.pub", mode: 0o644)
            try write(privatePEM, "weakrsa", mode: 0o600)
            try write(privatePEM, "orphan", mode: 0o644)
        }

        private static func uiTestRSAPublicLine(bits: Int) -> String {
            var modulus = [UInt8](repeating: 0, count: bits / 8)
            modulus[0] = 0x80
            func ssh(_ bytes: [UInt8]) -> [UInt8] {
                let n = UInt32(bytes.count)
                return [
                    UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF),
                    UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF),
                ] + bytes
            }
            let blob = ssh(Array("ssh-rsa".utf8)) + ssh([0x01, 0x00, 0x01]) + ssh([0x00] + modulus)
            return "ssh-rsa " + Data(blob).base64EncodedString() + " weak@host\n"
        }

        func setAgentStateForTesting(_ identities: [AgentIdentity], status: AgentStatus) {
            agentIdentities = identities
            agentStatus = status
        }
    #endif
}
