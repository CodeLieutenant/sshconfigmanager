//
//  GrantAccessView.swift
//  sshconfigmanager
//
//  First-run screen asking the user to grant access to their ~/.ssh folder.
//

import SwiftUI

struct GrantAccessView: View {
    @Environment(ConfigStore.self) private var store

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            IconTile(systemImage: "lock.shield.fill", color: TilePalette.accent, size: 64)

            Text("Access your SSH configuration")
                .font(.system(size: 22, weight: .bold))

            Text(
                """
                This app edits the files in your **~/.ssh** folder. Because it runs in a \
                sandbox, macOS needs you to grant access once. Your selection is remembered \
                securely and never leaves your Mac.
                """
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 420)

            Button(action: { store.requestAccess() }) {
                Text("Choose ~/.ssh Folder…")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Text("Tip: the folder is preselected. Just click “Grant Access”.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowWash())
    }
}

#Preview {
    GrantAccessView()
        .environment(ConfigStore())
        .frame(width: 600, height: 480)
}
