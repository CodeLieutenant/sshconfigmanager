//
//  JumpHostWizard.swift
//  sshconfigmanager
//
//  A sheet for authoring `ProxyJump` (and optionally `ProxyCommand`) chains without
//  hand-editing the raw directive. Presents:
//    • an ordered hop list (add / remove / drag-to-reorder)
//    • a "ProxyJump none" toggle to explicitly disable jumping
//    • a topology graph showing you → jump₁ → … → target
//    • a "What ssh will do" resolved preview with a Copy button
//    • inline validation: unknown alias, both directives set, unparseable hop
//
//  Entry points from HostDetailView: "Jump Hosts…" in the More menu, and an
//  "Edit chain" button next to the ProxyJump keyword row.
//

import SSHConfigCore
import SwiftUI

struct JumpHostWizard: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let blockID: HostBlock.ID

    @State private var chain: JumpChain = JumpChain()
    @State private var hasProxyCommand = false
    @State private var resolvedHops: [ResolvedHop] = []
    @State private var dragItem: UUID?

    private var block: HostBlock? { store.block(id: blockID) }

    private var targetLabel: String {
        block?.primaryAlias ?? block?.title ?? "target"
    }

    private var knownAliases: [String] {
        store.allHostBlocks
            .flatMap(\.concreteAliases)
            .filter { $0 != targetLabel }
            .sorted()
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    topologySection
                    hopsSection
                    validationSection
                    previewSection
                }
                .padding(Spacing.xxxl)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 460)
        .onAppear { loadFromBlock() }
        .onChange(of: chain) { _, _ in recompute() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.lg) {
            IconTile(systemImage: "arrow.triangle.branch", color: TilePalette.tunnels, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Jump Hosts").font(.system(size: 17, weight: .semibold))
                Text("Configure ProxyJump for \(targetLabel)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Spacing.xxxl)
        .background(.regularMaterial)
    }

    // MARK: - Topology graph

    private var topologySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionLabel("Connection path")
            Card {
                TopologyGraph(
                    hops: resolvedHops,
                    targetLabel: targetLabel,
                    onSelectAlias: { alias in
                        store.selectedBlockID =
                            store.allHostBlocks
                            .first { $0.concreteAliases.contains(alias) }?.id
                    }
                )
                .padding(Spacing.xl)
            }
        }
    }

    // MARK: - Hop list

    private var hopsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionLabel("Jump hops (first = closest to you)")
            Card {
                if chain.hops.isEmpty && !chain.isNone {
                    CardRow {
                        Text("No hops — connection goes directly to \(targetLabel).")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(chain.hops) { hop in
                    hopRow(hop)
                }
                AccentRow(title: "Add Hop", systemImage: "plus") {
                    chain.hops.append(JumpHop(host: ""))
                }
                .disabled(chain.isNone)
            }
            Toggle("ProxyJump none — explicitly disable jumping (overrides wildcards)", isOn: $chain.isNone)
                .font(.system(size: 13))
                .toggleStyle(.checkbox)
                .onChange(of: chain.isNone) { _, none in
                    if none { chain.hops.removeAll() }
                }
        }
    }

    @ViewBuilder
    private func hopRow(_ hop: JumpHop) -> some View {
        let index = chain.hops.firstIndex(where: { $0.id == hop.id })
        CardRow(minHeight: 44) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))
                .onDrag {
                    dragItem = hop.id
                    return NSItemProvider()
                }

            // user@ field (optional)
            TextField("user", text: userBinding(id: hop.id))
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospaced())
                .frame(width: 80)
                .foregroundStyle(.secondary)

            Text("@")
                .foregroundStyle(.tertiary)
                .font(.system(size: 12))

            // host field with alias autocomplete
            HopHostField(
                host: hostBinding(id: hop.id),
                aliases: knownAliases
            )

            Text(":")
                .foregroundStyle(.tertiary)
                .font(.system(size: 12))

            // port field (optional)
            TextField("port", text: portBinding(id: hop.id))
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospaced())
                .frame(width: 50)

            Spacer(minLength: Spacing.sm)
            hopValidationIcon(hop)

            Button(role: .destructive) {
                if let i = index { chain.hops.remove(at: i) }
            } label: {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .onDrop(
            of: [.text],
            delegate: HopDropDelegate(
                id: hop.id, hops: $chain.hops, dragItem: $dragItem))
    }

    @ViewBuilder
    private func hopValidationIcon(_ hop: JumpHop) -> some View {
        if hop.host.isEmpty {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .help("Enter a host name or alias")
        } else if !hop.host.isEmpty && !knownAliases.contains(hop.host) && !looksLikeLiteralHost(hop.host) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help("\"\(hop.host)\" is not a known alias \u{2014} it may be an external host or a typo")
        }
    }

    // MARK: - Validation

    @ViewBuilder
    private var validationSection: some View {
        let issues = validationIssues
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Image(systemName: issue.icon)
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                            .font(.system(size: 13))
                        Text(issue.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private struct ValidationIssue {
        enum Severity { case warning, error }
        let severity: Severity
        let message: String
        var icon: String { severity == .error ? "xmark.circle" : "exclamationmark.triangle" }
    }

    private var validationIssues: [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if hasProxyCommand && !chain.hops.isEmpty {
            issues.append(
                .init(
                    severity: .warning,
                    message:
                        "Both ProxyJump and ProxyCommand are set. ProxyJump takes precedence; remove ProxyCommand to avoid confusion."
                ))
        }
        for hop in chain.hops where hop.host.isEmpty {
            issues.append(.init(severity: .error, message: "One or more hops has no host specified."))
            break
        }
        return issues
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewSection: some View {
        if !chain.hops.isEmpty || chain.isNone {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionLabel("What ssh will do")
                Card {
                    CardRow(minHeight: 48) {
                        Text(previewCommand)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") { NSPasteboard.general.setString(previewCommand, forType: .string) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private var previewCommand: String {
        if chain.isNone { return "ssh \(targetLabel)  # (no jump — direct connection)" }
        let jumpArg = chain.render()
        return jumpArg.isEmpty ? "ssh \(targetLabel)" : "ssh -J \(jumpArg) \(targetLabel)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Apply") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(hasUnresolvedErrors)
        }
        .padding(Spacing.xxxl)
        .background(.regularMaterial)
    }

    private var hasUnresolvedErrors: Bool {
        validationIssues.contains { $0.severity == .error }
    }

    // MARK: - Actions

    private func loadFromBlock() {
        guard let block else { return }
        let raw = block.firstValue(for: "ProxyJump") ?? ""
        chain = JumpChain.parse(raw)
        hasProxyCommand = block.firstValue(for: "ProxyCommand") != nil
        recompute()
    }

    private func recompute() {
        resolvedHops = EffectiveConfigResolver.resolveJumpChain(
            target: targetLabel, in: store.documents)
    }

    private func apply() {
        store.setJumpChain(id: blockID, chain)
        dismiss()
    }

    // MARK: - Bindings

    private func userBinding(id: UUID) -> Binding<String> {
        Binding(
            get: { chain.hops.first(where: { $0.id == id })?.user ?? "" },
            set: { v in
                if let i = chain.hops.firstIndex(where: { $0.id == id }) {
                    chain.hops[i].user = v.isEmpty ? nil : v
                }
            }
        )
    }

    private func hostBinding(id: UUID) -> Binding<String> {
        Binding(
            get: { chain.hops.first(where: { $0.id == id })?.host ?? "" },
            set: { v in
                if let i = chain.hops.firstIndex(where: { $0.id == id }) {
                    chain.hops[i].host = v
                }
            }
        )
    }

    private func portBinding(id: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let hop = chain.hops.first(where: { $0.id == id }),
                    let p = hop.port
                else { return "" }
                return String(p)
            },
            set: { v in
                if let i = chain.hops.firstIndex(where: { $0.id == id }) {
                    chain.hops[i].port = Int(v)
                }
            }
        )
    }

    // MARK: - Helpers

    private func looksLikeLiteralHost(_ host: String) -> Bool {
        // Accept bare IPs, IPv6 brackets, and strings with dots (likely FQDNs).
        host.contains(".") || host.contains(":") || host.hasPrefix("[")
    }
}

// MARK: - Host field with alias autocomplete

private struct HopHostField: View {
    @Binding var host: String
    let aliases: [String]
    @State private var showSuggestions = false

    private var suggestions: [String] {
        guard !host.isEmpty else { return [] }
        let q = host.lowercased()
        return aliases.filter { FuzzyMatch.contains(q, in: $0.lowercased()) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("hostname or alias", text: $host)
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospaced())
                .frame(minWidth: 140)
                .onChange(of: host) { _, _ in showSuggestions = !suggestions.isEmpty }
                .onSubmit { showSuggestions = false }

            if showSuggestions {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { alias in
                        Button(alias) {
                            host = alias
                            showSuggestions = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12).monospaced())
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Color.appContent)
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Color.cardBorder))
                .shadow(radius: 4, y: 2)
                .zIndex(10)
            }
        }
    }
}

// MARK: - Drag-reorder delegate

private struct HopDropDelegate: DropDelegate {
    let id: UUID
    @Binding var hops: [JumpHop]
    @Binding var dragItem: UUID?

    func performDrop(info: DropInfo) -> Bool {
        guard let from = dragItem,
            let fromIdx = hops.firstIndex(where: { $0.id == from }),
            let toIdx = hops.firstIndex(where: { $0.id == id }),
            fromIdx != toIdx
        else { return false }
        withAnimation {
            hops.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        }
        dragItem = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { dragItem != nil }
}
