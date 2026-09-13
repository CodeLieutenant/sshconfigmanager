//
//  ContentView.swift
//  sshconfigmanager
//
//  Created by Dusan Malusev on 4. 6. 2026..
//

import SSHConfigCore
import SwiftUI

/// What is currently selected in the sidebar.
enum SidebarSelection: Hashable {
    case host(HostBlock.ID)
    /// The pinned "Global Defaults" (`Host *`) entry. Deliberately not `.host(id)`:
    /// it must stay selectable even when no `Host *` block exists yet.
    case globalDefaults
    case keys
    case agent
    case knownHosts
    case issues
    case history
    case tunnels
    case gistSync
}

struct ContentView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelStore.self) private var tunnels
    @Environment(GistSyncStore.self) private var gistSync
    @Environment(\.undoManager) private var undoManager
    @State private var selection: SidebarSelection?

    var body: some View {
        @Bindable var store = store
        return Group {
            if store.hasAccess {
                mainInterface
            } else {
                GrantAccessView()
            }
        }
        .background(WindowChromeConfigurator())
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert(
            "Connect",
            isPresented: Binding(
                get: { store.launchStatus != nil },
                set: { if !$0 { store.launchStatus = nil } })
        ) {
            Button("OK", role: .cancel) { store.launchStatus = nil }
        } message: {
            Text(store.launchStatus ?? "")
        }
        // An `Include` (or the config itself) pointing outside the granted folder —
        // whether via a symlink or just an ordinary path that was never granted —
        // leaves those hosts silently missing with no explanation. This walks the
        // user straight to granting access instead of leaving them to find a
        // "Can't read" finding buried in Issues (or not find it at all).
        .alert(
            "Grant Access to Continue Reading Your Config",
            isPresented: Binding(
                get: { store.pendingSymlinkAccessRequest != nil },
                set: { if !$0 { store.dismissPendingSymlinkAccessRequest() } })
        ) {
            Button("Not Now", role: .cancel) { store.dismissPendingSymlinkAccessRequest() }
            Button("Grant Access…") { store.grantAccessToPendingSymlinkRequest() }
        } message: {
            if let issue = store.pendingSymlinkAccessRequest, let target = issue.symlinkTarget {
                if target == issue.url {
                    Text(
                        "An `Include` in your config points to “\(target.path)”, "
                            + "which is outside the folder you granted SSH Config Manager access to — "
                            + "the sandbox can't reach it, so those hosts are missing.\n\n"
                            + "Grant access to “\(target.deletingLastPathComponent().path)” to fix this.")
                } else {
                    Text(
                        "“\(issue.url.lastPathComponent)” is a symlink to “\(target.path)”, "
                            + "which is outside the folder you granted SSH Config Manager access to — "
                            + "the sandbox can't follow it, so this file reads as empty.\n\n"
                            + "Grant access to “\(target.deletingLastPathComponent().path)” to fix this.")
                }
            }
        }
        // A hop's `IdentityAgent` socket or `UserKnownHostsFile` pointing outside
        // every granted folder (almost always a third-party agent like 1Password, or
        // a known_hosts file elsewhere) — the sandbox can't reach it. Same fix as the
        // symlink case: grant the path's containing folder.
        .alert(
            "Grant Access to Continue",
            isPresented: Binding(
                get: { store.pendingExternalAccessRequest != nil },
                set: { if !$0 { store.dismissPendingExternalAccessRequest() } })
        ) {
            Button("Not Now", role: .cancel) { store.dismissPendingExternalAccessRequest() }
            Button("Grant Access…") { store.grantAccessToPendingExternalAccessRequest() }
        } message: {
            if let issue = store.pendingExternalAccessRequest {
                switch issue.reason {
                case .agentSocket(let hopDescription):
                    Text(
                        "The `IdentityAgent` configured for \(hopDescription) points to "
                            + "“\(issue.path.path)”, which is outside the folder(s) you've granted "
                            + "SSH Config Manager access to — the sandbox can't reach it, so this hop "
                            + "connects without ssh-agent auth.\n\n"
                            + "Grant access to “\(issue.path.deletingLastPathComponent().path)” to fix this.")
                case .userKnownHostsFile(let hopDescription):
                    Text(
                        "The `UserKnownHostsFile` configured for \(hopDescription) points to "
                            + "“\(issue.path.path)”, which is outside the folder(s) you've granted "
                            + "SSH Config Manager access to — the sandbox can't reach it.\n\n"
                            + "Grant access to “\(issue.path.deletingLastPathComponent().path)” to fix this.")
                case .revokedHostKeys(let hopDescription):
                    Text(
                        "The `RevokedHostKeys` file configured for \(hopDescription) points to "
                            + "“\(issue.path.path)”, which is outside the folder(s) you've granted "
                            + "SSH Config Manager access to — the sandbox can't reach it.\n\n"
                            + "Grant access to “\(issue.path.deletingLastPathComponent().path)” to fix this.")
                }
            }
        }
        .sheet(isPresented: $store.showCommandPalette) {
            CommandPaletteView { id in
                selection = .host(id)
            }
            .environment(store)
        }
        .onChange(of: undoManager, initial: true) { _, manager in
            store.undoManager = manager
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            store.checkForExternalChanges()
            Task { await gistSync.autoSyncIfNeeded() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willResignActiveNotification)
        ) { _ in
            if store.autosaveEnabled { store.flushPendingSave() }
        }
    }

    private var mainInterface: some View {
        splitView
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .onChange(of: selection) { _, newValue in
            if case .host(let id) = newValue { store.selectedBlockID = id }
        }
        .onChange(of: store.selectedBlockID) { _, newID in
            if let newID, selection != .host(newID) { selection = .host(newID) }
        }
        // The menu-bar "Logs" action sets this; jump to the Tunnels screen so
        // TunnelsManagementView can select the requested tunnel.
        .onChange(of: tunnels.consoleFocus, initial: true) { _, focus in
            if focus != nil { selection = .tunnels }
        }
        // A menu-bar host-key alert or a tapped notification asks to focus the Known
        // Hosts screen; KnownHostsView then consumes the pending group id to select it.
        .onChange(of: store.pendingKnownHostsSelection, initial: true) { _, pending in
            if pending != nil { selection = .knownHosts }
        }
        // A tapped "known_hosts changed" live-file-watch notification — jump to Known
        // Hosts so the fresh externalKnownHostsChange banner is visible immediately.
        .onChange(of: store.pendingKnownHostsFocus, initial: true) { _, focus in
            if focus {
                selection = .knownHosts
                store.pendingKnownHostsFocus = false
            }
        }
        // A tapped "config changed" live-file-watch notification — jump to Version
        // History so the freshly-recorded external version is visible immediately.
        .onChange(of: store.pendingHistoryFocus, initial: true) { _, focus in
            if focus {
                selection = .history
                store.pendingHistoryFocus = false
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .host(let id):
            if store.block(id: id) != nil {
                HostDetailView(blockID: id).id(id)
            } else {
                placeholder
            }
        case .globalDefaults:
            if let block = store.globalDefaultsBlock {
                HostDetailView(blockID: block.id).id(block.id)
            } else {
                globalDefaultsPlaceholder
            }
        case .keys:
            KeysView()
        case .agent:
            AgentView()
        case .knownHosts:
            KnownHostsView()
        case .tunnels:
            TunnelsManagementView()
        case .issues:
            IssuesView(selection: $selection)
        case .history:
            VersionHistoryView()
        case .gistSync:
            GistSyncView()
        case nil:
            placeholder
        }
    }

    /// Shown for the pinned "Global Defaults" entry before any `Host *` block
    /// exists. Nothing is written to the config until "Add Global Defaults" is
    /// pressed — just navigating here creates nothing.
    private var globalDefaultsPlaceholder: some View {
        ContentUnavailableView {
            Label("No Global Defaults Yet", systemImage: "asterisk")
        } description: {
            Text(
                "A Host * block applies settings to every host that doesn't already set them itself — "
                    + "handy for things like User or IdentityFile you'd otherwise repeat everywhere.")
        } actions: {
            Button("Add Global Defaults") { store.ensureGlobalDefaultsBlock() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if store.allHostBlocks.isEmpty {
            ContentUnavailableView {
                Label("No Hosts Yet", systemImage: "server.rack")
            } description: {
                Text("Add a host to get started, or drop your ~/.ssh/config onto the sidebar.")
            } actions: {
                Button("Add Host") {
                    if let id = store.addHost() { selection = .host(id) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "Select a host", systemImage: "server.rack",
                description: Text("Choose an entry from the sidebar."))
        }
    }
}

#Preview {
    ContentView()
        .environment(ConfigStore())
        .environment(TunnelStore.shared)
}
