//
//  SettingsPanes.swift
//  sshconfigmanager
//
//  The individual preference panes shown by `SettingsView`'s `TabView`. Each is a
//  grouped `Form`. Every control binds straight to `AppSettings.shared` (which
//  write-throughs to SQLite), except "Launch at login" which mirrors the OS via
//  `LoginItemService` since the system owns that state.
//

import AppKit
import SSHConfigCore
import SSHConfigServices
import SwiftUI

// MARK: - General

struct GeneralSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var launchAtLogin = LoginItemService.isEnabled

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section("Saving") {
                Toggle("Automatically save changes", isOn: $settings.autosaveEnabled)
                Text(
                    """
                    When on, edits to your SSH config are written to disk a moment after you \
                    make them. When off, changes are kept until you choose File ▸ Save (⌘S), \
                    and you’ll be asked to save on quit.
                    """
                )
                .settingsCaption()
            }

            Section("Startup") {
                Toggle(isOn: $launchAtLogin) { Text("Launch at login") }
                    .onChange(of: launchAtLogin) { _, newValue in
                        launchAtLogin = LoginItemService.setEnabled(newValue)
                    }
                Text(
                    "Open SSH Config Manager automatically when you log in. You can also manage this in System Settings ▸ General ▸ Login Items."
                )
                .settingsCaption()
            }

            Section("Editing") {
                Toggle("Confirm before deleting a host", isOn: $settings.confirmBeforeDelete)
                Text("When off, deleting a host removes it immediately without asking. Undo (⌘Z) still brings it back.")
                    .settingsCaption()
            }

            Section("New Host Defaults") {
                TextField("Default user", text: $settings.defaultHostUser, prompt: Text("none"))
                LabeledContent("Default port") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.defaultHostPort, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                        Stepper("", value: $settings.defaultHostPort, in: 0...65535)
                            .labelsHidden()
                    }
                }
                Text(
                    "Prefilled into every new host you create. Leave the user blank and the port at 0 to add nothing (ssh then uses your login name and port 22)."
                )
                .settingsCaption()
            }

            Section("Menu Bar") {
                Toggle(isOn: $settings.showMenuBarExtra) { Text("Show icon in the menu bar") }
                Text("A quick-access menu with your hosts, available even when the main window is closed.")
                    .settingsCaption()
                Toggle(isOn: $settings.showTunnelMenuBar) { Text("Show active tunnels in the menu bar") }
                Text(
                    "A status item appears while tunnels are running, listing each one with its live status and a jump to its logs."
                )
                .settingsCaption()
            }

            Section("Host Key Monitoring") {
                Toggle(isOn: $settings.hostKeyMonitorEnabled) { Text("Check host keys in the background") }
                Text(
                    "Periodically re-checks each known host's live key against what's stored, so a changed or new server key is caught without connecting. Findings appear on the Known Hosts screen and in the menu bar."
                )
                .settingsCaption()
                Picker("Check every", selection: $settings.hostKeyCheckIntervalMinutes) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("Hour").tag(60)
                    Text("6 hours").tag(360)
                    Text("Day").tag(1440)
                }
                .disabled(!settings.hostKeyMonitorEnabled)
                Toggle("Notify me when a host key changes", isOn: $settings.hostKeyNotificationsEnabled)
                    .disabled(!settings.hostKeyMonitorEnabled)
            }

            Section("Live File Watching") {
                Toggle(isOn: $settings.liveFileWatchEnabled) {
                    Text("Watch config and known_hosts for external changes")
                }
                Text(
                    "Detects edits made outside SSH Config Manager the moment they happen — a manual config edit is recorded in Version History immediately, and known_hosts changes (like ssh trusting a new server) show up on the Known Hosts screen. Without this, changes are only picked up when the app regains focus."
                )
                .settingsCaption()
                Toggle("Notify me about external changes", isOn: $settings.liveFileWatchNotificationsEnabled)
                    .disabled(!settings.liveFileWatchEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItemService.isEnabled }
    }
}

// MARK: - Appearance

