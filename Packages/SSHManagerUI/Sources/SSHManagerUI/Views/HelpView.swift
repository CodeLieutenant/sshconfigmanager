import Adwaita

/// The help window. Same twelve topics as the macOS build, with the Linux
/// wording where the two platforms differ.
struct HelpView: View {
    var onClose: () -> Void

    @State private var selection = HelpTopic.all.first?.id ?? ""

    private var topic: HelpTopic {
        HelpTopic.all.first { $0.id == selection } ?? HelpTopic.all[0]
    }

    var view: Body {
        NavigationSplitView {
            list
        } content: {
            article
        }
    }

    @ViewBuilder private var list: Body {
        ScrollView {
            List(HelpTopic.all, id: \.id, selection: $selection) { topic in
                HStack(spacing: 12) {
                    Symbol(icon: topic.icon)
                        .valign(.center)
                    Text(topic.title)
                        .ellipsize()
                        .halign(.start)
                        .hexpand()
                }
                .padding(6)
            }
            .sidebarStyle()
        }
        .topToolbar {
            HeaderBar.empty()
                .headerBarTitle {
                    WindowTitle(subtitle: "", title: "Help")
                }
        }
        .navigationTitle("Help")
    }

    @ViewBuilder private var article: Body {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(topic.sections) { section in
                    PreferencesGroup(section.heading.markupEscaped) {
                        ForEach(section.paragraphs) { paragraph in
                            ActionRow(paragraph.text)
                                .useMarkup(false)
                                .titleLines(0)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 720)
        }
        .topToolbar {
            HeaderBar.end {
                Button("Close") { onClose() }
            }
            .headerBarTitle {
                WindowTitle(subtitle: "", title: topic.title)
            }
        }
        .navigationTitle(topic.title)
    }
}

struct HelpTopic: Identifiable {
    struct Paragraph: Identifiable {
        let id: String
        let text: String
    }

    struct Section: Identifiable {
        let id: String
        let heading: String
        let paragraphs: [Paragraph]

        init(_ heading: String, _ lines: [String]) {
            self.id = heading
            self.heading = heading
            self.paragraphs = lines.enumerated().map {
                Paragraph(id: "\(heading)-\($0.offset)", text: $0.element)
            }
        }
    }

    let id: String
    let title: String
    let icon: Icon
    let sections: [Section]

    init(_ title: String, icon: Icon, sections: [Section]) {
        self.id = title
        self.title = title
        self.icon = icon
        self.sections = sections
    }

