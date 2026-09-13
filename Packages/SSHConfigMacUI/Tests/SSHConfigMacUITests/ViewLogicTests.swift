//
//  ViewLogicTests.swift
//  sshconfigmanagerTests
//
//  Behaviour tests for the *logic* the views present — the derived labels,
//  filters, and groupings a user can see. The render suite (ViewRenderingTests)
//  proves each `body` evaluates; this suite pins the data those bodies show.
//
//  Most of this logic lives in `private` view helpers, so it can't be called
//  directly. Where the helper is a thin wrapper over a public model function
//  (e.g. the tunnel command preview, the forward summary, the palette filter)
//  we assert the public function the view delegates to — same contract, reached
//  without poking at view internals. The few genuinely view-private rules
//  (the "+N extra" summary, the host grouping) are reproduced as free functions
//  mirroring the view, with the view kept as the source of truth in review.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

// MARK: - TunnelEditorView: mode-driven labels + preview

@MainActor
struct TunnelEditorLogicTests {
    /// `preview(for:)` shows `<flag> <forwardSpec>`; the flag must track the mode.
    @Test func previewCombinesModeFlagAndForwardSpec() {
        let local = PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)
        #expect("\(TunnelMode.local.flag) \(local.forwardSpec(for: .local))" == "-L 5432:db:5432")

        let remote = PortMapping(
            bindAddress: "127.0.0.1", listenPort: 8080,
            targetHost: "localhost", targetPort: 3000)
        #expect(
            "\(TunnelMode.remote.flag) \(remote.forwardSpec(for: .remote))"
                == "-R 127.0.0.1:8080:localhost:3000")

        let dynamic = PortMapping(listenPort: 1080)
        #expect("\(TunnelMode.dynamic.flag) \(dynamic.forwardSpec(for: .dynamic))" == "-D 1080")
    }

    /// Only `.dynamic` hides the target host/port columns in the mapping row.
    @Test func onlyDynamicModeHasNoTarget() {
        #expect(TunnelMode.local.hasTarget)
        #expect(TunnelMode.remote.hasTarget)
        #expect(!TunnelMode.dynamic.hasTarget)
    }

    /// The editor's host picker offers Host aliases only — the same
    /// `kind == .host && !isWildcard` filter the view applies to `allHostBlocks`.
    /// `isWildcard` is true only for a block whose every pattern is exactly "*",
    /// so a catch-all "Host *" is dropped while a partial glob like "*.internal"
    /// (still a legitimate, pickable alias) is kept. Match blocks are excluded.
    @Test func hostPickerExcludesCatchAllWildcardAndMatchBlocks() {
        let store = ConfigStore(settings: AppSettings(database: nil))
        store.loadForTesting([
            SSHConfigParser.parse(
                """
                Host web
                    HostName w.example.com
                Host *.internal
                    User deploy
                Host *
                    Compression yes
                Match host server
                    ForwardAgent yes
                """, sourceURL: URL(fileURLWithPath: "/tmp/config"))
        ])
        let aliases = store.allHostBlocks
            .filter { $0.kind == .host && !$0.isWildcard }
            .compactMap { $0.patterns.first }
            .filter { !$0.isEmpty }
        #expect(aliases == ["web", "*.internal"]) // catch-all "*" and the Match block are dropped
    }
}

// MARK: - TunnelsManagementView: forward summary + host grouping

struct TunnelsManagementLogicTests {
    /// `forwardSummary` shows the first forward and, when a tunnel carries more,
    /// a "+N" suffix. This mirrors the view's private helper exactly.
    private func forwardSummary(_ preset: TunnelPreset) -> String {
        guard let first = preset.mappings.first else { return preset.mode.flag }
        let base = "\(preset.mode.flag) \(first.forwardSpec(for: preset.mode))"
        let extra = preset.mappings.count - 1
        return extra > 0 ? "\(base)  +\(extra)" : base
    }