struct AppearanceSettingsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Accent", selection: $settings.accentChoice) {
                    ForEach(AccentChoice.allCases) { Text($0.label).tag($0) }
                }
                Text(
                    "“System” follows your macOS accent color — the recommended default. Pick a color to pin the app to one hue regardless of your system setting. Status and diff colors never change."
                )
                .settingsCaption()

                Picker("Density", selection: $settings.uiDensity) {
                    ForEach(UIDensity.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Compact tightens controls so more fits on screen.")
                    .settingsCaption()
            }

            Section("Code Font") {
                Picker("Font", selection: $settings.editorFontName) {
                    Text("System Monospaced").tag("")
                    ForEach(settings.availableEditorFonts, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    HStack(spacing: 6) {
                        Text("\(Int(settings.editorFontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("", value: $settings.editorFontSize, in: 8...32, step: 1)
                            .labelsHidden()
                    }
                }
                Text("Used by the raw config editor and the tunnel console.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Editor

struct EditorSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var previewText = """
        # Example host
        Host example
            HostName example.com
            User git
            Port 22
            IdentityFile ~/.ssh/id_ed25519
        """

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section("Raw Config Editor") {
                Toggle("Open hosts in the raw editor by default", isOn: $settings.defaultToRawEditor)
                    .help(
                        "Show a host’s raw ssh_config text instead of the structured form. "
                            + "The form is still one click away via “Edit as Raw Text”.")
                Toggle("Show line numbers", isOn: $settings.editorShowLineNumbers)
                Toggle("Soft wrap long lines", isOn: $settings.editorSoftWrap)
                Toggle("Syntax highlighting", isOn: $settings.editorSyntaxHighlighting)
                Toggle("Code completion (IntelliSense)", isOn: $settings.editorIntelliSense)
                Toggle("Show documentation panel", isOn: $settings.editorShowDocs)
                    .help(
                        "Show a detached panel beside the suggestions with help for the "
                            + "highlighted keyword or value."
                    )
                    .disabled(!settings.editorIntelliSense)
                LabeledContent("Tab width") {
                    HStack(spacing: 6) {
                        Text("\(settings.editorTabWidth)").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("", value: $settings.editorTabWidth, in: 1...8)
                            .labelsHidden()
                    }
                }
                Text(
                    "These apply to the raw-text editor opened from a host’s “Edit Raw” view. Code completion suggests ssh_config keywords and their values as you type — ↩/⇥ to accept, ⎋ to dismiss."
                )
                .settingsCaption()
            }

            Section("Preview") {
                CodeEditor(
                    text: $previewText,
                    isEditable: true,
                    fontName: settings.editorFontName,
                    fontSize: settings.editorFontSize,
                    tabWidth: settings.editorTabWidth,
                    showLineNumbers: settings.editorShowLineNumbers,
                    softWrap: settings.editorSoftWrap,
                    highlight: settings.editorSyntaxHighlighting,
                    intelliSense: settings.editorIntelliSense
                )
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.cardBorder))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keys & Tunnels

struct KeysTunnelsSettingsPane: View {
    @State private var settings = AppSettings.shared

    /// Built-in terminals that are actually installed, so the picker only offers ones
    /// the user can pick. Terminal is always present on macOS.
    private var installedTerminals: [TerminalPreset] {
        TerminalPreset.builtIns.filter { preset in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: preset.bundleID) != nil
        }
    }

    /// A live preview of what Connect would run for a sample host.
    private var commandPreview: String {
        let sample = SSHCommandBuilder.aliasCommand(
            for: HostBlock(
                kind: .host,
                header: Directive(keyword: "Host", value: "example"),
                sourceURL: URL(fileURLWithPath: "/dev/null")))
        return TerminalLauncher.applyTemplate(settings.terminalCommandTemplate, to: sample.shellString)
    }

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section("Connecting") {
                Picker(selection: $settings.preferredTerminalID) {
                    ForEach(installedTerminals) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                } label: {
                    Text("Open Connect in")
                }
                TextField(
                    "Command template", text: $settings.terminalCommandTemplate,
                    prompt: Text("{ssh}")
                )
                .font(.system(.body, design: .monospaced))
                Text(
                    "Optional wrapper around the ssh command. Use `{ssh}` where the command goes, e.g. `tmux new-window '{ssh}'`. Leave blank to run it as-is."
                )
                .settingsCaption()
                LabeledContent("Preview") {
                    Text(commandPreview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("SSH Keys") {
                Picker("Default algorithm for new keys", selection: $settings.defaultKeyAlgorithm) {
                    ForEach(KeyAlgorithm.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Preselected in the Generate Key sheet. Ed25519 is the recommended modern default.")
                    .settingsCaption()
            }

            Section("Tunnels") {
                Toggle(isOn: $settings.tunnelNotificationsEnabled) {
                    Text("Notify when a tunnel fails or recovers")
                }
                Toggle(isOn: $settings.restoreTunnelsOnLaunch) { Text("Re-arm autostart tunnels on launch") }
                LabeledContent("Max reconnect backoff") {
                    HStack(spacing: 6) {
                        Text("\(settings.tunnelMaxBackoffSeconds) s").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("", value: $settings.tunnelMaxBackoffSeconds, in: 5...600, step: 5)
                            .labelsHidden()
                    }
                }
                Text(
                    """
                    Tunnels run inside the app over SwiftNIO SSH — no Terminal. When a connection \
                    drops the supervisor retries with exponential backoff, capped at this value. \
                    Host keys are checked against known_hosts (trust-on-first-use for new hosts).
                    """
                )
                .settingsCaption()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

struct HistorySettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var store = ConfigStore.shared
    @State private var confirmClearHistory = false

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section("Version History") {
                Toggle("Keep a version history of config changes", isOn: $settings.configHistoryEnabled)
                Text(
                    """
                    Every change to your SSH config is recorded as a version you can diff and \
                    restore from the Version History screen. Restoring is non-destructive — it \
                    moves you back in time without deleting anything, and editing then starts a \
                    new branch.
                    """
                )
                .settingsCaption()

                LabeledContent("Maximum versions kept") {
                    TextField("", value: $settings.maxConfigVersions, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                }
                .disabled(!settings.configHistoryEnabled)
                Text(
                    "Once this limit is reached, the oldest versions are removed first. Snapshots are tiny and de-duplicated, so a large number is fine."
                )
                .settingsCaption()

                LabeledContent("Currently stored") {
                    Text("\(store.history.versions.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Clear History…", role: .destructive) { confirmClearHistory = true }
                    .disabled(store.history.versions.isEmpty)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear the entire version history?", isPresented: $confirmClearHistory) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every recorded version. Your current config files on disk are not changed.")
        }
    }
}

// MARK: - Audit

struct AuditSettingsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section("Key Audit") {
                Toggle("Weak or outdated key algorithms", isOn: $settings.auditWeakKeys)
                Toggle("Loose file permissions", isOn: $settings.auditKeyPermissions)
                Toggle("Private keys without a passphrase", isOn: $settings.auditMissingPassphrase)
                Toggle("Keys not used by any host", isOn: $settings.auditOrphanedKeys)
                Toggle("Weak cryptography on the server", isOn: $settings.auditServerAlgorithms)
                    .help(
                        "Flags a server whose host key or negotiated algorithms are weak — a short RSA host key, a DSA key, a broken cipher or MAC."
                    )
                Toggle("Refuse to connect to a weak server", isOn: $settings.strictServerAlgorithms)
                    .disabled(!settings.auditServerAlgorithms)
                    .help(
                        "Stops a tunnel instead of only warning. Off by default: a weak host key is usually someone else's server you cannot fix."
                    )
                Text(
                    """
                    Which key-health checks appear in Issues. Turn one off to stop reporting \
                    that kind of finding — for example, hide the warning about private keys \
                    stored without a passphrase. This only changes what's shown; your keys \
                    aren't touched.
                    """
                )
                .settingsCaption()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared styling

extension View {
    /// The recurring caption style under a control: small, secondary explanatory text.
    fileprivate func settingsCaption() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
