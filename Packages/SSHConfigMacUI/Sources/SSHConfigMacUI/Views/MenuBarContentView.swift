//
//  MenuBarContentView.swift
//  sshconfigmanager
//
//  The dropdown shown by the menu-bar extra: searchable hosts with quick copy.
//

import AppKit
import SSHConfigCore
import SwiftUI

struct MenuBarContentView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelStore.self) private var tunnels
    @Environment(HostKeyMonitor.self) private var hostKeyMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var copied: HostBlock.ID?

    private var hosts: [HostBlock] {
        store.searchableHosts(matching: search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !store.hasAccess {
                Text("Open the app and grant access to your ~/.ssh folder to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                hostKeySection
                tunnelControlCenter
                TextField("Search hosts", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                hostList
            }

            Divider()
            footer
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill").foregroundStyle(.tint)
            Text("SSH Hosts").font(.headline)
            Spacer()
        }
        .padding(12)
    }

    private var hostList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if hosts.isEmpty {
                    Text(search.isEmpty ? "No hosts" : "No matches")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                ForEach(hosts) { host in
                    Button {
                        store.copySSHCommand(for: host)
                        copied = host.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.title).lineLimit(1)
                                if let name = host.firstValue(for: "HostName") {
                                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if copied == host.id {
                                Text("Copied").font(.caption).foregroundStyle(.green)
                            } else {
                                Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .help("Copy `ssh \(host.title)`")
                    .contextMenu {
                        if host.connectionTarget != nil {
                            Button("Connect") { store.connect(host) }
                        }
                        Button("Copy ssh Command") { store.copySSHCommand(for: host) }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 320)
    }

    /// Background host-key monitor: any detected changes (one click to review/resolve in
    /// the app), plus a status row with "Check Now".
    @ViewBuilder
    private var hostKeySection: some View {
        let alerts = hostKeyMonitor.alerts
        let fresh = hostKeyMonitor.freshness
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: alerts.isEmpty ? fresh.symbol : "exclamationmark.shield.fill")
                    .foregroundStyle(alerts.isEmpty ? fresh.tint.color : Color.orange)
                Text(alerts.isEmpty ? "Host Keys" : "\(alerts.count) host key change\(alerts.count == 1 ? "" : "s")")
                    .font(.caption).fontWeight(alerts.isEmpty ? .regular : .semibold)
                    .foregroundStyle(alerts.isEmpty ? Color.secondary : Color.primary)
                Spacer()
                if hostKeyMonitor.isChecking {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Check Now") { hostKeyMonitor.checkNow() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            ForEach(alerts) { alert in
                Button {
                    focusKnownHosts(alert.groupID)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: alert.kind == .changed ? "exclamationmark.triangle.fill" : "plus.circle")
                            .foregroundStyle(alert.kind == .changed ? .red : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.displayName).lineLimit(1)
                            Text(alert.kind == .changed ? "\(alert.keyType) key changed" : "new \(alert.keyType) key")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .help("Review and resolve \(alert.hostTitle)")
            }

            if let last = hostKeyMonitor.lastCheck {
                Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.top, 2)
            }
        }
        .padding(.bottom, 6)
        Divider()
    }

    private func focusKnownHosts(_ groupID: String) {
        store.pendingKnownHostsSelection = groupID
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Active tunnels with quick stop — shown only when something is running.
    @ViewBuilder
    private var tunnelControlCenter: some View {
        let running = tunnels.runningPresets
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tunnels")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                ForEach(running) { preset in
                    HStack(spacing: 8) {
                        TunnelStatusBadge(status: tunnels.status(for: preset.id), showsLabel: false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.displayName).lineLimit(1)
                            Text(preset.hostAlias).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop") { tunnels.stop(preset.id) }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
            }
            Divider()
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(10)
    }
}
