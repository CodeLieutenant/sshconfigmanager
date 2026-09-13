import Adwaita
import Foundation
import SSHConfigCore

/// The full ssh_config keyword catalog, searchable, grouped by category.
struct AddSettingCatalogView: View {
    var present: Set<String>
    var onAdd: (String) -> Void
    var onClose: () -> Void

    @State private var query = ""

    private var results: [KeywordInfoBox] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matches =
            trimmed.isEmpty
            ? KeywordRegistry.all
            : KeywordRegistry.search(trimmed, excluding: present)
        return KeywordInfoBox.boxes(matches.filter { !present.contains($0.key) })
    }

    /// A keyword ssh understands but the catalog does not list is still valid, so
    /// the user is never blocked by our list being incomplete.
    private var customKeyword: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, KeywordRegistry.info(for: trimmed) == nil else { return nil }
        return trimmed
    }

    var view: Body {
        VStack(spacing: 12) {
            SearchEntry()
                .text($query)
                .placeholderText("Search by name or description…")
            ScrollView {
                VStack(spacing: 18) {
                    if let customKeyword {
                        PreferencesGroup("Custom") {
                            ActionRow("Add custom keyword “\(customKeyword)”")
                                .useMarkup(false)
                                .subtitle("Not in the catalog — ssh may still accept it.")
                                .activated { onAdd(customKeyword) }
                                .prefix {
                                    Symbol(icon: .default(icon: .listAdd))
                                        .valign(.center)
                                }
                        }
                    }
                    ForEach(KeywordCategoryBox.all) { box in
                        let items = results.filter { $0.info.category == box.category }
                        if !items.isEmpty {
                            PreferencesGroup(box.category.rawValue.markupEscaped) {
                                ForEach(items) { item in
                                    ActionRow(item.info.canonical)
                                        .useMarkup(false)
                                        .subtitle(item.info.help)
                                        .subtitleLines(0)
                                        .activated { onAdd(item.info.canonical) }
                                        .suffix {
                                            Button("Add") { onAdd(item.info.canonical) }
                                                .valign(.center)
                                        }
                                }
                            }
                        }
                    }
                    if results.isEmpty && customKeyword == nil {
                        StatusPage(
                            "No matches",
                            icon: .default(icon: .systemSearch),
                            description: "Nothing in the catalog matches “\(query.markupEscaped)”."
                        )
                    }
                }
            }
            .vexpand()
            Button("Done") { onClose() }
                .suggested()
                .halign(.center)
        }
        .padding(18)
    }
}

struct KeywordInfoBox: Identifiable {
    let id: String
    let info: KeywordInfo

    static func boxes(_ infos: [KeywordInfo]) -> [KeywordInfoBox] {
        infos.map { .init(id: $0.key, info: $0) }
    }
}

/// What ssh will actually apply to this host, including anything an included file
/// or a wildcard block contributes.
struct EffectiveConfigView: View {
    var target: String
    var settings: [ResolvedSetting]
    var onClose: () -> Void

    var view: Body {
        VStack(spacing: 12) {
            Text("ssh \(target)")
                .monospace()
                .dimLabel()
                .halign(.center)
            ScrollView {
                if settings.isEmpty {
                    StatusPage(
                        "No settings apply",
                        icon: .default(icon: .dialogQuestion),
                        description: "No Host or Match block matches “\(target.markupEscaped)”."
                    )
                } else {
                    PreferencesGroup("") {
                        ForEach(settings) { setting in
                            ActionRow(setting.keyword)
                                .useMarkup(false)
                                .subtitle("\(setting.value)    — from \(setting.source)")
                                .subtitleSelectable()
                                .subtitleLines(0)
                        }
                    }
                }
            }
            .vexpand()
            HStack(spacing: 12) {
                Button("Copy") {
                    AdwaitaApp.copy(
                        settings.map { "\($0.keyword) \($0.value)" }.joined(separator: "\n")
                    )
                }
                Button("Done") { onClose() }
                    .suggested()
            }
            .halign(.center)
        }
        .padding(18)
    }
}

/// ProxyJump, as a chain the user can read. `JumpChain` in the core parses and
/// renders the value, so this screen never builds the string by hand.
struct JumpHostWizardView: View {
    var block: HostBlock
    var knownAliases: [String]
    var onApply: (String) -> Void
    var onCancel: () -> Void

    @State private var hops: [String] = []
    @State private var loaded = false
    @State private var disableJumping = false
    @State private var newHop = ""

    private var preview: String {
        if disableJumping { return "ssh \(block.sidebarKey)   # ProxyJump none" }
        let chain = hops.filter { !$0.isEmpty }
        guard !chain.isEmpty else {
            return "ssh \(block.sidebarKey)   # no jump — direct connection"
        }
        return "ssh -J \(chain.joined(separator: ",")) \(block.sidebarKey)"
    }

