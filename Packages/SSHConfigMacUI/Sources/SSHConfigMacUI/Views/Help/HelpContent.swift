//
//  HelpContent.swift
//  SSHConfigMacUI
//
//  The text of the in-app help book, as plain data. Keeping it separate from
//  `HelpView` means updating the docs is a content edit, never a layout change.
//  Markdown inline syntax (**bold**, `code`) is honoured because the renderer
//  feeds strings through `LocalizedStringKey`.
//
//  Keep this accurate when feature behaviour changes — it's user-facing and is
//  what an App Store reviewer reads to understand the app.
//

import Foundation

/// One article in the help book.
struct HelpTopic: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let blocks: [HelpBlock]
}

/// A typed unit of help content. The renderer (`HelpBlockView`) styles each kind.
enum HelpBlock {
    case paragraph(String)
    case heading(String)
    case bullets([String])
    case steps([String])
    case code(String)
    case note(String)
}

enum HelpContent {
    static let topics: [HelpTopic] = [
        gettingStarted,
        hosts,
        keys,
        agent,
        knownHosts,
        verification,
        tunnels,
        history,
        issues,
        privacy,
        shortcuts,
    ]

    // MARK: - Topics

    static let gettingStarted = HelpTopic(
        id: "getting-started",
        title: "Getting Started",
        systemImage: "sparkles",
        blocks: [
            .paragraph(
                "SSH Config Manager is a native editor for your SSH setup. It reads and writes your real `~/.ssh/config`, manages your keys and `known_hosts`, and can run SSH tunnels directly inside the app — no Terminal required."
            ),
            .heading("Grant access to ~/.ssh"),
            .paragraph(
                "Because the app is sandboxed, macOS asks your permission before it can read your `~/.ssh` folder. On first launch you'll see a one-time access screen."
            ),
            .steps([
                "Click **Grant Access** on the welcome screen.",
                "In the system dialog, your **.ssh** folder is preselected — click **Open**.",
                "That's it. The grant is remembered securely, so you only do this once.",
            ]),
            .note(
                "The app never sends your config, keys, or hostnames anywhere. Everything stays on your Mac. See **Privacy & Security** for details."
            ),
            .heading("The sidebar"),
            .paragraph("The sidebar is your map of the app:"),
            .bullets([
                "**Hosts** — every `Host` block in your config, grouped alphabetically and by included file.",
                "**Favorites** — hosts you've starred for quick access.",
                "**Keys**, **SSH Agent**, **Known Hosts** — manage your key material and trust.",
                "**Tunnels**, **Issues**, **Version History** — run port forwards, review security findings, and browse the full change history of your config.",
            ]),
        ]
    )

    static let hosts = HelpTopic(
        id: "hosts",
        title: "Hosts & Config",
        systemImage: "server.rack",
        blocks: [
            .paragraph(
                "Each entry in your `~/.ssh/config` is a **host**. Select one in the sidebar to edit it with a form, or drop into the raw block editor for full control."
            ),
            .heading("Add a host"),
            .steps([
                "Click the **+** button above the host list (or press **⌘N**).",
                "Give it a name (the `Host` alias you'll type after `ssh`).",
                "Fill in HostName, User, Port, IdentityFile, and any other keywords.",
                "Changes are saved automatically back to `~/.ssh/config`.",
            ]),
            .heading("Duplicate, favorite, and tag"),
            .bullets([
                "Hover a host row for a **Duplicate** action to clone its settings.",
                "Star a host to pin it under **Favorites**.",
                "Add tags to group related hosts, then filter the list by tag.",
            ]),
            .heading("Raw block editor"),
            .paragraph(
                "Prefer to edit the text directly? The raw block editor shows the exact lines for a host. The parser is **lossless** — your comments, ordering, and formatting are preserved exactly."
            ),
            .heading("Import from clipboard"),
            .paragraph(
                "Copy one or more `Host` blocks from anywhere, then choose **File ▸ Import Hosts from Clipboard…** to add them in one step."
            ),
            .heading("Find a host"),
            .paragraph("Press **⌘K** to open the command palette and jump to any host by fuzzy-matching its name."),
        ]
    )

