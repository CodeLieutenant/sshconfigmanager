import Adwaita
import Foundation
import SSHConfigCore
import SSHConfigServices

/// Generate a key. Every field the macOS sheet has, including the host to wire
/// the new key into.
struct GenerateKeyView: View {
    var hosts: [String]
    var existingNames: Set<String>
    var defaultAlgorithm: String
    var onGenerate: (KeyAlgorithm, String, String, String?, String?) -> Void
    var onCancel: () -> Void

    @State private var algorithm = ""
    @State private var name = ""
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var host = "None"
    @State private var loaded = false

    private var chosen: KeyAlgorithm {
        KeyAlgorithm.allCases.first { $0.displayName == algorithm } ?? .ed25519
    }

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("/") { return "Use a single file name with no “/”." }
        if existingNames.contains(trimmed) { return "“\(trimmed)” already exists — pick another name." }
        return nil
    }

    private var passphraseProblem: String? {
        guard passphrase != confirmation else { return nil }
        return "Passphrases do not match."
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && nameProblem == nil && passphraseProblem == nil
    }

    var view: Body {
        ScrollView {
            VStack(spacing: 18) {
                PreferencesGroup("New Key") {
                    ComboRow(
                        "Algorithm",
                        selection: .init {
                            algorithm
                        } set: { newValue in
                            algorithm = newValue
                            let suggested = chosen.defaultFileName
                            if name.isEmpty
                                || KeyAlgorithm.allCases.contains(where: {
                                    $0.defaultFileName == name
                                })
                            {
                                name = suggested
                            }
                        },
                        values: KeyAlgorithm.allCases.map { $0.displayName },
                        id: \.self,
                        description: \.self
                    )
                    EntryRow("File name", text: $name)
                    EntryRow("Comment", text: $comment)
                }
                .description("RSA is not offered. Ed25519 is smaller, faster and safer.")
                if let nameProblem {
                    Text(nameProblem)
                        .style("warning")
                        .halign(.start)
                }
                PreferencesGroup("Passphrase") {
                    PasswordEntryRow("Passphrase", text: $passphrase)
                    PasswordEntryRow("Confirm", text: $confirmation)
                }
                .description(
                    passphraseProblem
                        ?? "Leave empty for no passphrase — not recommended."
                )
                PreferencesGroup("Use for a host (optional)") {
                    ComboRow(
                        "Add as IdentityFile to",
                        selection: .init {
                            host
                        } set: {
                            host = $0
                        },
                        values: ["None"] + hosts,
                        id: \.self,
                        description: \.self
                    )
                }
                HStack(spacing: 12) {
                    Button("Cancel") { onCancel() }
                    Button("Generate") {
                        guard isValid else { return }
                        onGenerate(
                            chosen,
                            name.trimmingCharacters(in: .whitespaces),
                            comment,
                            passphrase.isEmpty ? nil : passphrase,
                            host == "None" ? nil : host
                        )
                    }
                    .suggested()
                }
                .halign(.center)
            }
            .padding(18)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            algorithm = defaultAlgorithm
            name = chosen.defaultFileName
            let user = ProcessInfo.processInfo.environment["USER"] ?? "user"
            comment = "\(user)@\(ProcessInfo.processInfo.hostName)"
        }
    }
}

/// Deploy a public key to a host's authorized_keys. The command is shown in full
/// because it is the thing the user runs.
struct DeployKeyView: View {
    var key: SSHKeyEntry
    var hosts: [HostBlock]
    var publicKeyLine: String
    var onStatus: (String) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var selectedAlias = ""

    private var results: [HostBlock] {
        let trimmed = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return hosts }
        return hosts.filter { $0.title.lowercased().contains(trimmed) }
    }

    private var command: String {
        guard let block = hosts.first(where: { $0.sidebarKey == selectedAlias }) else {
            return "Select a host to preview the deploy command."
        }
        return SSHCommandBuilder.deployCommand(for: block, publicKeyLine: publicKeyLine)?
            .shellString ?? "This host has no connection target."
    }

    var view: Body {
        VStack(spacing: 12) {
            Text("Append \(key.name).pub to a host's ~/.ssh/authorized_keys.")
                .dimLabel()
                .halign(.start)
            if key.key.privateKeyURL == nil {
                Banner(
                    "This key has no private half on disk — you will not be able to log in as this identity after deploying it.",
                    visible: true
                )
            }
            SearchEntry()
                .text($query)
                .placeholderText("Filter hosts")
            ScrollView {
                if results.isEmpty {
                    StatusPage(
                        "No hosts to deploy to",
                        icon: .default(icon: .networkServer),
                        description: "Add a host in the config first, then deploy this key to it."
                    )
                } else {
                    PreferencesGroup("") {
                        ForEach(results) { block in
                            ActionRow(block.title)
                                .useMarkup(false)
                                .subtitle(block.connectionTarget?.host ?? "")
                                .activated { selectedAlias = block.sidebarKey }
                                .suffix {
                                    if selectedAlias == block.sidebarKey {
                                        Symbol(icon: .default(icon: .emblemOk))
                                            .style("success")
                                            .valign(.center)
                                    }
                                }
                        }
                    }
                }
            }
            .vexpand()
            PreferencesGroup("Command") {
                Text(command)
                    .ellipsize()
                    .monospace()
                    .style("code-surface")
                    .halign(.start)
            }
            HStack(spacing: 12) {
                Button("Cancel") { onClose() }
                Button("Copy Command") {
                    AdwaitaApp.copy(command)
                    onStatus("Copied the deploy command")
                }
                Button("Open in Terminal") {
                    onStatus("Opening a terminal is not wired up yet")
                }
                .suggested()
            }
            .halign(.center)
        }
        .padding(18)
    }
}

/// The command that keeps a key loaded across restarts.
struct AddToAgentView: View {
    var key: SSHKeyEntry
    var onStatus: (String) -> Void
    var onClose: () -> Void

    private var command: String {
        "ssh-add \(SSHCommandBuilder.shellQuote(key.abbreviatedPath))"
    }

    var view: Body {
        VStack(spacing: 18) {
            StatusPage(
                "Keep “\(key.name)” loaded",
                icon: .default(icon: .avatarDefault),
                description:
                    "Linux has no Keychain. A passphrase is held by the running agent, and by your "
                    + "desktop keyring if it is the agent. Add it once per session, or let your "
                    + "session start an agent that keeps it."
            )
            .compact()
            PreferencesGroup("Command") {
                Text(command)
                    .ellipsize()
                    .monospace()
                    .style("code-surface")
                    .halign(.start)
            }
            HStack(spacing: 12) {
                Button("Copy") {
                    AdwaitaApp.copy(command)
                    onStatus("Copied the ssh-add command")
                }
                Button("Done") { onClose() }
                    .suggested()
            }
            .halign(.center)
        }
        .padding(18)
    }
}
