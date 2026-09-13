import Adwaita
import Foundation
import SSHConfigCore

/// L05 · Issues. Everything the linter and the key auditor found, worst first,
/// with the fixes that can be applied without leaving the app.
struct IssuesView: View {
    @Binding var store: ConfigStore
    var onStatus: (String) -> Void

    var view: Body {
        content
            .topToolbar {
                HeaderBar.end {
                    Button(icon: .default(icon: .viewRefresh)) {
                        store.reload()
                        onStatus("Re-checked")
                    }
                    .flat()
                    .tooltip("Check again")
                }
                .headerBarTitle {
                    WindowTitle(subtitle: subtitle, title: "Issues")
                }
            }
    }

    private var subtitle: String {
        let count = store.findings.count
        return count == 0 ? "All clear" : count == 1 ? "1 finding" : "\(count) findings"
    }

    private func count(_ severity: LintFinding.Severity) -> Int {
        store.findings.filter { $0.severity == severity }.count
    }

    /// One pill per severity that actually occurs. A screen that always shows
    /// three counters, two of them zero, reads as noisier than it is.
    @ViewBuilder private var headerPills: Body {
        if count(.error) > 0 {
            statusPill(kind: .error, text: "\(count(.error)) to fix")
        }
        if count(.warning) > 0 {
            statusPill(kind: .warn, text: "\(count(.warning)) warnings")
        }
        if count(.info) > 0 {
            tagPill(text: "\(count(.info)) notes")
        }
    }

    @ViewBuilder private var content: Body {
        if store.findings.isEmpty {
            StatusPage(
                "Nothing to fix",
                icon: .default(icon: .emblemOk),
                description: "Your configuration and your keys pass every check."
            )
        } else {
            VStack {
                screenHeader(
                    icon: .default(icon: .dialogWarning),
                    tile: "tile-issues",
                    title: "Issues",
                    subtitle: subtitle,
                    pills: { headerPills }
                )
                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        section("Errors", .error)
                        section("Warnings", .warning)
                        section("Notes", .info)
                    }
                    .padding(Spacing.xxl)
                    .frame(maxWidth: 900)
                }
                .vexpand()
            }
        }
    }

    /// Findings are split by severity rather than listed in one card, so what
    /// needs doing now sits apart from what is only worth knowing.
    @ViewBuilder private func section(_ title: String, _ severity: LintFinding.Severity) -> Body {
        let items = store.findings.filter { $0.severity == severity }
        if !items.isEmpty {
            cardSection(title) {
                ForEach(items) { finding in
                    row(finding)
                }
            }
        }
    }

    private func row(_ finding: LintFinding) -> AnyView {
        ActionRow(finding.title)
            .useMarkup(false)
            .subtitle(finding.detail)
            .subtitleLines(0)
            .prefix {
                Symbol(icon: finding.severity.icon)
                    .style("area-tile")
                    .style(finding.severity.tileClass)
                    .valign(.center)
            }
            .suffix {
                if let fix = finding.fix, let label = fixLabel(fix) {
                    Button(label) { apply(fix) }
                        .valign(.center)
                }
            }
    }

    /// Only the fixes this front end can actually carry out get a button. The
    /// others still describe the problem, which is the point of the screen.
    private func fixLabel(_ fix: LintFix) -> String? {
        switch fix {
        case .setPermissions(_, _, let label): label
        case .deleteOrphanedKey: "Delete…"
        case .moveWildcardLast: "Move Last"
        case .generateReplacement, .grantSymlinkAccess: nil
        }
    }

    private func apply(_ fix: LintFix) {
        switch fix {
        case .setPermissions(let path, let mode, _):
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: mode],
                    ofItemAtPath: path
                )
                store.reload()
                onStatus("Set \(String(mode, radix: 8)) on \(URL(fileURLWithPath: path).lastPathComponent)")
            } catch {
                onStatus("Could not change permissions: \(error.localizedDescription)")
            }
        case .deleteOrphanedKey(let privatePath, let publicPath, let name):
            for path in [privatePath, publicPath].compactMap({ $0 }) {
                try? FileManager.default.removeItem(atPath: path)
            }
            store.reload()
            onStatus("Deleted \(name)")
        case .moveWildcardLast(let blockID):
            moveWildcardLast(blockID)
        case .generateReplacement, .grantSymlinkAccess:
            break
        }
    }

    /// `Host *` only supplies a default for what no later block set, so a
    /// catch-all above a specific host silently wins over it.
    private func moveWildcardLast(_ blockID: HostBlock.ID) {
        guard
            var document = store.graph.documents.first(where: { document in
                document.blocks.contains { $0.id == blockID }
            }),
            let index = document.blocks.firstIndex(where: { $0.id == blockID })
        else { return }
        let block = document.blocks.remove(at: index)
        document.blocks.append(block)
        do {
            try store.save(document)
            onStatus("Moved \(block.title) to the end")
        } catch {
            onStatus("Could not reorder: \(error.localizedDescription)")
        }
    }
}
