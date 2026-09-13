import Adwaita
import Foundation
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigServices

/// One algorithm's keys, for the grouped list.
struct KeyTypeSection {
    let type: String
    let keys: [SSHKeyEntry]

    /// Modern types first, then whatever else the folder holds. Matching the
    /// macOS order, so a user who moves between the two reads the same list.
    private static let order = ["Ed25519", "ECDSA", "RSA", "Security Key", "DSA"]

    static func build(_ keys: [SSHKeyEntry]) -> [KeyTypeSection] {
        Dictionary(grouping: keys, by: \.typeLabel)
            .map { KeyTypeSection(type: $0.key, keys: $0.value.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.type) ?? order.count
                let right = order.firstIndex(of: rhs.type) ?? order.count
                return left != right ? left < right : lhs.type < rhs.type
            }
    }
}

/// A row in the key list: either a type header or a key.
enum KeyRow: Identifiable {
    case header(String)
    case key(SSHKeyEntry)

    var id: String {
        switch self {
        case .header(let type): "type:\(type)"
        case .key(let key): key.id.uuidString
        }
    }

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }
}

/// L02 · SSH Keys. A key list beside the selected key's detail.
struct KeysView: View {
    @Binding var store: ConfigStore
    var defaultAlgorithm: String
    var onStatus: (String) -> Void

    @State private var selection = ""
    @State private var generating = false
    @State private var deploying = false
    @State private var confirmingDelete = false

    private var selected: SSHKeyEntry? {
        store.keys.first { $0.id.uuidString == selection } ?? store.keys.first
    }

    var view: Body {
        NavigationSplitView {
            list
        } content: {
            detail
                .navigationTitle(detailTitle)
        }
        .dialog(visible: $generating, title: "Generate SSH Key", width: 560, height: 680) {
            GenerateKeyView(
                hosts: store.hosts.map { $0.sidebarKey },
                existingNames: Set(store.keys.map { $0.name }),
                defaultAlgorithm: defaultAlgorithm,
                onGenerate: { algorithm, name, comment, passphrase, host in
                    generate(algorithm, name: name, comment: comment, passphrase: passphrase, host: host)
                },
                onCancel: { generating = false }
            )
        }
        .dialog(visible: $deploying, title: "Deploy Public Key", width: 620, height: 620) {
            if let key = selected {
                DeployKeyView(
                    key: key,
                    hosts: store.hosts,
                    publicKeyLine: publicKeyLine(key),
                    onStatus: onStatus,
                    onClose: { deploying = false }
                )
            }
        }
        .alertDialog(
            visible: $confirmingDelete,
            heading: deleteHeading,
            body: deleteBody
        )
        .response("Cancel", role: .close) {}
        .response("Delete", appearance: .destructive, role: .default) { deleteKey() }
    }

    /// The keys grouped by algorithm, modern types first — a long ~/.ssh reads
    /// as a few short lists instead of one undifferentiated column.
    private var typeSections: [KeyTypeSection] {
        KeyTypeSection.build(store.keys)
    }

    /// Section headers are rows in the same list, because two lists side by side
    /// would each keep their own selection highlight.
    private var listRows: [KeyRow] {
        typeSections.flatMap { section in
            [KeyRow.header(section.type)] + section.keys.map(KeyRow.key)
        }
    }

    /// Clicking a header selects the first key under it, so a header can never
    /// become the visible selection.
    private var listSelection: Binding<String> {
        .init {
            selection
        } set: { newValue in
            guard let index = listRows.firstIndex(where: { $0.id == newValue }) else {
                selection = newValue
                return
            }
            if listRows[index].isHeader {
                selection = listRows[(index + 1)...].first { !$0.isHeader }?.id ?? selection
            } else {
                selection = newValue
            }
        }
    }

    @ViewBuilder private var list: Body {
        ScrollView {
            List(listRows, id: \.id, selection: listSelection) { row in
                switch row {
                case .header(let type):
                    sectionLabel(type)
                        .padding(Spacing.md)
                case .key(let key):
                    keyRow(key)
                }
            }
            .sidebarStyle()
        }
        .topToolbar {
            HeaderBar.end {
                Button(icon: .default(icon: .viewRefresh)) {
                    store.reload()
                    onStatus("Re-scanned the SSH folder")
                }
                .flat()
                .tooltip("Re-scan the SSH folder")
                Button(icon: .default(icon: .listAdd)) { generating = true }
                    .flat()
                    .tooltip("Generate a key")
            }
            .headerBarTitle {
                WindowTitle(subtitle: "", title: "SSH Keys")
            }
        }
        .navigationTitle("SSH Keys")
    }

