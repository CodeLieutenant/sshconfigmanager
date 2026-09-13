//
//  SettingsView.swift
//  sshconfigmanager
//
//  App preferences (⌘,). A standard macOS tabbed preferences window: each tab is a
//  self-contained pane (see `Views/Settings/SettingsPanes.swift`). This file is just
//  the shell that wires the tabs together; `RootScene` hosts it in the `Settings`
//  scene.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsPane()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            EditorSettingsPane()
                .tabItem { Label("Editor", systemImage: "curlybraces") }
            KeysTunnelsSettingsPane()
                .tabItem { Label("Keys & Tunnels", systemImage: "key") }
            HistorySettingsPane()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            AuditSettingsPane()
                .tabItem { Label("Audit", systemImage: "checkmark.shield") }
        }
        .frame(width: 540, height: 580)
        .accessibilityIdentifier("settings-root")
    }
}

#Preview {
    SettingsView()
}
