//
//  LoginItemService.swift
//  sshconfigmanager
//
//  Thin wrapper over `SMAppService.mainApp` for the "Launch at login" toggle. The OS
//  is the source of truth here (the user can also flip it in System Settings ▸ General
//  ▸ Login Items), so we never cache the state in our own SQLite — the General pane
//  reads `isEnabled` live and calls `setEnabled` on toggle. Sandboxed apps are allowed
//  to register *themselves* as a login item, which is exactly this API.
//

import Foundation
import ServiceManagement

enum LoginItemService {
    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers/unregisters the app as a login item. Returns whether the change
    /// stuck; throwing registration errors are swallowed into a `false` so the UI can
    /// just reflect the resulting `isEnabled`.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return isEnabled
        }
        return isEnabled
    }
}
