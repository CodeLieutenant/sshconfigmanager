//
//  TunnelsSection.swift
//  sshconfigmanager
//
//  The "Tunnels" card shown in HostDetailView's right column: the host's saved tunnels
//  with a one-click start/stop toggle and live status, plus an add row. Restyled from the
//  old grouped-`Form` `Section` to the redesign's lifted `CardSection`; behaviour (toggle,
//  status, throughput, per-tunnel menu, editor/activity sheets) is unchanged.
//

import AppKit
import SSHConfigCore
import SwiftUI

struct TunnelsSection: View {
    @Environment(TunnelStore.self) private var tunnels
    @Environment(ConfigStore.self) private var config
    let hostAlias: String

    @State private var editing: TunnelPreset?
    @State private var activityFor: TunnelPreset?
    @State private var showNew = false
    @State private var toastMessage: String?

    private var presets: [TunnelPreset] { tunnels.presets(for: hostAlias) }

    var body: some View {
        content
    }

    private var content: some View {
        CardSection("Tunnels") {
            if presets.isEmpty {
                CardRow {
                    Text("No tunnels yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(presets) { preset in
                row(preset)
            }
            AccentRow(title: "Add Tunnel", systemImage: "plus") { showNew = true }
                .disabled(hostAlias.isEmpty)
        }
        .sheet(isPresented: $showNew) {
            TunnelEditorView(hostAlias: hostAlias, existing: nil, onAdded: { toastMessage = "Tunnel added" })
        }
        .sheet(item: $editing) { preset in
            TunnelEditorView(
                hostAlias: hostAlias, existing: preset,
                onUpdated: { toastMessage = "Tunnel updated" })
        }
        .sheet(item: $activityFor) { preset in
            TunnelActivityView(preset: preset)
        }
        .toast($toastMessage)
    }

    private func row(_ preset: TunnelPreset) -> some View {
        let status = tunnels.status(for: preset.id)
        return CardRow(minHeight: 44) {
            Button {
                tunnels.toggle(preset)
            } label: {
                Image(systemName: status.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(status.isRunning ? .red : .green)
            }
            .buttonStyle(.plain)
            .help(status.isRunning ? "Stop tunnel" : "Start tunnel")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(preset.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
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
                TunnelStatusBadge(status: status)
                if let bytes = tunnels.throughput[preset.id] {
                    Text(bytes.summary)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Spacing.sm)

            // Only -L has both a fixed target and a listen port reachable on this
            // Mac, so only it can offer a working browser shortcut.
            if let webUIMapping = preset.mappings.first(where: \.hasWebUI) {
                ChromeButton(icon: "safari", help: "Open in Browser") { openBrowser(webUIMapping) }
            }

            Menu {
                Button("Edit…") { editing = preset }
                if let webUIMapping = preset.mappings.first(where: \.hasWebUI) {
                    Button("Open in Browser") { openBrowser(webUIMapping) }
                }
                Button("Copy ssh Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        TunnelCommandBuilder.commandString(for: preset), forType: .string)
                }
                Button("Write to ssh config") {
                    config.writeForwardDirectives(preset.forwardDirectives, toHostAlias: hostAlias)
                }
                .help("Add the matching LocalForward/RemoteForward/DynamicForward line to this host")
                Button("Activity…") { activityFor = preset }
                Divider()
                Button("Delete", role: .destructive) { deleteWithToast(preset) }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More tunnel actions")
        }
    }

    /// Deletes a preset and confirms it with the same toast used for add/update.
    private func deleteWithToast(_ preset: TunnelPreset) {
        tunnels.delete(preset.id)
        toastMessage = "Tunnel deleted"
    }

    /// Opens the mapping's local address in the default browser, e.g. `http://127.0.0.1:3001`.
    private func openBrowser(_ mapping: PortMapping) {
        let bind = mapping.bindAddress.trimmingCharacters(in: .whitespaces)
        let host = bind.isEmpty ? "127.0.0.1" : bind
        guard let url = URL(string: "http://\(host):\(mapping.listenPort)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A card row whose whole width is a tap target with accent-tinted label + leading glyph
/// — the "Add Identity Key" / "Add Tunnel" affordances.
struct AccentRow: View {
    let title: String
    var systemImage: String = "plus"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            CardRow {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