    static let keys = HelpTopic(
        id: "keys",
        title: "SSH Keys",
        systemImage: "key.fill",
        blocks: [
            .paragraph(
                "The **Keys** screen lists the key pairs in your `~/.ssh` folder, with their type, fingerprint, and which hosts use them."
            ),
            .heading("Copy a public key"),
            .paragraph(
                "Select a key and copy its public half to paste into a server's `authorized_keys`, a GitHub/GitLab settings page, or a cloud console."
            ),
            .heading("Generate a new key"),
            .steps([
                "Click **Generate Key**.",
                "Pick a type — **Ed25519** is recommended for new keys; RSA and ECDSA are also supported.",
                "Optionally set a passphrase to encrypt the private key on disk.",
                "The new pair is written into `~/.ssh` and appears in the list.",
            ]),
        ]
    )

    static let agent = HelpTopic(
        id: "agent",
        title: "SSH Agent",
        systemImage: "person.badge.key.fill",
        blocks: [
            .paragraph(
                "The **SSH Agent** screen shows the keys currently loaded into your running `ssh-agent`, so you can see at a glance what can authenticate without re-entering a passphrase."
            ),
            .bullets([
                "View loaded identities and their fingerprints.",
                "Add a key to the agent so connections that use it stop prompting for a passphrase.",
                "Remove identities you no longer want held in memory.",
            ]),
        ]
    )

    static let knownHosts = HelpTopic(
        id: "known-hosts",
        title: "Known Hosts",
        systemImage: "checkmark.shield.fill",
        blocks: [
            .paragraph(
                "`known_hosts` records the host keys you've already trusted. The **Known Hosts** screen organizes that list by server — grouped into **Hostnames**, **IP Addresses**, and **Hashed** — and cross-references each entry with the matching `Host` from your config, so a bare IP reads as the friendly name you actually `ssh` to."
            ),
            .bullets([
                "Browse every trusted host key by host, with its algorithm and fingerprint.",
                "**Verify** a host against its live key, and resolve a change in one click (see **Host Key Verification**).",
                "Remove a stale entry, or every key for a host, when a server's key legitimately changes.",
                "Switch which `known_hosts` file the app is working with.",
            ]),
        ]
    )

    static let verification = HelpTopic(
        id: "verification",
        title: "Host Key Verification",
        systemImage: "lock.shield.fill",
        blocks: [
            .paragraph(
                "Every SSH server proves its identity with a **host key**. The first time you connect, SSH records that key in `known_hosts`; on every later connection it checks that the server still presents the **same** key. This is what stops someone from impersonating your server."
            ),
            .heading("Why it matters"),
            .paragraph(
                "If an attacker sits between you and your server (a **man-in-the-middle**), they can present *their* key instead of the real one. If you accept it, your session — passwords, commands, forwarded data — flows through the attacker. A host key that suddenly **changes** is the single most important warning SSH gives you."
            ),
            .bullets([
                "**Match** — the server's key is the one you trust. Safe to connect.",
                "**Changed** — the server is presenting a *different* key than the one stored. Either the host was legitimately rebuilt/re-keyed, or someone is intercepting you. Never accept it blindly — confirm out-of-band (ask your provider, check a console).",
                "**New / unknown** — no key on record yet. Trust-on-first-use: fine on a trusted network, risky on a hostile one.",
            ]),
            .heading("Verify a host's live key"),
            .paragraph(
                "On the **Known Hosts** screen, select a host and click **Verify**. The app connects to the server, reads the key it presents right now, and compares it to what's stored — showing **Verified**, **Changed**, or **New key**. It never logs in or sends credentials; it only reads the public host key, exactly like `ssh-keyscan`."
            ),
            .heading("Background monitoring"),
            .paragraph(
                "With monitoring on (Settings ▸ General ▸ Host Key Monitoring), the app re-checks every known host on a schedule — hourly by default — so a key that changes is caught **before** your next connection. Findings appear on the Known Hosts screen, in the menu-bar item, and as a notification."
            ),
            .bullets([
                "A green **shield** with “Checked …” means every host was verified recently.",
                "It turns **amber** after a day without a successful check, and **red** after a week — a nudge that your trust data is going stale.",
                "Results are stored locally and pruned automatically, so the history never grows without bound.",
            ]),
            .heading("Resolve a changed key"),
            .steps([
                "Select the flagged host — a red banner explains what changed and shows the live fingerprint.",
                "Click **Resolve…**.",
                "**Replace Trusted Key** — only after you've confirmed the host was rebuilt or re-keyed. Removes the old key and trusts the new one.",
                "**Add as Additional Key** — keep the old key and trust the new one too (e.g. a second key type).",
                "**Delete Old Key** — retire a key for a server that's gone.",
            ]),
            .note(
                "Confirm a changed key through a channel **other** than the suspect connection before replacing it. If you can't explain why it changed, treat it as hostile."
            ),
            .heading("Fetch keys for a configured host"),
            .paragraph(
                "When you add a `Host` to your config, open it and use **Fetch Host Key** to pull the server's current key into `known_hosts` straight away. From then on the monitor keeps it verified, so a later change stands out immediately."
            ),
        ]
    )

