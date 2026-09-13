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
    var existingFileNames: Set<String> {
        Set((try? fileAccess.directoryFiles())?.map(\.lastPathComponent) ?? [])
    }

    var lintFindings: [LintFinding] {
        ConfigLinter.lint(documents, existingFiles: existingFileNames, graph: configGraph)
    }

    private var configReadFindings: [LintFinding] {
        configReadIssues.map { issue in
            LintFinding(
                severity: .error, blockID: nil,
                title: "Can't read “\(issue.url.lastPathComponent)”",
                detail: issue.error.localizedDescription,
                fix: issue.symlinkTarget.map { .grantSymlinkAccess(target: $0) }
            )
        }
    }

    var serverKeyFindings: [LintFinding] {
        let enabled = settings.auditServerAlgorithms
        if let cached = serverKeyFindingsCache, cached.enabled == enabled { return cached.findings }
        let findings = enabled ? ServerAlgorithmAudit.knownHostsFindings(knownHosts) : []
        serverKeyFindingsCache = (enabled, findings)
        return findings
    }

    var allFindings: [LintFinding] {
        (lintFindings + keyFindings + serverKeyFindings + configReadFindings)
            .sorted { $0.severity > $1.severity }
    }
}