    /// One view, not a `Body`: a `@ViewBuilder` branch produces a wrapper whose
    /// storage carries no fields, and the navigation title would be lost.
    private var detail: any AnyView {
        if let key = selected {
            keyDetail(key)
                .topToolbar {
                    HeaderBar.end {
                        Menu(icon: .default(icon: .openMenu)) {
                            MenuButton("Copy Public Key (no comment)") { copyPublicKey(key, stripComment: true) }
                            MenuButton("Deploy to Host…") { deploying = true }
                            MenuSection {
                                MenuButton("Copy Private Key") { copyPrivateKey(key) }
                                MenuButton("Copy Fingerprint") {
                                    AdwaitaApp.copy(key.fingerprint)
                                    onStatus("Copied the fingerprint")
                                }
                            }
                            MenuSection {
                                MenuButton("Delete Key…") { confirmingDelete = true }
                            }
                        }
                        .primary()
                        Button("Copy Public Key", icon: .default(icon: .editCopy)) {
                            copyPublicKey(key)
                        }
                        .suggested()
                    }
                    .headerBarTitle {
                        WindowTitle(subtitle: key.sizeLabel, title: key.name)
                    }
                }
        } else {
            StatusPage(
                "No keys",
                icon: .default(icon: .dialogPassword),
                description: "There are no SSH keys in your ~/.ssh directory."
            ) {
                Button("Generate a Key") { generating = true }
                    .suggested()
                    .pill()
                    .halign(.center)
            }
            .topToolbar {
                HeaderBar.empty()
                    .headerBarTitle {
                        WindowTitle(subtitle: "", title: "Key")
                    }
            }
        }
    }

    private var detailTitle: String {
        selected?.name ?? "Key"
    }

    private func keyRow(_ key: SSHKeyEntry) -> AnyView {
        HStack(spacing: Spacing.lg) {
            Symbol(icon: .default(icon: .dialogPassword))
                .style("area-tile")
                .style("tile-keys")
            VStack {
                Text(key.name)
                    .ellipsize()
                    .halign(.start)
                Text(shortFingerprint(key.fingerprint))
                    .ellipsize()
                    .caption()
                    .dimLabel()
                    .monospace()
                    .halign(.start)
            }
            .hexpand()
            if key.isEncrypted == true {
                Symbol(icon: .default(icon: .changesPrevent))
                    .dimLabel()
                    .tooltip("Protected by a passphrase")
                    .valign(.center)
            }
            availability(key)
        }
        .padding(Spacing.md)
    }

    /// Which halves of the pair are on disk. A key with no private half cannot
    /// authenticate, and a key with no `.pub` cannot be deployed, so the row
    /// says which one you are looking at.
    private func availability(_ key: SSHKeyEntry) -> AnyView {
        let hasPublic = key.key.publicKeyURL != nil
        let hasPrivate = key.key.privateKeyURL != nil
        if hasPublic && hasPrivate {
            return Symbol(icon: .default(icon: .emblemOk))
                .style("success")
                .tooltip("Public and private key present")
                .valign(.center)
        }
        if hasPrivate {
            return Symbol(icon: .default(icon: .changesPrevent))
                .style("warning")
                .tooltip("Private key only — no .pub file")
                .valign(.center)
        }
        return Symbol(icon: .default(icon: .dialogPassword))
            .dimLabel()
            .tooltip("Public key only")
            .valign(.center)
    }

    private func keyDetail(_ key: SSHKeyEntry) -> AnyView {
        VStack {
            screenHeader(
                icon: .default(icon: .dialogPassword),
                tile: "tile-keys",
                title: key.name,
                subtitle: key.sizeLabel,
                pills: { detailPills(key) }
            )
            ScrollView {
                keyCards(key)
                    .padding(Spacing.xxl)
                    .frame(maxWidth: 820)
            }
            .vexpand()
        }
    }

    @ViewBuilder private func detailPills(_ key: SSHKeyEntry) -> Body {
        if key.isEncrypted == true {
            statusPill(kind: .ok, text: "Passphrase")
        } else if key.isEncrypted == false {
            statusPill(kind: .warn, text: "No passphrase")
        }
        if key.key.privateKeyURL == nil {
            tagPill(text: "Public half only")
        }
        let users = hostsUsing(key).count
        if users > 0 {
            tagPill(text: users == 1 ? "1 host" : "\(users) hosts")
        }
    }