    var view: Body {
        ScrollView {
            VStack(spacing: 18) {
                PreferencesGroup("Connection Path") {
                    ActionRow(pathDescription)
                        .useMarkup(false)
                        .subtitle("First hop is the one closest to you.")
                        .titleLines(0)
                }
                PreferencesGroup("Jump Hops") {
                    if hops.isEmpty {
                        ActionRow("No hops")
                            .useMarkup(false)
                            .subtitle("The connection goes straight to \(block.sidebarKey).")
                    } else {
                        ForEach(ValueBox.boxes(hops)) { box in
                            ActionRow(box.value)
                                .useMarkup(false)
                                .subtitle(
                                    knownAliases.contains(box.value)
                                        ? "A host in your configuration"
                                        : "Not a known alias — it may be an external host"
                                )
                                .suffix {
                                    Button(icon: .default(icon: .listRemove)) {
                                        hops.removeAll { $0 == box.value }
                                    }
                                    .flat()
                                    .valign(.center)
                                }
                        }
                    }
                    EntryRow("Add a hop", text: $newHop)
                        .onSubmit {
                            let value = newHop.trimmingCharacters(in: .whitespaces)
                            guard !value.isEmpty else { return }
                            hops.append(value)
                            newHop = ""
                        }
                }
                .description("Enter user@host:port, or the alias of a host you already have.")
                PreferencesGroup("Options") {
                    SwitchRow("ProxyJump none", isOn: $disableJumping)
                        .subtitle("Explicitly disable jumping, overriding a wildcard block.")
                        .subtitleLines(0)
                }
                PreferencesGroup("What ssh Will Do") {
                    Text(preview)
                        .ellipsize()
                        .monospace()
                        .style("code-surface")
                        .halign(.start)
                }
                HStack(spacing: 12) {
                    Button("Cancel") { onCancel() }
                    Button("Apply") {
                        onApply(disableJumping ? "none" : hops.joined(separator: ","))
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
            let current = block.firstValue(for: "ProxyJump") ?? ""
            if current.lowercased() == "none" {
                disableJumping = true
            } else if !current.isEmpty {
                hops = JumpChain.parse(current).hops.map { $0.label }
            }
        }
    }

    private var pathDescription: String {
        let chain = disableJumping ? [] : hops.filter { !$0.isEmpty }
        return (["you"] + chain + [block.sidebarKey]).joined(separator: "  →  ")
    }
}

/// The block exactly as it sits in the file. The one editor that can express
/// anything ssh accepts, including what the structured form does not model.
struct RawBlockEditorView: View {
    var block: HostBlock
    var onApply: (String) -> Void
    var onCancel: () -> Void

    @State private var text = ""
    @State private var loaded = false

    var view: Body {
        VStack(spacing: 12) {
            ScrollView {
                TextEditor(text: $text)
                    .monospace()
                    .vexpand()
            }
            .vexpand()
            HStack(spacing: 12) {
                Text("One Host or Match block only.")
                    .caption()
                    .dimLabel()
                    .hexpand()
                    .halign(.start)
                Button("Cancel") { onCancel() }
                Button("Apply") { onApply(text) }
                    .suggested()
            }
        }
        .padding(18)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = ([block.header.rendered] + block.body.map { $0.rendered })
                .joined(separator: "\n")
        }
    }
}

/// Picks a key from ~/.ssh rather than making the user type a path.
struct AddIdentityKeyView: View {
    var keys: [SSHKeyEntry]
    var onPick: (String) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var manualPath = ""

    private var results: [SSHKeyEntry] {
        let trimmed = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return keys }
        return keys.filter { $0.name.lowercased().contains(trimmed) }
    }

    var view: Body {
        VStack(spacing: 12) {
            SearchEntry()
                .text($query)
                .placeholderText("Search keys in ~/.ssh")
            ScrollView {
                if results.isEmpty {
                    StatusPage(
                        "No keys found",
                        icon: .default(icon: .dialogPassword),
                        description: "No keys in your SSH folder match."
                    )
                } else {
                    PreferencesGroup("") {
                        ForEach(results) { key in
                            ActionRow(key.name)
                                .useMarkup(false)
                                .subtitle("\(key.typeLabel) · \(key.fingerprint)")
                                .activated { onPick(key.abbreviatedPath) }
                                .prefix {
                                    Symbol(icon: .default(icon: .dialogPassword))
                                        .style("area-tile")
                                        .style("tile-keys")
                                        .valign(.center)
                                }
                        }
                    }
                }
            }
            .vexpand()
            PreferencesGroup("Enter a path") {
                EntryRow("Path", text: $manualPath)
                    .onSubmit {
                        let value = manualPath.trimmingCharacters(in: .whitespaces)
                        guard !value.isEmpty else { return }
                        onPick(value)
                    }
            }
            Button("Close") { onClose() }
                .halign(.center)
        }
        .padding(18)
    }
}

/// Moves a host between the files an ssh_config includes.
struct MoveToFileView: View {
    var documents: [SSHConfigDocument]
    var current: URL
    var onMove: (URL) -> Void
    var onCancel: () -> Void

    var view: Body {
        VStack(spacing: 12) {
            Text(
                "Moves this entry — and the comments directly above it — into another file that "
                    + "your configuration already includes."
            )
            .dimLabel()
            .halign(.start)
            ScrollView {
                PreferencesGroup("Files") {
                    ForEach(DocumentBox.boxes(documents)) { box in
                        ActionRow(box.document.displayName)
                            .useMarkup(false)
                            .subtitle(
                                HomePath.abbreviating(
                                    box.document.sourceURL.path,
                                    home: SSHDirectory.home
                                )
                            )
                            .subtitleSelectable()
                            .activated { onMove(box.document.sourceURL) }
                            .suffix {
                                if box.document.sourceURL == current {
                                    Text("Current")
                                        .dimLabel()
                                        .valign(.center)
                                }
                            }
                    }
                }
            }
            .vexpand()
            Button("Cancel") { onCancel() }
                .halign(.center)
        }
        .padding(18)
    }
}

struct DocumentBox: Identifiable {
    let id: String
    let document: SSHConfigDocument

    static func boxes(_ documents: [SSHConfigDocument]) -> [DocumentBox] {
        documents.map { .init(id: $0.sourceURL.path, document: $0) }
    }
}