    static let tunnels = HelpTopic(
        id: "tunnels",
        title: "Tunnels",
        systemImage: "point.3.connected.trianglepath.dotted",
        blocks: [
            .paragraph(
                "SSH Config Manager runs tunnels **in-process** — there's no `ssh` subprocess and no Terminal window. Start a tunnel and it stays managed by the app, with live status, throughput, and a per-tunnel console."
            ),
            .heading("Forward types"),
            .bullets([
                "**Local (-L)** — forward a local port to a remote address through the SSH server.",
                "**Remote (-R)** — expose a local service on the remote host.",
                "**Dynamic (-D)** — run a local SOCKS proxy.",
            ]),
            .heading("ProxyCommand"),
            .paragraph(
                "Three `ProxyCommand` idioms run in-process, no subprocess needed: `ssh -W %h:%p <bastion>` (treated as ProxyJump), a SOCKS5 proxy (`nc -x`, `connect -S`), and an HTTP CONNECT proxy (`corkscrew`, `connect -H`). Anything else — `cloudflared access ssh`, a custom wrapper script — needs the unsandboxed direct-download build, since the Mac App Store sandbox can't run an arbitrary command."
            ),
            .heading("Create a tunnel"),
            .steps([
                "Open **Tunnels** in the sidebar and click **+**.",
                "Choose the SSH host (jump hosts / ProxyJump are supported for multi-hop).",
                "Add one or more port forwards — a single tunnel can carry several over one connection.",
                "Start it. The app keeps it healthy, retrying with backoff if the link drops.",
            ]),
            .paragraph(
                "Authentication uses your `ssh-agent` keys or your configured key files, and the server's identity is verified against `known_hosts` (new hosts are trusted on first use)."
            ),
        ]
    )

    static let history = HelpTopic(
        id: "history",
        title: "Version History",
        systemImage: "clock.arrow.circlepath",
        blocks: [
            .paragraph(
                "Every settled edit to your config — and any change made outside the app — is committed to a built-in, git-style history. You can browse past versions and restore any one of them."
            ),
            .bullets([
                "Each editing burst becomes a version; restoring then editing forks a branch, so nothing is ever lost.",
                "Storage is content-addressed and compressed, so unchanged files are stored once and any version restores instantly.",
            ]),
            .paragraph("Open **Version History** in the sidebar to browse the timeline and restore a version."),
        ]
    )

    static let issues = HelpTopic(
        id: "issues",
        title: "Issues & Audit",
        systemImage: "exclamationmark.triangle.fill",
        blocks: [
            .paragraph("The **Issues** screen audits your keys and surfaces problems worth fixing, such as:"),
            .bullets([
                "Private keys with loose file permissions.",
                "Weak or deprecated key algorithms.",
                "Other configuration risks the app can detect.",
            ]),
            .paragraph(
                "Each finding explains what's wrong and why it matters. You can dismiss categories you don't care about in **Settings ▸ Audit**."
            ),
        ]
    )

    static let privacy = HelpTopic(
        id: "privacy",
        title: "Privacy & Security",
        systemImage: "lock.shield.fill",
        blocks: [
            .paragraph("Your SSH setup is sensitive, so the app is built to keep it on your Mac."),
            .bullets([
                "**Sandboxed.** The app runs in Apple's App Sandbox and can only touch the `~/.ssh` folder you explicitly granted.",
                "**No telemetry.** Your config, keys, hostnames, and tunnel activity are never sent anywhere.",
                "**In-process tunnels.** Tunnels run inside the app over a vetted SSH library — no shelling out, no Terminal, no quarantine games.",
                "**Local-only network use.** The only network requests the app makes are the SSH connections you start.",
            ]),
        ]
    )

    static let shortcuts = HelpTopic(
        id: "shortcuts",
        title: "Keyboard Shortcuts",
        systemImage: "keyboard",
        blocks: [
            .heading("General"),
            .bullets([
                "**⌘N** — New host",
                "**⌘K** — Find a host (command palette)",
                "**⌘S** — Save now",
                "**⌘R** — Revert to the last saved version",
                "**⌘,** — Settings",
                "**⌘?** — Open this help",
            ]),
        ]
    )
}