    @Test func singleMappingHasNoExtraSuffix() {
        let p = TunnelPreset(
            hostAlias: "b", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
        #expect(forwardSummary(p) == "-L 5432:db:5432")
    }

    @Test func multipleMappingsAppendExtraCount() {
        let p = TunnelPreset(
            hostAlias: "b", mode: .local,
            mappings: [
                PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432),
                PortMapping(listenPort: 6379, targetHost: "cache", targetPort: 6379),
                PortMapping(listenPort: 9200, targetHost: "es", targetPort: 9200),
            ])
        #expect(forwardSummary(p) == "-L 5432:db:5432  +2")
    }

    @Test func emptyMappingsFallBackToModeFlag() {
        let p = TunnelPreset(hostAlias: "b", mode: .dynamic, mappings: [])
        #expect(forwardSummary(p) == "-D")
    }

    /// The sidebar groups presets by host alias (blank → "(no host)") and sorts
    /// the groups case-insensitively. Mirrors the view's `hostGroups`.
    private func hostGroups(_ presets: [TunnelPreset]) -> [(host: String, count: Int)] {
        Dictionary(grouping: presets, by: \.hostAlias)
            .map { (host: $0.key.isEmpty ? "(no host)" : $0.key, count: $0.value.count) }
            .sorted { $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending }
    }

    @Test func presetsGroupByHostSortedAndBlankBecomesNoHost() {
        let presets = [
            TunnelPreset(hostAlias: "Zeta", mode: .dynamic, mappings: [PortMapping(listenPort: 1)]),
            TunnelPreset(hostAlias: "alpha", mode: .dynamic, mappings: [PortMapping(listenPort: 2)]),
            TunnelPreset(hostAlias: "alpha", mode: .dynamic, mappings: [PortMapping(listenPort: 3)]),
            TunnelPreset(hostAlias: "", mode: .dynamic, mappings: [PortMapping(listenPort: 4)]),
        ]
        let groups = hostGroups(presets)
        #expect(groups.map(\.host) == ["(no host)", "alpha", "Zeta"]) // case-insensitive sort
        #expect(groups.first(where: { $0.host == "alpha" })?.count == 2)
    }

    /// `subtitle` reads "<running> of <total> running"; empty when there are none.
    @MainActor
    @Test func subtitleCountsRunningOfTotal() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vl-\(UUID().uuidString).store")
        let store = TunnelStore(persistenceURL: url, engine: LogicNoopEngine())
        #expect(subtitle(store) == "")
        let p = TunnelPreset(hostAlias: "b", mode: .dynamic, mappings: [PortMapping(listenPort: 1080)])
        store.add(p)
        #expect(subtitle(store) == "0 of 1 running")
        store.start(p)
        #expect(subtitle(store) == "1 of 1 running")
    }

    @MainActor
    private func subtitle(_ tunnels: TunnelStore) -> String {
        let total = tunnels.presets.count
        guard total > 0 else { return "" }
        return "\(tunnels.runningPresets.count) of \(total) running"
    }
}

// MARK: - CommandPalette / MenuBar: host + tunnel filtering

@MainActor
struct PaletteAndMenuFilterTests {
    private func store(_ text: String) -> ConfigStore {
        let s = ConfigStore(settings: AppSettings(database: nil))
        s.loadForTesting([SSHConfigParser.parse(text, sourceURL: URL(fileURLWithPath: "/tmp/config"))])
        return s
    }

    /// CommandPalette's `matches` fuzzy-scores non-wildcard hosts and sorts by
    /// score. We assert the two contracts it relies on: wildcards are excluded,
    /// and a closer match outranks a scattered one.
    @Test func paletteMatchesExcludeWildcardsAndRankByScore() {
        let s = store(
            """
            Host prod-web
                HostName web.example.com
            Host prod-db
                HostName db.example.com
            Host *
                Compression yes
            """)
        let hosts = s.allHostBlocks.filter { !$0.isWildcard }
        #expect(hosts.count == 2) // the wildcard "*" is dropped

        let scored = hosts.compactMap { block -> (String, Int)? in
            let haystack = block.title + " " + (block.firstValue(for: "HostName") ?? "")
            guard let score = FuzzyMatch.score(query: "web", candidate: haystack) else { return nil }
            return (block.title, score)
        }.sorted { $0.1 > $1.1 }
        #expect(scored.first?.0 == "prod-web") // "web" matches prod-web best
    }

