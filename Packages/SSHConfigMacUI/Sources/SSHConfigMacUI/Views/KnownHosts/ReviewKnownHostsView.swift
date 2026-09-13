//
//  ReviewKnownHostsView.swift
//  sshconfigmanager
//

import SSHConfigCore
import SSHConfigServices
import SwiftUI

struct ReviewKnownHostsView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let findings: [KnownHostEntry.ID: KnownHostsAudit.Finding]

    /// Entries for which we have a finding, ordered by line index.
    private var affectedEntries: [(entry: KnownHostEntry, finding: KnownHostsAudit.Finding)] {
        store.knownHosts
            .compactMap { e in findings[e.id].map { (e, $0) } }
            .sorted { $0.entry.lineIndex < $1.entry.lineIndex }
    }

    private var malformed: [(entry: KnownHostEntry, finding: KnownHostsAudit.Finding)] {
        affectedEntries.filter {
            if case .malformed = $0.finding { return true }
            return false
        }
    }
    private var duplicates: [(entry: KnownHostEntry, finding: KnownHostsAudit.Finding)] {
        affectedEntries.filter {
            if case .duplicate = $0.finding { return true }
            return false
        }
    }
    private var orphans: [(entry: KnownHostEntry, finding: KnownHostsAudit.Finding)] {
        affectedEntries.filter {
            if case .orphan = $0.finding { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if affectedEntries.isEmpty {
                noFindingsState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        if !malformed.isEmpty {
                            section("Malformed", items: malformed, icon: "exclamationmark.triangle", tint: .red)
                        }
                        if !duplicates.isEmpty {
                            section("Duplicates", items: duplicates, icon: "doc.on.doc", tint: .orange)
                        }
                        if !orphans.isEmpty {
                            section("Orphans", items: orphans, icon: "questionmark.circle", tint: .secondary)
                        }
                    }
                    .padding(Spacing.xxxl)
                }
            }
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: "doc.badge.gearshape", color: TilePalette.knownHosts, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Known Hosts")
                    .font(.headline)
                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.xxl)
    }

    private var subtitleText: String {
        let total = affectedEntries.count
        if total == 0 { return "No issues found in \(store.knownHostsFileName)." }
        return "\(total) issue\(total == 1 ? "" : "s") found in \(store.knownHostsFileName)"
    }

    // MARK: Sections

    private func section(
        _ title: String,
        items: [(entry: KnownHostEntry, finding: KnownHostsAudit.Finding)],
        icon: String, tint: Color
    ) -> some View {
        CardSection(title) {
            ForEach(items, id: \.entry.id) { pair in
                findingRow(pair.entry, finding: pair.finding, icon: icon, tint: tint)
            }
        }
    }

    private func findingRow(
        _ entry: KnownHostEntry,
        finding: KnownHostsAudit.Finding,
        icon: String, tint: Color
    ) -> some View {
        CardRow(minHeight: 50) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.hostsDisplay)
                    .font(.system(size: 12.5, weight: .medium).monospaced())
                    .lineLimit(1).truncationMode(.middle)
                Text(findingDescription(finding, keyType: entry.keyType))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            HStack(spacing: 6) {
                Button("Comment Out") { store.applyCleanup(.commentOut, to: entry) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Remove", role: .destructive) { store.applyCleanup(.remove, to: entry) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func findingDescription(_ finding: KnownHostsAudit.Finding, keyType: String) -> String {
        switch finding {
        case .malformed:
            return "This line can't be parsed as a known_hosts entry and is ignored by ssh."
        case .duplicate(of: _):
            return "Another entry already stores a \(keyType) key for this host. The later entry is redundant."
        case .orphan:
            return "No ssh_config Host block references this host. The entry may be from a server you no longer use."
        }
    }

    // MARK: Empty state

    private var noFindingsState: some View {
        ContentUnavailableView(
            "No issues found",
            systemImage: "checkmark.circle",
            description: Text("\(store.knownHostsFileName) looks clean — no malformed, duplicate, or orphaned entries.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            Text(
                "Orphan findings are advisory — a host may be legitimate but not in your config. Removing changes what ssh trusts; prefer Comment Out when unsure."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.lg)
    }
}
