//
//  RootScene.swift
//  SSHConfigMacUI
//
//  The app's entire scene graph, extracted from the former
//  `sshconfigmanagerApp.App.body` so the app target is a thin @main shell. Owns
//  the observable stores and wires them into every scene's environment.
//
//  This is one of exactly two public symbols the package vends (the other is
//  `AppDelegate`); keeping the scene composition in-package lets the stores and
//  views stay `internal`.
//

import AppKit
import CoreSpotlight
import SSHConfigCore
import SwiftUI

public struct RootScene: Scene {
    @Environment(\.openWindow) private var openWindow
    @State private var store = ConfigStore.shared
    @State private var tunnels = TunnelStore.shared
    @State private var settings = AppSettings.shared
    @State private var hostKeyMonitor = HostKeyMonitor.shared
    @State private var gistSync = GistSyncStore.shared
    /// Guards the one-time launch sequence in `.onAppear` below against re-firing
    /// when the main window is closed and reopened (audit #21/#22).
    @State private var launchCoordinator = LaunchOnceCoordinator()

    public init() {}

    public var body: some Scene {
        @Bindable var settings = settings
        // Read live tunnel state *in the scene body* so SwiftUI re-evaluates (and
        // inserts/removes the tunnels status item) as tunnels start and stop.
        let activeTunnels = tunnels.runningPresets.count
        let showTunnelItem = settings.showTunnelMenuBar && activeTunnels > 0
        // NB: no explicit `return` — an explicit return would disable the
        // @SceneBuilder transform and silently drop every scene after the first
        // (the menu-bar items and Settings). Let the builder compose them.
        Window("SSH Config Manager", id: "main") {
            ContentView()
                .environment(store)
                .environment(tunnels)
                .environment(hostKeyMonitor)
                .environment(gistSync)
                .frame(minWidth: 860, minHeight: 560)
                // Re-arm the background host-key monitor whenever the toggle or
                // cadence changes (it self-gates on the enabled flag).
                .onChange(of: settings.hostKeyMonitorEnabled) { _, _ in hostKeyMonitor.rearm() }
                .onChange(of: settings.hostKeyCheckIntervalMinutes) { _, _ in hostKeyMonitor.rearm() }
                // Same idea for the real-time config/known_hosts watchers — they
                // self-gate on the enabled flag inside updateFileWatchers().
                .onChange(of: settings.liveFileWatchEnabled) { _, _ in store.updateFileWatchers() }
                // Appearance preferences. `nil` color scheme / tint = follow the system
                // (the default), so a fresh install looks exactly as before.
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .tint(settings.accentChoice.color)
                .controlSize(settings.uiDensity.controlSize)
                // A Spotlight result click delivers CSSearchableItemActionType with the
                // host's primary alias encoded in the identifier; select it in the sidebar.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    handleSpotlightActivity(activity)
                }
                .onAppear {
                    Log.app.notice(
                        "launch: v\(DeviceInfo.appVersion ?? "?") (\(DeviceInfo.appBuild ?? "?")) on \(DeviceInfo.osVersion, privacy: .public)"
                    )
                    #if DEBUG
                        // Screenshot/preview harness: pin a deterministic capture size once
                        // the window exists (after this layout pass).
                        if ScreenshotMode.isActive {
                            DispatchQueue.main.async { ScreenshotMode.applyWindowFrame() }
                        }
                    #endif
                    Task {
                        await launchCoordinator.runOnce {
                            store.restoreOnLaunch()
                            // Settings load asynchronously from SQLite; wait up front so
                            // the launch work below reads resolved values.
                            await settings.waitUntilLoaded()
                            await BuildEnvironment.shared.refresh()
                            if settings.restoreTunnelsOnLaunch {
                                tunnels.restoreAutostartTunnels()
                            }
                            // Begin the background known-hosts monitor now that settings
                            // are resolved (it self-gates and re-arms on changes).
                            hostKeyMonitor.start()
                        }
                    }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Save Now") { store.flushPendingSave() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!store.isDirty)
                Button("Revert to Saved") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!store.hasAccess)
            }
            CommandGroup(after: .newItem) {
                Button("New Host") { store.addHost() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!store.hasAccess)
                Button("Import Hosts from Clipboard…") { importFromClipboard() }
                    .disabled(!store.hasAccess)
            }
            CommandGroup(after: .toolbar) {
                Button("Find Host…") { store.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!store.hasAccess)
                Divider()
                Button("Open Logs") { openWindow(id: "logs") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            // Replace the stock (empty) Help menu with a real one: the in-app help
            // book and the issue tracker.
            CommandGroup(replacing: .help) {
                HelpMenuButtons()
            }
        }

        MenuBarExtra(
            "SSH Config", systemImage: "key.fill",
            isInserted: .constant(settings.showMenuBarExtra)
        ) {
            MenuBarContentView()
                .environment(store)
                .environment(tunnels)
                .environment(hostKeyMonitor)
        }
        .menuBarExtraStyle(.window)

        // A dedicated status item that appears only while tunnels are live, so the
        // user always has eyes on what's running and one click to its logs.
        MenuBarExtra(isInserted: .constant(showTunnelItem)) {
            TunnelsMenuBarView()
                .environment(store)
                .environment(tunnels)
        } label: {
            // The badge count rides next to the icon in the menu bar.
            Label(
                "\(activeTunnels) active tunnels",
                systemImage: "point.3.connected.trianglepath.dotted")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(tunnels)
        }

        // The in-app help book (Help ▸ SSH Config Manager Help, ⌘?). A dedicated
        // single window so it can be opened, focused, and closed independently.
        Window("SSH Config Manager Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 860, height: 620)

        // The log window (View ▸ Open Logs, ⇧⌘L) — the app's own unified-log
        // entries, so a user can see what happened without Console.app.
        Window("Logs", id: "logs") {
            LogViewerView()
        }
        .defaultSize(width: 900, height: 560)
    }

    private func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let added = store.importHosts(fromText: text)
        if added == 0 { store.errorMessage = "No SSH host blocks were found on the clipboard." }
    }

    /// Routes a Spotlight result tap to the matching host in the sidebar. The unique
    /// identifier encodes the host's primary alias; we look it up by alias (not UUID,
    /// which changes on every config reload) so the navigation is stable across launches.
    private func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let alias = SpotlightIndexer.alias(from: id)
        else { return }
        let host = store.searchableHosts(matching: "").first(where: { $0.primaryAlias == alias })
        guard let host else { return }
        store.selectedBlockID = host.id
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue == "main" {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Menu command content

/// The Help menu: the in-app help book and the project's issue tracker.
private struct HelpMenuButtons: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("SSH Config Manager Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
        Divider()
        Button("Source Code on GitHub") { open(AppLinks.repository) }
        Button("Report a Bug…") { open(AppLinks.newIssue) }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