    /// The palette's tunnel verbs: an empty query shows only *running* tunnels;
    /// a query matches on display name or host alias. Mirrors `tunnelMatches`.
    @Test func tunnelMatchesEmptyShowsRunningQueryFiltersByNameOrHost() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vl-\(UUID().uuidString).store")
        let tunnels = TunnelStore(persistenceURL: url, engine: LogicNoopEngine())
        let pg = TunnelPreset(
            name: "Postgres", hostAlias: "bastion", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
        let socks = TunnelPreset(
            name: "SOCKS", hostAlias: "web", mode: .dynamic,
            mappings: [PortMapping(listenPort: 1080)])
        tunnels.add(pg)
        tunnels.add(socks)
        tunnels.start(pg)

        // Empty query → only the running preset.
        #expect(tunnelMatches(tunnels, query: "").map(\.name) == ["Postgres"])
        // Query on name.
        #expect(tunnelMatches(tunnels, query: "socks").map(\.name) == ["SOCKS"])
        // Query on host alias.
        #expect(tunnelMatches(tunnels, query: "web").map(\.name) == ["SOCKS"])
        // No match.
        #expect(tunnelMatches(tunnels, query: "zzz").isEmpty)
    }

    private func tunnelMatches(_ tunnels: TunnelStore, query: String) -> [TunnelPreset] {
        guard !query.isEmpty else { return tunnels.runningPresets }
        let q = query.lowercased()
        return tunnels.presets.filter {
            $0.displayName.lowercased().contains(q) || $0.hostAlias.lowercased().contains(q)
        }
    }
}

// MARK: - AddIdentityKeyPopover: key search filter

struct IdentityKeyFilterTests {
    private func key(name: String, comment: String, algorithm: String) -> SSHPublicKey {
        SSHPublicKey(
            id: UUID(),
            publicKeyURL: URL(fileURLWithPath: "/tmp/\(name).pub"),
            privateKeyURL: URL(fileURLWithPath: "/tmp/\(name)"),
            algorithm: algorithm, fingerprint: "SHA256:x", comment: comment)
    }

    /// The popover matches a key by name, comment, or human type label, and an
    /// empty query returns everything. Mirrors `AddIdentityKeyPopover.matches`.
    @Test func matchesByNameCommentOrTypeAndEmptyReturnsAll() {
        let keys = [
            key(name: "id_ed25519", comment: "laptop@home", algorithm: "ssh-ed25519"),
            key(name: "work_key", comment: "office", algorithm: "ecdsa-sha2-nistp256"),
        ]
        #expect(matches(keys, "").count == 2) // empty → all
        #expect(matches(keys, "work").map(\.name) == ["work_key"]) // by name
        #expect(matches(keys, "laptop").map(\.name) == ["id_ed25519"]) // by comment
        #expect(matches(keys, "ecdsa").map(\.name) == ["work_key"]) // by type label
        #expect(matches(keys, "  ").count == 2) // whitespace-only → all
    }

    private func matches(_ keys: [SSHPublicKey], _ query: String) -> [SSHPublicKey] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return keys }
        return keys.filter {
            $0.name.lowercased().contains(q)
                || $0.comment.lowercased().contains(q)
                || $0.typeLabel.lowercased().contains(q)
        }
    }
}

// MARK: - IssuesView: severity → colour symbol is total

struct IssuesSeverityTests {
    /// Every severity must resolve to a non-empty SF Symbol — the view force-uses
    /// `severity.symbol`, so a missing case would render a blank icon.
    @Test func everySeverityHasASymbol() {
        for severity in [LintFinding.Severity.info, .warning, .error] {
            #expect(!severity.symbol.isEmpty)
        }
    }
}

/// Engine stub for the store-backed logic tests (no network, no Terminal).
@MainActor
private final class LogicNoopEngine: TunnelEngine {
    let capabilities = TunnelEngineCapabilities(reportsLiveness: false, canStop: true, survivesAppQuit: false)
    func start(_ preset: TunnelPreset) throws {
        if !preset.isValid { throw TunnelEngineError.invalidPreset }
    }
    func stop(_ preset: TunnelPreset) {}
}