    static let all: [HelpTopic] = [
        .init(
            "Getting Started",
            icon: .default(icon: .starNew),
            sections: [
                .init(
                    "Your SSH folder",
                    [
                        "The app reads and writes the files in ~/.ssh. Linux has no sandbox, so no grant step is needed — the app only checks that the folder exists and that you can read and write it.",
                        "If the folder is missing, the first screen offers to create it with the permissions ssh requires.",
                    ]
                ),
                .init(
                    "The sidebar",
                    [
                        "Library holds your keys, the agent and known hosts. Activity holds tunnels, issues and version history. Below them is every host in your configuration.",
                        "Included files are expanded the way ssh expands them, so a host defined in an included file appears here too.",
                    ]
                ),
            ]
        ),
        .init(
            "Hosts & Config",
            icon: .default(icon: .networkServer),
            sections: [
                .init(
                    "Add a host",
                    [
                        "Use the plus button in the sidebar, or the main menu. A new host is added to your main configuration file and selected so you can name it.",
                        "Templates fill in the settings a common setup needs.",
                    ]
                ),
                .init(
                    "Edits are lossless",
                    [
                        "Changing one setting rewrites only that line. Comments, blank lines, indentation and quoting everywhere else survive byte for byte.",
                        "Press Enter in a text field to apply it. The app writes the file once per change, not once per keystroke.",
                    ]
                ),
                .init(
                    "Raw editing",
                    ["Edit as Raw Text shows the block exactly as it appears in the file."]
                ),
            ]
        ),
        .init(
            "SSH Keys",
            icon: .default(icon: .dialogPassword),
            sections: [
                .init(
                    "Your keys",
                    [
                        "The Keys screen lists every key in ~/.ssh, with its fingerprint, type, comment and randomart.",
                        "A key held only by an agent — 1Password or a hardware token, for example — has no file on disk and appears on the Agent screen instead.",
                    ]
                ),
                .init(
                    "Generate a key",
                    [
                        "Ed25519 is the recommended default. RSA is deliberately not offered.",
                        "The private key is created with mode 0600 before anything is written into it.",
                    ]
                ),
            ]
        ),
        .init(
            "SSH Agent",
            icon: .default(icon: .avatarDefault),
            sections: [
                .init(
                    "What it shows",
                    [
                        "The agent screen talks to the agent named by SSH_AUTH_SOCK and lists the identities it holds, matched against the keys on disk.",
                        "Unload removes one identity from the running agent. Your key files are not touched.",
                    ]
                )
            ]
        ),
        .init(
            "Known Hosts",
            icon: .default(icon: .securityHigh),
            sections: [
                .init(
                    "Trusted keys",
                    [
                        "Every host key ssh has accepted is listed here, grouped by host.",
                        "Hashed entries cannot be read back to a host name. The app can still try to match them against the names in your configuration.",
                    ]
                ),
                .init(
                    "Markers",
                    [
                        "A key can be marked as a certificate authority or as revoked. Revoking a key tells ssh to refuse it."
                    ]
                ),
            ]
        ),
        .init(
            "Tunnels",
            icon: .default(icon: .networkTransmitReceive),
            sections: [
                .init(
                    "Forward types",
                    [
                        "A local forward listens on this computer and sends each connection to a host the server can reach.",
                        "A remote forward asks the server to listen and send connections back here.",
                        "A dynamic forward opens a SOCKS proxy, and each application picks its own destination.",
                    ]
                ),
                .init(
                    "On Linux today",
                    [
                        "The in-app tunnel engine is not available on Linux yet. The app builds the matching ssh command so you can run it, and lists the forwards your configuration already declares."
                    ]
                ),
            ]
        ),
        .init(
            "Version History",
            icon: .default(icon: .documentOpenRecent),
            sections: [
                .init(
                    "Every write is kept",
                    [
                        "Before the app writes a configuration file, it copies the old one under ~/.local/share/sshmanager/history.",
                        "Restoring a version copies the current file first, so a restore can itself be undone.",
                    ]
                )
            ]
        ),
        .init(
            "Issues & Audit",
            icon: .default(icon: .dialogWarning),
            sections: [
                .init(
                    "What is checked",
                    [
                        "Duplicate aliases, a catch-all Host * that is not last, deprecated options, disabled host key checking, weak ciphers, and keys with weak algorithms or loose permissions.",
                        "Choose which checks run in Preferences, under Audit.",
                    ]
                )
            ]
        ),
        .init(
            "Background & Notifications",
            icon: .default(icon: .preferencesSystemNotifications),
            sections: [
                .init(
                    "No tray icon",
                    [
                        "GNOME has no menu-bar extras and no supported tray. The app instead keeps running as a background application and reports through desktop notifications.",
                        "Turn this on in Preferences, under General.",
                    ]
                )
            ]
        ),
        .init(
            "Privacy & Security",
            icon: .default(icon: .changesPrevent),
            sections: [
                .init(
                    "What leaves this computer",
                    [
                        "Nothing, unless you send a bug report or turn on crash reports. Your configuration, keys, passphrases and known hosts are never sent."
                    ]
                )
            ]
        ),
        .init(
            "Keyboard Shortcuts",
            icon: .default(icon: .inputKeyboard),
            sections: [
                .init(
                    "General",
                    [
                        "Ctrl+N — new host",
                        "Ctrl+K — go to a host or an area",
                        "Ctrl+S — save now",
                        "Ctrl+R — reload from disk",
                        "Ctrl+comma — preferences",
                        "Ctrl+W — close the window",
                        "Ctrl+Q — quit",
                    ]
                )
            ]
        ),
    ]
}
