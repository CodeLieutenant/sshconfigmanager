//
//  sshconfigmanagerApp.swift
//  sshconfigmanager
//
//  Created by Dusan Malusev on 4. 6. 2026..
//
//  The entire app target: a thin @main shell. The scene graph (`RootScene`) and
//  the lifecycle delegate (`AppDelegate`) live in the SSHConfigMacUI package, so
//  all views, stores, and services stay behind that module boundary. The only
//  things the app bundle still owns are this shell, the asset catalog (AppIcon),
//  entitlements, and Info.plist.
//

import SSHConfigMacUI
import SwiftUI

@main
struct SSHConfigManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        RootScene()
    }
}
