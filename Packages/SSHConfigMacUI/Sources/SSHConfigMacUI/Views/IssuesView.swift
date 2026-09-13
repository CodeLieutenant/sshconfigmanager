//
//  IssuesView.swift
//  sshconfigmanager
//
//  The config lint / security audit results — restyled to the Liquid Glass redesign: a
//  frosted screen header over a single lifted card of finding rows (severity glyph ·
//  title/detail · inline fix action · chevron). Tapping a row that points at a host
//  navigates to it; the fix actions, deep-links, and delete confirmation are unchanged.
//

import AppKit
import SSHConfigCore
import SwiftUI

struct IssuesView: View {
    @Environment(ConfigStore.self) private var store
    @Binding var selection: SidebarSelection?

    /// The orphaned-key delete awaiting confirmation, if any.
    @State private var pendingDelete: LintFix?
    @State private var toastMessage: String?

    private var findings: [LintFinding] { store.allFindings }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                tile: (icon: "exclamationmark.triangle.fill", color: TilePalette.issues),
                title: "Issues",
                subtitle: findings.isEmpty
                    ? "All clear"
                    : "\(findings.count) finding\(findings.count == 1 ? "" : "s")")
            if findings.isEmpty {
                ContentUnavailableView(
                    "No issues found", systemImage: "checkmark.seal",
                    description: Text("Your SSH config looks clean.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Card {
                        ForEach(findings) { finding in
                            row(finding)
                        }
                    }
                    .padding(Spacing.xxxl)
                }
            }
        }
        .background(WindowWash())
        .confirmationDialog(
            "Delete this key?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { fix in
            if case .deleteOrphanedKey(let priv, let pub, let name) = fix {
                Button("Delete “\(name)”", role: .destructive) {
                    store.deleteOrphanedKey(privateKeyPath: priv, publicKeyPath: pub)
                    toastMessage = "Key deleted"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                "The key files are moved to a backup folder inside your SSH folder first. "
                    + "Only do this if no other machine still uses this key.")
        }
        .toast($toastMessage)
    }

    private func row(_ finding: LintFinding) -> some View {
        CardRow(minHeight: 54) {
            Image(systemName: finding.severity.symbol)
                .foregroundStyle(color(for: finding.severity))
                .font(.system(size: 17))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.system(size: 13, weight: .semibold))
                Text(finding.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.md)
            actions(for: finding)
            if finding.blockID != nil {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        // Not wrapped in a Button: a row-level Button would absorb the inner action
        // Buttons into one accessibility element. A tap gesture navigates; the action
        // buttons stay first-class.
        .contentShape(Rectangle())
        .onTapGesture { navigate(to: finding) }
    }

    /// The inline action control(s) a finding offers, by fix kind.
    @ViewBuilder
    private func actions(for finding: LintFinding) -> some View {
        switch finding.fix {
        case .setPermissions(_, _, let label):
            Button(label) { store.applyFix(finding.fix!) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("fix-permissions")
        case .deleteOrphanedKey(let priv, let pub, _):
            if let path = priv ?? pub {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("reveal-key")
            }
            Button("Delete…", role: .destructive) { pendingDelete = finding.fix }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("delete-orphan")
        case .generateReplacement(let comment, _):
            Button("Generate Replacement") {
                store.pendingKeyGeneration = ConfigStore.KeyGenerationRequest(comment: comment)
                selection = .keys
            }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityIdentifier("generate-replacement")
        case .grantSymlinkAccess:
            Button("Grant Access…") { store.applyFix(finding.fix!) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("grant-symlink-access")
        case .moveWildcardLast:
            Button("Move to End") { store.applyFix(finding.fix!) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("move-wildcard-last")
        case .none:
            EmptyView()
        }
    }

    private func color(for severity: LintFinding.Severity) -> Color {
        switch severity {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func navigate(to finding: LintFinding) {
        if let id = finding.blockID { selection = .host(id) }
    }
}
