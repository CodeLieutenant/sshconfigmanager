//
//  RawBlockEditor.swift
//  sshconfigmanager
//
//  A raw-text editor for a single block, with reparse-on-apply.
//

import SSHConfigCore
import SSHConfigServices
import SwiftUI

struct RawBlockEditor: View {
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelStore.self) private var tunnels
    @State private var settings = AppSettings.shared
    let blockID: HostBlock.ID
    @Binding var showRaw: Bool

    @State private var text = ""
    @State private var parseError = false

    private var intelliSenseActive: Bool { settings.editorIntelliSense }

    /// File-path completion source, confined to the granted `~/.ssh`. Only handed to
    /// the editor when IntelliSense is active so it does no filesystem work otherwise.
    private var pathBrowser: PathCompletionBrowser? {
        guard intelliSenseActive else { return nil }
        return PathCompletionBrowser(
            homeDirectoryPath: SSHFileAccess.realHomeDirectory.path,
            baseDirectoryPath: store.sshDirectoryPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if parseError {
                Label("This must contain exactly one Host or Match block.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(8)
            }
            CodeEditor(
                text: $text,
                fontName: settings.editorFontName,
                fontSize: settings.editorFontSize,
                tabWidth: settings.editorTabWidth,
                showLineNumbers: settings.editorShowLineNumbers,
                softWrap: settings.editorSoftWrap,
                highlight: settings.editorSyntaxHighlighting,
                intelliSense: intelliSenseActive,
                showDocs: intelliSenseActive && settings.editorShowDocs,
                fileSystem: pathBrowser)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Apply") { apply() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { showRaw = false }
            }
        }
        .onAppear { text = store.rawText(for: blockID) }
    }

    private func apply() {
        // Capture the primary alias before reparsing so a rename here migrates any
        // tunnel presets that point at this host (raw-apply is a clean commit point).
        let oldAlias = store.block(id: blockID)?.patterns.first
        if store.replaceBlockFromRaw(id: blockID, rawText: text) {
            let newAlias = store.block(id: blockID)?.patterns.first
            if let oldAlias, let newAlias {
                tunnels.renameHostAlias(from: oldAlias, to: newAlias)
            }
            // Any running tunnel for this host needs to reconnect to pick up
            // whatever changed in the raw text (HostName, Port, ProxyJump, …) —
            // an already-open SSH link keeps using the address it dialled with.
            if let alias = newAlias ?? oldAlias {
                tunnels.restartRunningTunnels(for: alias)
            }
            parseError = false
            showRaw = false
        } else {
            parseError = true
        }
    }
}
