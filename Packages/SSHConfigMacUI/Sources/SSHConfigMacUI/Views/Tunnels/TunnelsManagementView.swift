//
//  TunnelsManagementView.swift
//  sshconfigmanager
//
//  The top-level Tunnels screen — restyled to the Liquid Glass redesign: a frosted screen
//  header, a glass tunnel list grouped by host, and a detail pane with a Forwards card,
//  live throughput, and the per-tunnel console. Tunnels still run in-process; start/stop,
//  status, throughput, console, and the editor sheets are unchanged.
//

import AppKit
import SSHConfigCore
import SSHConfigServices
import SwiftUI

struct TunnelsManagementView: View {
    @Environment(TunnelStore.self) private var tunnels
    @Environment(ConfigStore.self) private var config

    @State private var selection: TunnelPreset.ID?
    @State private var editing: TunnelPreset?
    @State private var showNew = false
    @State private var toastMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                tile: (icon: "point.3.connected.trianglepath.dotted", color: TilePalette.tunnels),
                title: "Tunnels", subtitle: subtitle
            ) {
                ChromeButton(title: "Add Tunnel", systemImage: "plus", kind: .secondary) { showNew = true }
                    .disabled(!tunnels.isLoaded)
            }
            content
        }
        .background(WindowWash())
        .onAppear(perform: selectFirstIfNeeded)
        .onChange(of: tunnels.presets.map(\.id)) { _, _ in selectFirstIfNeeded() }
        // Deep-link from the menu-bar "Logs" action: select the focused tunnel.
        .onChange(of: tunnels.consoleFocus, initial: true) { _, focus in
            if let focus, tunnels.presets.contains(where: { $0.id == focus.id }) {
                selection = focus.id
            }
        }
        .sheet(isPresented: $showNew) {
            TunnelEditorView(existing: nil, onAdded: { toastMessage = "Tunnel added" })
        }
        .sheet(item: $editing) {
            TunnelEditorView(existing: $0, onUpdated: { toastMessage = "Tunnel updated" })
        }
        .toast($toastMessage)
    }

    @ViewBuilder
    private var content: some View {
        if !tunnels.isLoaded {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tunnels.presets.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                tunnelList.frame(width: 300)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var subtitle: String {
        let total = tunnels.presets.count
        guard total > 0 else { return "" }
        return "\(tunnels.runningPresets.count) of \(total) running"
    }

    /// Keep a tunnel selected so the detail pane is never an empty void.
    private func selectFirstIfNeeded() {
        if selection == nil || !tunnels.presets.contains(where: { $0.id == selection }) {
            selection = tunnels.presets.first?.id
        }
    }

    // MARK: - Tunnel list

    private var tunnelList: some View {
        // A real `List` so ↑/↓ keyboard navigation works; styled to the glass look.
        List(selection: $selection) {
            ForEach(hostGroups, id: \.host) { group in
                Section(group.host) {
                    ForEach(group.presets) { preset in row(preset) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 300)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.appSeparator).frame(width: 1) }
    }

    private func row(_ preset: TunnelPreset) -> some View {
        let status = tunnels.status(for: preset.id)
        return HStack(spacing: Spacing.md) {
            Button {
                tunnels.toggle(preset)
            } label: {
                Image(systemName: status.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(status.isRunning ? .red : .green)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(status.isRunning ? "Stop tunnel" : "Start tunnel")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(preset.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    // At-a-glance marker so a browsable tunnel doesn't require opening
                    // the detail pane to notice — mirrors the Forwards card's WebUIPill.
                    if preset.mappings.contains(where: \.hasWebUI) {
                        Image(systemName: "safari.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .help("Has a web UI")
                    }
                    if tunnels.isOrphaned(preset) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("“\(preset.hostAlias)” isn't in the config anymore — was it renamed or removed?")
                    }
                }
                Text(forwardSummary(preset))
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            Circle().fill(status.kind.color).frame(width: 7, height: 7)
                .animation(.easeInOut(duration: 0.2), value: status.isRunning)
        }
        .frame(minHeight: 40)
        .tag(preset.id)
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .listRowSeparator(.hidden)
        .contextMenu { rowMenu(preset) }
        .accessibilityIdentifier("tunnel-row-\(tunnelSlug(preset))")
    }

    private func tunnelSlug(_ preset: TunnelPreset) -> String {
        preset.displayName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    @ViewBuilder
    private func rowMenu(_ preset: TunnelPreset) -> some View {
        let status = tunnels.status(for: preset.id)
        Button(status.isRunning ? "Stop" : "Start") { tunnels.toggle(preset) }
        Button("Edit…") { editing = preset }
        Button("Copy ssh Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                TunnelCommandBuilder.commandString(for: preset), forType: .string)
        }
        Button("Write to ssh config") {
            config.writeForwardDirectives(preset.forwardDirectives, toHostAlias: preset.hostAlias)
        }
        importForwardsButton(preset)
        Divider()
        Button("Delete", role: .destructive) { deleteWithToast(preset) }
    }

    /// Only shown when the host's config actually has `LocalForward`/`RemoteForward`/
    /// `DynamicForward` directives (matching this preset's mode) not already covered
    /// by its mappings — `importForwardsFromConfig` returns `nil` otherwise, and there's
    /// nothing useful for the button to do in that case.
    @ViewBuilder
    private func importForwardsButton(_ preset: TunnelPreset) -> some View {
        if let imported = config.importForwardsFromConfig(into: preset) {
            Button("Import Forwards from Config") {
                var updated = preset
                updated.mappings = imported
                tunnels.update(updated)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let preset = selected {
            VStack(spacing: 0) {
                detailHeader(preset)
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    forwardsCard(preset)
                    if let bytes = tunnels.throughput[preset.id] {
                        Text(bytes.summary)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.linear(duration: 0.4), value: bytes.summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.xxxl)

                Spacer(minLength: 0)
                consoleBar(preset)
                TunnelConsoleView(preset: preset)
            }
        } else {
            ContentUnavailableView(
                "Select a tunnel",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Pick a tunnel on the left to see its console and controls."))
        }
    }

    private func detailHeader(_ preset: TunnelPreset) -> some View {
        let status = tunnels.status(for: preset.id)
        return HStack(spacing: Spacing.md) {
            IconTile(systemImage: "point.3.connected.trianglepath.dotted", color: TilePalette.tunnels, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.displayName).font(.system(size: 16, weight: .bold)).lineLimit(1)
                Text("through \(preset.hostAlias)").font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                // "Reconnecting…" on its own tells the user nothing. Carry the last
                // attempt's reason next to it, in full on hover.
                if let reason = tunnels.failureReason(for: preset.id), !isActive(status) {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(reason)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Spacing.lg)
            StatusPill(kind: status.kind, text: statusLabel(status))
            // The primary mapping's browser shortcut, front and center — the per-row
            // button in the Forwards card below still covers additional mappings.
            if let webUIMapping = preset.mappings.first(where: \.hasWebUI) {
                ChromeButton(icon: "safari", help: "Open in Browser") {
                    openBrowser(webUIMapping)
                }
            }
            ChromeButton(
                title: status.isRunning ? "Stop" : "Start",
                systemImage: status.isRunning ? "stop.fill" : "play.fill",
                kind: .prominent, tint: status.isRunning ? .red : .green
            ) {
                tunnels.toggle(preset)
            }
            tunnelMenu(preset)
        }
        .padding(.horizontal, Spacing.xxxl)
        .padding(.vertical, Spacing.xl)
        .frame(minHeight: 84)
        .glassChrome()
        .overlay(alignment: .bottom) { Rectangle().fill(.appSeparator).frame(height: 1) }
    }

    private func tunnelMenu(_ preset: TunnelPreset) -> some View {
        Menu {
            Button("Edit…") { editing = preset }
            Button("Copy ssh Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    TunnelCommandBuilder.commandString(for: preset), forType: .string)
            }
            Button("Write to ssh config") {
                config.writeForwardDirectives(preset.forwardDirectives, toHostAlias: preset.hostAlias)
            }
            importForwardsButton(preset)
            Divider()
            Button("Delete", role: .destructive) { deleteWithToast(preset) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 29)
                .background(.controlWash, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(
                        Color.cardBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private func forwardsCard(_ preset: TunnelPreset) -> some View {
        CardSection("Forwards") {
            ForEach(preset.mappings) { mapping in
                CardRow {
                    Image(systemName: preset.mode.symbol)
                        .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                    Text(forwardKindLabel(preset)).font(.system(size: 13, weight: .medium))
                    // Marked "Has a web UI" in the editor — only offered on -L, the
                    // only mode with both a fixed target and a locally-reachable port.
                    if mapping.hasWebUI {
                        WebUIPill()
                    }
                    Spacer(minLength: Spacing.md)
                    Text(mapping.forwardSpec(for: preset.mode))
                        .font(.system(size: 12).monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    // -R's listener is on the remote host, not this Mac, so there's no
                    // local address to copy — only -L/-D have something to paste elsewhere.
                    if preset.mode.listensLocally {
                        Button {
                            copyLocalAddress(mapping)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Copy the local address")
                    }
                    if mapping.hasWebUI {
                        Button {
                            openBrowser(mapping)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Open in browser")
                    }
                }
            }
        }
    }

    /// Deletes a preset and confirms it with the same toast used for add/update.
    private func deleteWithToast(_ preset: TunnelPreset) {
        tunnels.delete(preset.id)
        toastMessage = "Tunnel deleted"
    }

    /// Copies the address this Mac listens on for a mapping, e.g. `127.0.0.1:5432`.
    private func copyLocalAddress(_ mapping: PortMapping) {
        let bind = mapping.bindAddress.trimmingCharacters(in: .whitespaces)
        let address = "\(bind.isEmpty ? "127.0.0.1" : bind):\(mapping.listenPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    /// Opens the mapping's local address in the default browser, e.g. `http://127.0.0.1:3001`.
    private func openBrowser(_ mapping: PortMapping) {
        let bind = mapping.bindAddress.trimmingCharacters(in: .whitespaces)
        let host = bind.isEmpty ? "127.0.0.1" : bind
        guard let url = URL(string: "http://\(host):\(mapping.listenPort)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func consoleBar(_ preset: TunnelPreset) -> some View {
        let entries = tunnels.logEntries(for: preset.id)
        return HStack(spacing: Spacing.md) {
            Text("CONSOLE").font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
            Spacer()
            Text("\(entries.count) line\(entries.count == 1 ? "" : "s")")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            Button {
                copyConsole(preset)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy the console")
            .disabled(entries.isEmpty)
            Button {
                tunnels.clearLogs(preset.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear the console")
            .disabled(entries.isEmpty)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .overlay(alignment: .top) { Rectangle().fill(.appSeparator).frame(height: 1) }
    }

    /// Copies the whole console as plain text, one `HH:mm:ss  message` line each.
    private func copyConsole(_ preset: TunnelPreset) {
        let formatter = Date.FormatStyle.dateTime.hour().minute().second()
        let text = tunnels.logEntries(for: preset.id)
            .map { "\($0.date.formatted(formatter))  \($0.message)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No tunnels", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Add a port forward to reach a service through one of your hosts.")
        } actions: {
            Button("Add Tunnel") { showNew = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func isActive(_ status: TunnelStatus) -> Bool {
        if case .active = status { return true }
        return false
    }

    private func statusLabel(_ status: TunnelStatus) -> String {
        if case .active(let since) = status {
            return "Active · \(TunnelStatusBadge.uptime(since))"
        }
        return status.label
    }

    private func forwardKindLabel(_ preset: TunnelPreset) -> String {
        switch preset.mode.flag {
        case "-R": return "Remote forward"
        case "-D": return "Dynamic forward"
        default: return "Local forward"
        }
    }

    private func forwardSummary(_ preset: TunnelPreset) -> String {
        guard let first = preset.mappings.first else { return preset.mode.flag }
        let base = "\(preset.mode.flag) \(first.forwardSpec(for: preset.mode))"
        let extra = preset.mappings.count - 1
        return extra > 0 ? "\(base)  +\(extra)" : base
    }

    private struct HostGroup {
        let host: String
        let presets: [TunnelPreset]
    }

    private var hostGroups: [HostGroup] {
        Dictionary(grouping: tunnels.presets, by: \.hostAlias)
            .map { HostGroup(host: $0.key.isEmpty ? "(no host)" : $0.key, presets: $0.value) }
            .sorted { $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending }
    }

    private var selected: TunnelPreset? {
        guard let selection else { return nil }
        return tunnels.presets.first { $0.id == selection }
    }
}
