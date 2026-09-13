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
    func enqueueSymlinkIssueIfNeeded(_ error: Error, url: URL) {
        guard case .symlinkOutsideGrantedDirectory(_, let target) = error as? SSHFileAccessError else { return }
        let path = target.standardizedFileURL.path
        guard !dismissedSymlinkTargetPaths.contains(path),
            !symlinkAccessQueue.contains(where: { $0.symlinkTarget?.standardizedFileURL.path == path })
        else { return }
        symlinkAccessQueue.append(ConfigReadIssue(url: url, error: error))
    }

    func reportUnreachableExternalPath(_ path: String, reason: ExternalAccessReason) {
        let url = URL(fileURLWithPath: path)
        let key = url.standardizedFileURL.path
        guard !dismissedExternalAccessPaths.contains(key),
            !externalAccessQueue.contains(where: { $0.path.standardizedFileURL.path == key })
        else { return }
        externalAccessQueue.append(ExternalAccessIssue(path: url, reason: reason))
    }

    func readExternalKnownHostsEntries(atPath path: String) -> [KnownHostEntry]? {
        guard let text = try? fileAccess.readText(at: URL(fileURLWithPath: path)) else { return nil }
        return KnownHostsService.parse(text)
    }

    func readExternalRevokedFingerprints(atPath path: String) -> Set<String>? {
        guard let text = try? fileAccess.readText(at: URL(fileURLWithPath: path)) else { return nil }
        return RevokedHostKeysParser.parse(text) { KeyFingerprint.sha256(base64Blob: $0) }
    }

    func applyFix(_ fix: LintFix) {
        switch fix {
        case .setPermissions(let path, let mode, _):
            do {
                try fileAccess.setPermissions(mode, on: URL(fileURLWithPath: path))
                loadKeyFindings()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .grantSymlinkAccess(let target):
            do {
                try fileAccess.requestAccess(toAdditionalDirectory: target.deletingLastPathComponent())
                reload()
            } catch SSHFileAccessError.accessDenied {
            } catch {
                errorMessage = error.localizedDescription
            }
        case .moveWildcardLast(let blockID):
            moveWildcardBlockToEnd(id: blockID)
        case .deleteOrphanedKey, .generateReplacement:
            break
        }
    }

    private func moveWildcardBlockToEnd(id: HostBlock.ID) {
        guard let location = locate(id) else { return }
        let documentURL = documents[location.document].sourceURL
        let lastIndex = documents[location.document].blocks.count
        guard location.block != lastIndex - 1 else { return }
        moveBlocks(in: documentURL, fromOffsets: IndexSet(integer: location.block), toOffset: lastIndex)
    }

    func grantAccessToPendingSymlinkRequest() {
        guard let target = pendingSymlinkAccessRequest?.symlinkTarget else { return }
        applyFix(.grantSymlinkAccess(target: target))
    }

    func dismissPendingSymlinkAccessRequest() {
        guard let target = pendingSymlinkAccessRequest?.symlinkTarget else { return }
        dismissedSymlinkTargetPaths.insert(target.standardizedFileURL.path)
        if !symlinkAccessQueue.isEmpty { symlinkAccessQueue.removeFirst() }
    }

    func grantAccessToPendingExternalAccessRequest() {
        guard let issue = pendingExternalAccessRequest else { return }
        let message: String
        switch issue.reason {
        case .agentSocket(let hopDescription):
            message =
                "“\(issue.path.lastPathComponent)” is the ssh-agent socket configured for "
                + "\(hopDescription). Grant access so SSH Config Manager can reach it."
        case .userKnownHostsFile(let hopDescription):
            message =
                "“\(issue.path.lastPathComponent)” is a UserKnownHostsFile configured for "
                + "\(hopDescription). Grant access so SSH Config Manager can reach it."
        case .revokedHostKeys(let hopDescription):
            message =
                "“\(issue.path.lastPathComponent)” is the RevokedHostKeys file configured for "
                + "\(hopDescription). Grant access so SSH Config Manager can reach it."
        }
        do {
            try fileAccess.requestAccess(
                toAdditionalDirectory: issue.path.deletingLastPathComponent(),
                message: message)
            if !externalAccessQueue.isEmpty { externalAccessQueue.removeFirst() }
        } catch SSHFileAccessError.accessDenied {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissPendingExternalAccessRequest() {
        guard let issue = pendingExternalAccessRequest else { return }
        dismissedExternalAccessPaths.insert(issue.path.standardizedFileURL.path)
        if !externalAccessQueue.isEmpty { externalAccessQueue.removeFirst() }
    }
}