    @ViewBuilder private func keyCards(_ key: SSHKeyEntry) -> Body {
        VStack(spacing: Spacing.xl) {
            cardSection("Details") {
                row("Fingerprint", key.fingerprint)
                row("SHA256 (hex)", key.key.sha256HexFingerprint ?? "—")
                row("Comment", key.comment.isEmpty ? "—" : key.comment)
                row("Type", key.sizeLabel)
                row("Identity file", key.abbreviatedPath)
                row(
                    "Passphrase",
                    key.isEncrypted.map { $0 ? "Protected" : "None" } ?? "Unknown"
                )
            }
            if let randomart = key.randomart {
                cardSection("Randomart") {
                    Text(randomart)
                        .monospace()
                        .style("randomart")
                        .halign(.center)
                }
            }
            cardSection("Used By") {
                let hosts = hostsUsing(key)
                if hosts.isEmpty {
                    ActionRow("No host uses this key")
                        .subtitle("No Host block names it in IdentityFile.")
                } else {
                    ForEach(hosts) { block in
                        ActionRow(block.title)
                            .useMarkup(false)
                            .subtitle(block.connectionTarget?.host ?? "")
                            .prefix {
                                Symbol(icon: .default(icon: .networkServer))
                                    .style("area-tile")
                                    .style("tile-host")
                                    .valign(.center)
                            }
                    }
                }
            }
            cardSection("Actions") {
                ActionRow("Copy Public Key (no comment)")
                    .activated { copyPublicKey(key, stripComment: true) }
                ActionRow("Deploy to Host…")
                    .subtitle("Append it to a host's authorized_keys.")
                    .activated { deploying = true }
                ActionRow("Copy Private Key")
                    .activated { copyPrivateKey(key) }
                ActionRow("Copy Identity Path")
                    .useMarkup(false)
                    .subtitle(key.abbreviatedPath)
                    .activated {
                        AdwaitaApp.copy(key.abbreviatedPath)
                        onStatus("Copied path")
                    }
                ActionRow("Delete Key…")
                    .activated { confirmingDelete = true }
                    .style("error")
            }
        }
    }

    private func row(_ title: String, _ value: String) -> AnyView {
        ActionRow(title)
            .useMarkup(false)
            .subtitle(value)
            .subtitleSelectable()
    }

    // MARK: - Data

    private func hostsUsing(_ key: SSHKeyEntry) -> [HostBlock] {
        store.hosts.filter { block in
            block.values(for: "IdentityFile")
                .contains { HomePath.expanding($0, home: SSHDirectory.home) == key.path }
        }
    }

    private func shortFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 24 else { return fingerprint }
        return fingerprint.prefix(14) + "…" + fingerprint.suffix(6)
    }

    // MARK: - Actions

    private func copyPublicKey(_ key: SSHKeyEntry, stripComment: Bool = false) {
        guard let url = key.key.publicKeyURL,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            onStatus("This key has no public half on disk")
            return
        }
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripComment {
            // A public key line is "<type> <blob> [comment]". Some servers key their
            // authorized_keys on the exact line, so the comment is dropped on request.
            line = line.split(separator: " ").prefix(2).joined(separator: " ")
        }
        AdwaitaApp.copy(line)
        onStatus("Public key copied")
    }

    private func publicKeyLine(_ key: SSHKeyEntry) -> String {
        guard let url = key.key.publicKeyURL,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deleteHeading: String {
        guard let key = selected else { return "Delete this key?" }
        return hostsUsing(key).isEmpty
            ? "Delete “\(key.name)”?" : "“\(key.name)” is still in use"
    }

    private var deleteBody: String {
        guard let key = selected else { return "" }
        let users = hostsUsing(key).map { $0.title }
        return users.isEmpty
            ? "This removes the key files from ~/.ssh. It cannot be undone from the app."
            : "This key is used by \(users.joined(separator: ", ")). Deleting it breaks SSH access there unless you have already replaced it."
    }

    private func copyPrivateKey(_ key: SSHKeyEntry) {
        guard let url = key.key.privateKeyURL,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            onStatus("This key has no private half on disk")
            return
        }
        AdwaitaApp.copy(text)
        onStatus("Private key copied")
    }

    private func deleteKey() {
        guard let key = selected else { return }
        for url in [key.key.privateKeyURL, key.key.publicKeyURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        store.reload()
        onStatus("Key deleted")
    }

    private func generate(
        _ algorithm: KeyAlgorithm,
        name: String,
        comment: String,
        passphrase: String?,
        host: String?
    ) {
        let privatePath = "\(SSHDirectory.defaultPath)/\(name)"
        guard !FileManager.default.fileExists(atPath: privatePath) else {
            onStatus("\(name) already exists")
            return
        }
        do {
            let key = try SSHKeyGenerator.generate(
                algorithm: algorithm,
                comment: comment,
                passphrase: passphrase
            )
            // The private key must be unreadable to anyone else before it holds a
            // secret, so it is created empty with the right mode and then written.
            FileManager.default.createFile(
                atPath: privatePath,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            try key.privateKeyPEM.write(toFile: privatePath, atomically: false, encoding: .utf8)
            try key.publicKeyText.write(
                toFile: "\(privatePath).pub",
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: "\(privatePath).pub"
            )
            if let host {
                try? store.update(alias: host) { block in
                    block.addDirective(
                        keyword: "IdentityFile",
                        value: HomePath.abbreviating(privatePath, home: SSHDirectory.home)
                    )
                }
            }
            generating = false
            store.reload()
            onStatus("Key generated")
        } catch {
            onStatus("Could not generate: \(error.localizedDescription)")
        }
    }
}
