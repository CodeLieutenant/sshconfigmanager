import Adwaita

/// The settings dialog, page by page.
///
/// The macOS build uses an eight-tab window. GNOME's `AdwPreferencesDialog` is
/// the same idea with a page switcher, so the tabs map across one to one — except
/// the two macOS menu-bar tabs, which GNOME has no equivalent for. Those controls
/// move to a "Background" group, matching §6 of the design paper.
extension PreferencesDialog {
    func sshManagerPages(
        settings: Binding<AppSettings>,
        storedVersions: Int,
        onClearHistory: @escaping () -> Void,
        onReportBug: @escaping () -> Void,
        onOpenLogs: @escaping () -> Void
    ) -> Self {
        let bind = { (path: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> in
            .init {
                settings.wrappedValue[keyPath: path]
            } set: { newValue in
                settings.wrappedValue[keyPath: path] = newValue
                settings.wrappedValue.save()
            }
        }
        let bindInt = { (path: WritableKeyPath<AppSettings, Int>) -> Binding<Int> in
            .init {
                settings.wrappedValue[keyPath: path]
            } set: { newValue in
                settings.wrappedValue[keyPath: path] = newValue
                settings.wrappedValue.save()
            }
        }
        let bindText = { (path: WritableKeyPath<AppSettings, String>) -> Binding<String> in
            .init {
                settings.wrappedValue[keyPath: path]
            } set: { newValue in
                settings.wrappedValue[keyPath: path] = newValue
                settings.wrappedValue.save()
            }
        }

        return
            self
            .preferencesPage("General", icon: .default(icon: .emblemSystem)) { page in
                page
                    .group("Saving") {
                        SwitchRow("Automatically save changes", isOn: bind(\.automaticallySave))
                            .subtitle(
                                "Edits are written to ~/.ssh/config a moment after you make them. "
                                    + "When off, changes wait until you save."
                            )
                            .subtitleLines(0)
                    }
                    .group("Startup") {
                        SwitchRow("Start at login", isOn: bind(\.launchAtLogin))
                            .subtitle(
                                "Adds a user autostart entry under ~/.config/autostart."
                            )
                            .subtitleLines(0)
                    }
                    .group("Editing") {
                        SwitchRow(
                            "Confirm before deleting a host",
                            isOn: bind(\.confirmBeforeDeletingHost)
                        )
                        .subtitle("When off, a delete happens at once. Undo still brings it back.")
                        .subtitleLines(0)
                    }
                    .group(
                        "New Host Defaults",
                        description:
                            "Prefilled into every new host. Leave the user blank and the port at 0 "
                            + "to add nothing, so ssh uses your login name and port 22."
                    ) {
                        EntryRow("Default user", text: bindText(\.defaultUser))
                        SpinRow("Default port", value: bindInt(\.defaultPort), min: 0, max: 65535)
                    }
                    .group(
                        "Background",
                        description:
                            "GNOME has no menu-bar extras. The app keeps tunnels running as a "
                            + "background application and reports through desktop notifications."
                    ) {
                        SwitchRow("Keep running in the background", isOn: bind(\.runInBackground))
                        SwitchRow(
                            "Notify when a tunnel fails or recovers",
                            isOn: bind(\.showTunnelNotifications)
                        )
                    }
                    .group("Host Key Monitoring") {
                        SwitchRow(
                            "Check host keys in the background",
                            isOn: bind(\.monitorHostKeys)
                        )
                        .subtitle(
                            "Re-checks each known host's live key against what is stored, so a "
                                + "changed key is caught before you connect."
                        )
                        .subtitleLines(0)
                        ComboRow(
                            "Check every",
                            selection: bindText(\.hostKeyCheckInterval),
                            values: AppSettings.hostKeyIntervals,
                            id: \.self,
                            description: \.self
                        )
                        SwitchRow(
                            "Notify me when a host key changes",
                            isOn: bind(\.notifyOnHostKeyChange)
                        )
                    }
                    .group("Live File Watching") {
                        SwitchRow(
                            "Watch config and known_hosts for external changes",
                            isOn: bind(\.watchFiles)
                        )
                        .subtitle(
                            "Picks up edits made outside the app the moment they happen. Without "
                                + "this, changes appear when the window regains focus."
                        )
                        .subtitleLines(0)
                        SwitchRow(
                            "Notify me about external changes",
                            isOn: bind(\.notifyOnExternalChange)
                        )
                    }
            }
            .preferencesPage("Appearance", icon: .default(icon: .appletsScreenshooter)) { page in
                page
                    .group(
                        "Theme",
                        description:
                            "“System” follows your GNOME setting, which is the recommended default. "
                            + "Status and diff colours never change."
                    ) {
                        ComboRow(
                            "Appearance",
                            selection: bindText(\.theme),
                            values: AppSettings.themes,
                            id: \.self,
                            description: \.self
                        )
                        ComboRow(
                            "Accent",
                            selection: bindText(\.accent),
                            values: AppSettings.accents,
                            id: \.self,
                            description: \.self
                        )
                        ComboRow(
                            "Density",
                            selection: bindText(\.density),
                            values: AppSettings.densities,
                            id: \.self,
                            description: \.self
                        )
                    }
                    .group(
                        "Code Font",
                        description: "Used by the raw config editor and the tunnel console."
                    ) {
                        ComboRow(
                            "Font",
                            selection: bindText(\.codeFont),
                            values: AppSettings.codeFonts,
                            id: \.self,
                            description: \.self
                        )
                        SpinRow("Size", value: bindInt(\.codeFontSize), min: 8, max: 32)
                    }
            }
            .preferencesPage("Editor", icon: .default(icon: .accessoriesTextEditor)) { page in
                page
                    .group(
                        "Raw Config Editor",
                        description:
                            "These apply to the raw-text editor opened from a host. Code completion "
                            + "suggests ssh_config keywords as you type."
                    ) {
                        SwitchRow(
                            "Open hosts in the raw editor by default",
                            isOn: bind(\.openRawEditorByDefault)
                        )
                        SwitchRow("Show line numbers", isOn: bind(\.showLineNumbers))
                        SwitchRow("Soft wrap long lines", isOn: bind(\.softWrap))
                        SwitchRow("Syntax highlighting", isOn: bind(\.syntaxHighlighting))
                        SwitchRow("Code completion", isOn: bind(\.codeCompletion))
                        SwitchRow("Show documentation panel", isOn: bind(\.showDocumentationPanel))
                        SpinRow("Tab width", value: bindInt(\.tabWidth), min: 1, max: 8)
                    }
            }
            .preferencesPage("Keys & Tunnels", icon: .default(icon: .dialogPassword)) { page in
                page
                    .group(
                        "Connecting",
                        description:
                            "The terminal the Connect action opens. Use {ssh} in the template where "
                            + "the command goes, for example: tmux new-window '{ssh}'."
                    ) {
                        ComboRow(
                            "Open Connect in",
                            selection: bindText(\.terminalCommand),
                            values: AppSettings.terminals,
                            id: \.self,
                            description: \.self
                        )
                        EntryRow("Command template", text: bindText(\.commandTemplate))
                    }
                    .group(
                        "SSH Keys",
                        description:
                            "Preselected in the Generate Key dialog. Ed25519 is the recommended "
                            + "modern default. RSA is not offered."
                    ) {
                        ComboRow(
                            "Default algorithm for new keys",
                            selection: bindText(\.defaultKeyAlgorithm),
                            values: AppSettings.keyAlgorithms,
                            id: \.self,
                            description: \.self
                        )
                    }
                    .group(
                        "Tunnels",
                        description:
                            "When a connection drops, the supervisor retries with exponential "
                            + "backoff, capped at this value."
                    ) {
                        SwitchRow(
                            "Notify when a tunnel fails or recovers",
                            isOn: bind(\.notifyOnTunnelChange)
                        )
                        SwitchRow(
                            "Re-arm autostart tunnels on launch",
                            isOn: bind(\.rearmAutostartTunnels)
                        )
                        SpinRow(
                            "Max reconnect backoff (seconds)",
                            value: bindInt(\.maxReconnectBackoff),
                            min: 5,
                            max: 600
                        )
                    }
            }
            .preferencesPage("History", icon: .default(icon: .documentOpenRecent)) { page in
                page
                    .group(
                        "Version History",
                        description:
                            "Every change is recorded as a version you can compare and restore. "
                            + "Restoring is not destructive — the older versions stay."
                    ) {
                        SwitchRow(
                            "Keep a version history of config changes",
                            isOn: bind(\.keepVersionHistory)
                        )
                        SpinRow(
                            "Maximum versions kept",
                            value: bindInt(\.maximumVersionsKept),
                            min: 1,
                            max: 100_000
                        )
                        ActionRow("Currently stored")
                            .subtitle("\(storedVersions) versions")
                        ActionRow("Clear History…")
                            .subtitle("Your current files on disk are not changed.")
                            .activated(onClearHistory)
                            .style("error")
                    }
            }
            .preferencesPage("Audit", icon: .default(icon: .securityHigh)) { page in
                page
                    .group(
                        "Key Audit",
                        description:
                            "Which checks appear on the Issues screen. Turning one off only stops "
                            + "the report — your keys are not touched."
                    ) {
                        SwitchRow(
                            "Weak or outdated key algorithms",
                            isOn: bind(\.auditWeakAlgorithms)
                        )
                        SwitchRow("Loose file permissions", isOn: bind(\.auditLoosePermissions))
                        SwitchRow(
                            "Private keys without a passphrase",
                            isOn: bind(\.auditMissingPassphrase)
                        )
                        SwitchRow("Keys not used by any host", isOn: bind(\.auditUnusedKeys))
                        SwitchRow(
                            "Weak cryptography on the server",
                            isOn: bind(\.auditWeakServerCrypto)
                        )
                        .subtitle(
                            "Flags a server whose host key or negotiated algorithms are weak."
                        )
                        .subtitleLines(0)
                        SwitchRow(
                            "Refuse to connect to a weak server",
                            isOn: bind(\.refuseWeakServer)
                        )
                        .subtitle(
                            "Stops a tunnel instead of only warning. Off by default: a weak host "
                                + "key is usually someone else's server you cannot fix."
                        )
                        .subtitleLines(0)
                    }
            }
            .preferencesPage("Privacy", icon: .default(icon: .changesPrevent)) { page in
                page
                    .group(
                        "Crash Reports",
                        description:
                            "Reports include diagnostic data and your app and system version. They "
                            + "never include your configuration, keys, passwords or known hosts."
                    ) {
                        SwitchRow(
                            "Share crash reports automatically",
                            isOn: bind(\.shareCrashReports)
                        )
                    }
                    .group("Support") {
                        ActionRow("Open Logs")
                            .subtitle("See what the app recorded during this run.")
                            .activated(onOpenLogs)
                        ActionRow("Report a Bug…")
                            .subtitle("Open the issue tracker in your browser.")
                            .activated(onReportBug)
                    }
            }
    }
}
