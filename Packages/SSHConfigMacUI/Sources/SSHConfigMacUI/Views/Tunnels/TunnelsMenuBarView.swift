//
//  TunnelsMenuBarView.swift
//  sshconfigmanager
//
//  The dropdown for the dedicated tunnels menu-bar status item. It appears
//  whenever at least one tunnel is live (see `showTunnelMenuBar` + the
//  `MenuBarExtra` in `sshconfigmanagerApp`), and lists every running tunnel with
//  its live status, throughput, and quick actions: jump to its console in the
//  main window ("Logs") or stop it.
//

import AppKit
import SSHConfigCore
import SwiftUI

struct TunnelsMenuBarView: View {
    @Environment(TunnelStore.self) private var tunnels
    @Environment(\.openWindow) private var openWindow

    /// Running = anything not stopped/failed: active, starting, retrying, degraded.
    private var running: [TunnelPreset] { tunnels.runningPresets }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if running.isEmpty {
                Text("No active tunnels.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(12)
            } else if running.count > 6 {
                // Many tunnels: scroll within a fixed height.
                ScrollView { rows }.frame(height: 380)
            } else {
                // A few tunnels: let the popover size to its content. A ScrollView
                // here reports ~0 ideal height and collapses the list to nothing.
                rows
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    /// The list of running-tunnel rows, sized to content (the popover grows to fit).
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(running) { preset in
                row(preset)
                if preset.id != running.last?.id { Divider().padding(.leading, 12) }
            }
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.tint)
            Text("Active Tunnels").font(.headline)
            Spacer()
            Text("\(running.count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .padding(12)
    }

    private func row(_ preset: TunnelPreset) -> some View {
        let status = tunnels.status(for: preset.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.symbol)
                    .foregroundStyle(color(for: status))
                    .font(.body)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName).fontWeight(.medium).lineLimit(1)
                    Text("through \(preset.hostAlias)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(forwardSummary(preset))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(statusLabel(status))
                            .font(.caption2).foregroundStyle(color(for: status))
                        if let bytes = tunnels.throughput[preset.id] {
                            Text(bytes.summary)
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 4)
            }
            HStack(spacing: 8) {
                Spacer()
                Button {
                    showLogs(preset)
                } label: {
                    Label("Logs", systemImage: "text.alignleft")
                }
                .controlSize(.small)
                Button(role: .destructive) {
                    tunnels.stop(preset.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack {
            Button("Open Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            if running.count > 1 {
                Button("Stop All") {
                    for tunnel in running { tunnels.stop(tunnel.id) }
                }
            }
        }
        .padding(10)
    }

    /// Opens the main window and asks it to reveal this tunnel's console.
    private func showLogs(_ preset: TunnelPreset) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        tunnels.requestConsole(preset.id)
    }

    private func forwardSummary(_ preset: TunnelPreset) -> String {
        guard let first = preset.mappings.first else { return preset.mode.flag }
        let base = "\(preset.mode.flag) \(first.forwardSpec(for: preset.mode))"
        let extra = preset.mappings.count - 1
        return extra > 0 ? "\(base)  +\(extra)" : base
    }

    private func statusLabel(_ status: TunnelStatus) -> String {
        if case .active(let since) = status { return "Active · \(TunnelStatusBadge.uptime(since))" }
        return status.label
    }

    private func color(for status: TunnelStatus) -> Color {
        switch status {
        case .stopped: return .secondary
        case .starting, .retrying: return .yellow
        case .active: return .green
        case .degraded: return .orange
        case .failed: return .red
        }
    }
}
