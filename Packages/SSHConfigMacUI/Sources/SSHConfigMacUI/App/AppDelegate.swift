//
//  AppDelegate.swift
//  SSHConfigMacUI
//
//  Extracted from the former `sshconfigmanagerApp.swift`. `public` because the
//  app target's `@NSApplicationDelegateAdaptor(AppDelegate.self)` must be able to
//  name and instantiate the type across the module boundary — this is the only
//  reason it (and its `init`) are public. The @objc dock selectors stay private;
//  AppKit dispatches the NSApplicationDelegate methods via the ObjC runtime, so
//  they need not be public.
//

import AppKit
import SSHConfigCore
import SwiftUI
@preconcurrency import UserNotifications

/// Handles app-wide lifecycle: keep running in the menu bar after the window
/// closes, and prompt to save unsaved edits on quit when autosave is off.
///
/// `@MainActor`: AppKit always calls these delegate methods on the main thread,
/// so declaring the isolation (rather than asserting it with `assumeIsolated`)
/// lets us touch the main-actor stores directly and clears the Swift 6
/// nonisolated-context warnings.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    public override init() { super.init() }

    /// KVO token for `NSApp.effectiveAppearance`. macOS never switches the Dock
    /// icon by light/dark on its own (appearance-aware app icons are iOS-only), so
    /// we override it at runtime from `applyDockIconForAppearance()` and re-apply
    /// whenever the system theme changes. Retained for the app's lifetime; the
    /// AppDelegate outlives any theme change so there is nothing to invalidate.
    private var appearanceObservation: NSKeyValueObservation?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The Dock/Finder icon baked into the bundle is static (always the light
        // variant on macOS). Swap it to match the live appearance and keep it in
        // sync as the user toggles light/dark. Only takes effect while running —
        // when the app is closed the Dock falls back to the static light icon.
        applyDockIconForAppearance()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyDockIconForAppearance() }
        }

        // Receive host-key-monitor notifications so a tap routes the app to the affected
        // host on the Known Hosts screen (and so they show as banners in the foreground).
        UNUserNotificationCenter.current().delegate = self

        Task.detached(priority: .utility) {
            await AppDatabase.shared?.prepare()
        }

        #if DEBUG
            // Dev-only sandbox self-check: when launched with --sandbox-selfcheck,
            // exercise the entitlements that the in-process tunnel engine needs
            // (binding a loopback listener = network.server) inside the *real*
            // sandboxed process, print the result, and exit.
            guard CommandLine.arguments.contains("--sandbox-selfcheck") else { return }
            SandboxSelfCheck.run()
        #endif
    }

    /// Pick the light or dark Dock icon to match the current effective appearance
    /// and assign it to `NSApp.applicationIconImage`. The images are standalone
    /// image sets (`DockIconLight`/`DockIconDark`) in the app bundle's asset
    /// catalog — separate from `AppIcon`, which AppKit treats as static. Falls
    /// back to the baked-in icon (nil) if an asset is somehow missing.
    private func applyDockIconForAppearance() {
        let isDark =
            NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = isDark ? "DockIconDark" : "DockIconLight"
        NSApp.applicationIconImage = NSImage(named: name)
    }

    // MARK: - Dock menu

    /// The right-click / long-press menu on the Dock icon. Built fresh on every
    /// invocation so it always reflects current state: live tunnels (toggle in
    /// place), public keys (copy to clipboard), and hosts (copy `ssh …` command).
    /// AppKit appends its standard items (window list, Options, Quit) below.
    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        buildDockMenu()
    }

    private func buildDockMenu() -> NSMenu {
        let menu = NSMenu()
        let tunnels = TunnelStore.shared
        let store = ConfigStore.shared

        if !tunnels.presets.isEmpty {
            let groups = tunnelGroups(tunnels.presets)
            menu.addItem(sectionHeader("Tunnels"))
            if tunnels.presets.count > Self.dockTunnelSubmenuThreshold {
                for group in groups {
                    let parent = NSMenuItem(title: group.host, action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    for preset in group.presets { submenu.addItem(tunnelItem(for: preset)) }
                    parent.submenu = submenu
                    menu.addItem(parent)
                }
            } else {
                for group in groups {
                    menu.addItem(hostHeader(group.host))
                    for preset in group.presets {
                        let item = tunnelItem(for: preset)
                        item.indentationLevel = 1
                        menu.addItem(item)
                    }
                }
            }
            menu.addItem(.separator())
        }

        // Copy a public key to the clipboard.
        let copyableKeys = store.publicKeys.filter { $0.publicKeyURL != nil }
        if !copyableKeys.isEmpty {
            let submenu = NSMenu()
            for key in copyableKeys {
                let item = NSMenuItem(
                    title: key.name,
                    action: #selector(dockCopyPublicKey(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = key.publicKeyURL
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: "Copy Public Key", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }

        // Copy the `ssh <alias>` command for a host.
        let hosts = store.searchableHosts(matching: "")
        if !hosts.isEmpty {
            let submenu = NSMenu()
            for host in hosts {
                let item = NSMenuItem(
                    title: host.title,
                    action: #selector(dockCopyHostCommand(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = host.id.uuidString
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: "Copy SSH Command", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }

        return menu
    }

    /// A disabled, non-selectable label row used to title a group of items.
    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// An indented, disabled sub-header naming the SSH host a group of tunnels
    /// runs through — the "project" label under the "Tunnels" heading.
    private func hostHeader(_ host: String) -> NSMenuItem {
        let item = sectionHeader(host)
        item.indentationLevel = 1
        return item
    }

    private struct TunnelGroup {
        let host: String
        let presets: [TunnelPreset]
    }

    /// Above this many total tunnels, the Dock menu switches from a flat grouped
    /// list to one submenu per host. Chosen so the flat list stays comfortably
    /// on-screen (each tunnel plus its host header is one row) before collapsing.
    private static let dockTunnelSubmenuThreshold = 12

    /// Group presets by their `hostAlias`, mirroring the Tunnels screen so the
    /// Dock menu presents the same grouping. Groups are host-sorted; presets keep
    /// their existing order within each group.
    private func tunnelGroups(_ presets: [TunnelPreset]) -> [TunnelGroup] {
        Dictionary(grouping: presets, by: \.hostAlias)
            .map { TunnelGroup(host: $0.key.isEmpty ? "(no host)" : $0.key, presets: $0.value) }
            .sorted { $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending }
    }

    /// A single toggle row for a tunnel: checkmark = running, selecting starts or
    /// stops it. Shared by the flat and submenu layouts so both behave identically.
    private func tunnelItem(for preset: TunnelPreset) -> NSMenuItem {
        let item = NSMenuItem(
            title: preset.displayName,
            action: #selector(dockToggleTunnel(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = preset.id.uuidString
        item.state = TunnelStore.shared.status(for: preset.id).isRunning ? .on : .off
        return item
    }

    @objc private func dockToggleTunnel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        let tunnels = TunnelStore.shared
        guard let preset = tunnels.presets.first(where: { $0.id == id }) else { return }
        tunnels.toggle(preset)
    }

    @objc private func dockCopyPublicKey(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
    }

    @objc private func dockCopyHostCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        let store = ConfigStore.shared
        guard let host = store.searchableHosts(matching: "").first(where: { $0.id == id }) else { return }
        store.copySSHCommand(for: host)
    }

    // MARK: - Notifications (host-key monitor)

    /// Show host-key alerts as banners even when the app is frontmost.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A tapped host-key, known_hosts-change, or config-change notification routes the
    /// main window to the relevant screen (ConfigStore drives the navigation;
    /// ContentView/KnownHostsView observe the pending selection/focus flags).
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let category = response.notification.request.content.categoryIdentifier
        let groupID = response.notification.request.content.userInfo["groupID"] as? String
        await MainActor.run {
            switch category {
            case ConfigStore.knownHostsChangeCategoryIdentifier:
                ConfigStore.shared.pendingKnownHostsFocus = true
            case ConfigStore.configChangeCategoryIdentifier:
                ConfigStore.shared.pendingHistoryFocus = true
            default:
                if let groupID { ConfigStore.shared.pendingKnownHostsSelection = groupID }
            }
            NSApp.activate(ignoringOtherApps: true)
            // Re-open the main window if it was closed to the menu bar.
            for window in NSApp.windows where window.identifier?.rawValue == "main" {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive in the menu bar when the main window is closed; otherwise quit.
        return !AppSettings.shared.showMenuBarExtra
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = ConfigStore.shared
        guard store.isDirty else { return .terminateNow }

        if store.autosaveEnabled {
            store.flushPendingSave()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Save changes to your SSH config?"
        alert.informativeText = "You have unsaved changes. If you don’t save them, they will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.flushPendingSave()
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
