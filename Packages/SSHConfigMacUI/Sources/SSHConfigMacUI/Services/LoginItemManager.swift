//
//  LoginItemManager.swift
//  sshconfigmanager
//
//  Registers the app to launch at login so it can re-inject "remembered" keys into
//  the running ssh-agent after a reboot (reloadPersistedAgentKeys runs on launch).
//  This is what makes our `--apple-use-keychain` equivalent actually persist: macOS
//  relaunches us at login, we read the stored passphrases and re-add the keys.
//
//  Uses `SMAppService.mainApp` (macOS 13+, sandbox- and App-Store-compatible). The
//  app is already a resident menu-bar utility that restores autostart tunnels, so
//  launching at login fits its existing shape.
//

import Foundation
import ServiceManagement
import os

enum LoginItemManager {
    private static let log = Log.loginItem

    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers the app as a login item. Idempotent; safe to call when already
    /// enabled. Best-effort: logs and swallows failures (e.g. user denied in
    /// System Settings → Login Items), since persistence degrades gracefully to
    /// "reloaded whenever the app is next opened."
    static func enable() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            log.error("Couldn't register login item: \(error.localizedDescription)")
        }
    }

    /// Unregisters the login item. Best-effort.
    static func disable() {
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            log.error("Couldn't unregister login item: \(error.localizedDescription)")
        }
    }
}
