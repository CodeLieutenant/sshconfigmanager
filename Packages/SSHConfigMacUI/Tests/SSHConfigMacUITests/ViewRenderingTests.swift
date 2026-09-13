//
//  ViewRenderingTests.swift
//  sshconfigmanagerTests
//
//  Smoke-renders SwiftUI views across representative states (empty / populated /
//  error / each status) so their `body` actually executes — catching crashes,
//  bad force-unwraps, and missing-environment bugs that only surface at render
//  time. `ImageRenderer` evaluates the view tree off-screen, no UI session needed.
//  These complement the logic suites; they assert "this screen renders given this
//  state" rather than deep interaction (which would need a UI test).
//

import Foundation
import SSHConfigCore
import SSHConfigSync
import SwiftUI
import Testing

@testable import SSHConfigMacUI

@MainActor
struct ViewRenderingTests {
    /// Forces `view.body` to evaluate by rendering it to an image off-screen.
    private func render(_ view: some View) {
        let renderer = ImageRenderer(content: view.environment(testGistSyncStore()))
        _ = renderer.nsImage
    }

    private struct NullGistSecretStore: GistSecretStoring {
        func saveToken(_ token: String) throws {}
        func token() -> String? { nil }
        func removeToken() {}
        func savePassphrase(_ passphrase: String) throws {}
        func passphrase() -> String? { nil }
        func removePassphrase() {}
    }

    private func testGistSyncStore() -> GistSyncStore {
        GistSyncStore(
            settings: isolatedSettings(), secretStore: NullGistSecretStore(), configStore: ConfigStore())
    }

    // MARK: - Seeding helpers
    //
    // The views read two `@Observable` stores from the environment. Most render
    // branches split on "empty vs. populated", so each helper offers both: an
    // empty store and one loaded with representative data. A few branches (keys,
    // known_hosts, backups, `hasAccess`) only light up when the store has read a
    // real directory — so `populatedConfigStore` writes a tiny temp `~/.ssh`,
    // grants access to it, and reloads. Everything lives under a unique temp dir,
    // so the suite stays parallel-safe and never touches the user's files.

    private let cfgURL = URL(fileURLWithPath: "/tmp/config")

    /// A private settings instance (no database) so constructing stores never
    /// touches `AppSettings.shared` — that global loads asynchronously and is
    /// mutated by other suites, so sharing it races. Autosave is forced off so
    /// no background disk writes are scheduled during a render.
    private func isolatedSettings() -> AppSettings {
        let s = AppSettings(database: nil)
        s.autosaveEnabled = false
        return s
    }

    /// A ConfigStore with three hosts loaded in memory (no disk, no access).
    private func memoryConfigStore(
        _ text: String = """
        Host web
            HostName web.example.com
            User deploy
            Port 22
            IdentityFile ~/.ssh/id_ed25519
        Host db *.internal
            HostName db.example.com
            StrictHostKeyChecking no
            Port nope
        Match host server user admin
            ForwardAgent yes
        """
    ) -> ConfigStore {
        let store = ConfigStore(settings: isolatedSettings())
        store.loadForTesting([SSHConfigParser.parse(text, sourceURL: cfgURL)])
        return store
    }

    /// A ConfigStore that has actually read a temp `~/.ssh` directory — so
    /// `hasAccess`, `publicKeys`, and `knownHosts` are all populated. Returns the
    /// directory too so the caller can keep it alive / clean it up.
    private func directoryConfigStore() throws -> (ConfigStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewrender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        Host web
            HostName web.example.com
            User deploy
        Host bastion
            HostName bastion.example.com
        """.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        // A public key so `publicKeys` is non-empty (KeysView / identity popover).
        try "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa user@host\n"
            .write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        // A known_hosts line so `knownHosts` is non-empty (KnownHostsView).
        try "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
            .write(to: dir.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
        let store = ConfigStore(settings: isolatedSettings())
        store.useDirectoryForTesting(dir)
        store.reload()
        return (store, dir)
    }

    /// An empty TunnelStore (no presets), backed by a throwaway temp DB.
    private func emptyTunnelStore() -> TunnelStore {
        TunnelStore(persistenceURL: tempDBURL(), engine: RenderNoopEngine())
    }

    /// A TunnelStore with a couple of presets across two hosts, one of them
    /// "started" (so a status + a console log line exist for it). Awaits the
    /// initial async DB load so `isLoaded` is true — the management screen gates
    /// its whole content on that, rendering a spinner until it flips.
    private func populatedTunnelStore() async -> TunnelStore {
        let store = TunnelStore(persistenceURL: tempDBURL(), engine: RenderNoopEngine())
        await store.waitUntilLoaded()
        let local = TunnelPreset(
            name: "Postgres", hostAlias: "bastion", mode: .local,
            mappings: [PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432)])
        let socks = TunnelPreset(
            name: "SOCKS", hostAlias: "web", mode: .dynamic,
            mappings: [PortMapping(listenPort: 1080)])
        store.add(local)
        store.add(socks)
        store.start(local) // marks running + appends a status log line
        return store
    }

    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("viewrender-\(UUID().uuidString).store")
    }

    private func firstHostID(_ store: ConfigStore) -> HostBlock.ID {
        store.documents[0].blocks[0].id
    }

    // MARK: - TunnelStatusBadge (pre-existing)

    @Test func tunnelStatusBadgeRendersEveryState() {
        let states: [TunnelStatus] = [
            .stopped, .starting, .active(since: Date(timeIntervalSinceNow: -90)),
            .degraded, .retrying(attempt: 3), .failed(reason: "auth failed"),
        ]
        for state in states {
            render(TunnelStatusBadge(status: state))
            render(TunnelStatusBadge(status: state, showsLabel: false))
        }
    }

    @Test func uptimeFormatsSecondsMinutesHours() {
        #expect(TunnelStatusBadge.uptime(Date(timeIntervalSinceNow: -5)).hasSuffix("s"))
        #expect(TunnelStatusBadge.uptime(Date(timeIntervalSinceNow: -120)).hasSuffix("m"))
        #expect(TunnelStatusBadge.uptime(Date(timeIntervalSinceNow: -3700)).contains("h"))
    }

    // MARK: - Tunnels screens

    @Test func tunnelEditorRendersEmptyPickerAndLockedHostInEachMode() {
        let config = memoryConfigStore()
        let tunnels = emptyTunnelStore()
        // New, host pickable (the "" picker branch).
        render(TunnelEditorView(existing: nil).environment(tunnels).environment(config))
        // New, host locked.
        render(TunnelEditorView(hostAlias: "web", existing: nil).environment(tunnels).environment(config))
        // Editing each mode exercises the mode-specific labels + mappingRow target columns.
        for mode in TunnelMode.allCases {
            let preset = TunnelPreset(
                name: "T", hostAlias: "web", mode: mode,
                mappings: [
                    PortMapping(listenPort: 5432, targetHost: "db", targetPort: 5432),
                    PortMapping(listenPort: 6379, targetHost: "cache", targetPort: 6379),
                ])
            render(TunnelEditorView(existing: preset).environment(tunnels).environment(config))
        }
    }

    @Test func tunnelsManagementRendersEmptyAndPopulated() async {
        let config = memoryConfigStore()
        render(TunnelsManagementView().environment(emptyTunnelStore()).environment(config))
        render(TunnelsManagementView().environment(await populatedTunnelStore()).environment(config))
    }

    @Test func tunnelsSectionRendersEmptyAndPopulated() async {
        let config = memoryConfigStore()
        render(
            Form { TunnelsSection(hostAlias: "bastion") }
                .environment(emptyTunnelStore()).environment(config))
        render(
            Form { TunnelsSection(hostAlias: "bastion") }
                .environment(await populatedTunnelStore()).environment(config))
        // Empty-alias disables the add button (a distinct branch).
        render(
            Form { TunnelsSection(hostAlias: "") }
                .environment(emptyTunnelStore()).environment(config))
    }

    @Test func tunnelConsoleAndActivityRenderEmptyAndWithLogs() async {
        let tunnels = await populatedTunnelStore()
        // Guard rather than force-unwrap: if no preset reaches "running" this
        // fails one test instead of crashing the whole run.
        guard let running = tunnels.presets.first(where: { tunnels.status(for: $0.id).isRunning }) else {
            Issue.record("no preset reached the running state — requires a test environment that can start tunnels")
            return
        }
        let idle = tunnels.presets.first { !tunnels.status(for: $0.id).isRunning }!
        render(TunnelConsoleView(preset: running).environment(tunnels)) // has log lines
        render(TunnelConsoleView(preset: idle).environment(tunnels)) // empty state
        render(TunnelActivityView(preset: running).environment(tunnels))
        render(TunnelActivityView(preset: idle).environment(tunnels))
    }

    // MARK: - Host detail + its sub-views

    @Test func hostDetailRendersHostMatchAndMissing() async {
        let config = memoryConfigStore()
        let tunnels = await populatedTunnelStore()
        // Host block (index 0), Match block (index 2), and a not-found id.
        render(
            HostDetailView(blockID: config.documents[0].blocks[0].id)
                .environment(config).environment(tunnels))
        render(
            HostDetailView(blockID: config.documents[0].blocks[2].id)
                .environment(config).environment(tunnels))
        render(
            HostDetailView(blockID: UUID())
                .environment(config).environment(tunnels))
    }

    @Test func rawBlockEditorRenders() {
        let config = memoryConfigStore()
        let tunnels = emptyTunnelStore()
        render(
            NavigationStack {
                RawBlockEditor(blockID: firstHostID(config), showRaw: .constant(true))
            }.environment(config).environment(tunnels))
    }

    @Test func effectiveConfigRendersMatchAndNoMatch() {
        let config = memoryConfigStore()
        render(EffectiveConfigView(target: "web").environment(config)) // settings apply
        render(EffectiveConfigView(target: "no-such-host-xyz").environment(config)) // empty
    }

    // MARK: - Components

    @Test func keywordFieldRowRendersEachFieldKind() {
        for keyword in ["HostName", "Port", "Compression", "StrictHostKeyChecking", "Ciphers"] {
            if let info = KeywordRegistry.info(for: keyword) {
                render(
                    Form {
                        KeywordFieldRow(info: info, value: .constant("yes"), boolValue: .constant(true))
                    })
            }
        }
    }

    @Test func addIdentityKeyPopoverRendersEmptyAndPopulated() throws {
        let (store, dir) = try directoryConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        render(AddIdentityKeyPopover(keys: store.publicKeys, onPick: { _ in }, onBrowse: {}))
        render(AddIdentityKeyPopover(keys: [], onPick: { _ in }, onBrowse: {}))
    }

    @Test func addSettingCatalogRendersWithAndWithoutCustomRow() {
        render(AddSettingCatalogView(present: { ["hostname"] }, onAdd: { _ in }, onAddCustom: { _ in }))
    }

    // MARK: - Tools screens (need a real directory for keys / known_hosts)

    @Test func keysViewRendersEmptyAndPopulated() throws {
        render(KeysView().environment(memoryConfigStore())) // no access → empty overlay
        let (store, dir) = try directoryConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        render(KeysView().environment(store))
    }

    @Test func agentViewRendersEveryStatus() throws {
        // Unavailable: no SSH_AUTH_SOCK reachable.
        let unavailable = memoryConfigStore()
        unavailable.setAgentStateForTesting([], status: .unavailable)
        render(NavigationStack { AgentView().environment(unavailable) })

        // Failed: socket present but the lookup errored.
        let failed = memoryConfigStore()
        failed.setAgentStateForTesting([], status: .failed("connection refused"))
        render(NavigationStack { AgentView().environment(failed) })

        // Available but empty (no disk keys, no loaded identities).
        let empty = memoryConfigStore()
        empty.setAgentStateForTesting([], status: .available)
        render(NavigationStack { AgentView().environment(empty) })

        // Available + populated: a disk key that's loaded, a disk key that's not,
        // and an agent-only identity (no file on disk). Exercises both sidebar
        // sections, the loaded/unloaded rows, and the agent-only detail branch.
        let (store, dir) = try directoryConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let diskBlob = blob(matching: store.publicKeys.first)
        store.setAgentStateForTesting(
            [
                AgentIdentity(keyBlob: diskBlob, comment: "me@mac", keyType: "ssh-ed25519"),
                AgentIdentity(keyBlob: [9, 9, 9, 9], comment: "1Password", keyType: "ssh-ed25519"),
            ],
            status: .available)
        render(NavigationStack { AgentView().environment(store) })
    }

    @Test func addToAgentSheetRenders() throws {
        let (_, dir) = try directoryConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The seeded key is `.pub`-only (no private), so synthesize one with a
        // private URL to exercise the add command path.
        let key = SSHPublicKey(
            id: UUID(),
            publicKeyURL: dir.appendingPathComponent("id_ed25519.pub"),
            privateKeyURL: dir.appendingPathComponent("id_ed25519"),
            algorithm: "ssh-ed25519", fingerprint: "SHA256:abc", comment: "me@mac")
        render(AddToAgentSheet(key: key))
    }

    /// Recovers the raw key blob for the first discovered `.pub` so a synthetic
    /// agent identity can be made to correlate with it (same fingerprint).
    private func blob(matching key: SSHPublicKey?) -> [UInt8] {
        guard let key, let url = key.publicKeyURL,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [1, 2, 3] }
        let base64 = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return Data(base64Encoded: base64).map(Array.init) ?? [1, 2, 3]
    }

    @Test func knownHostsViewRendersEmptyAndPopulated() throws {
        render(KnownHostsView().environment(memoryConfigStore()).environment(HostKeyMonitor.shared)) // empty overlay
        let (store, dir) = try directoryConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        render(KnownHostsView().environment(store).environment(HostKeyMonitor.shared))
    }

    @Test func issuesViewRendersCleanAndWithFindings() {
        // The default fixture has StrictHostKeyChecking no + a bad Port → findings.
        render(IssuesView(selection: .constant(nil)).environment(memoryConfigStore()))
        // A clean config → the "no issues" branch.
        render(
            IssuesView(selection: .constant(nil))
                .environment(memoryConfigStore("Host clean\n    HostName c.example.com\n")))
    }

    /// Renders the Issues view with key findings present so every `actions(for:)`
    /// branch (chmod fix, orphaned reveal/delete, generate-replacement) executes.
    @Test func issuesViewRendersKeyFindingActions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewrender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A referenced weak RSA key → generate-replacement (not orphaned).
        try "Host web\n    HostName w\n    IdentityFile ~/.ssh/weakrsa\n".write(
            to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try Self.rsaPubLine(bits: 1024).write(
            to: dir.appendingPathComponent("weakrsa.pub"), atomically: true, encoding: .utf8)
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n".write(
            to: dir.appendingPathComponent("weakrsa"), atomically: true, encoding: .utf8)
        // An unreferenced, loose-perms key → permission fix + orphaned delete.
        let orphan = dir.appendingPathComponent("orphan")
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n".write(
            to: orphan, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: orphan.path)

        let store = ConfigStore(settings: isolatedSettings())
        store.useDirectoryForTesting(dir)
        store.reload()
        render(IssuesView(selection: .constant(nil)).environment(store))
    }

    @Test func generateKeySheetRendersWithPrefilledComment() {
        render(
            GenerateKeySheet(initialComment: "legacy@host") { _ in }
                .environment(memoryConfigStore()))
    }

    /// Builds an `ssh-rsa <base64> comment` line with a modulus of exactly `bits` bits.
    private static func rsaPubLine(bits: Int) -> String {
        var modulus = [UInt8](repeating: 0, count: bits / 8)
        modulus[0] = 0x80
        func ssh(_ bytes: [UInt8]) -> [UInt8] {
            let n = UInt32(bytes.count)
            return [
                UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF),
                UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF),
            ] + bytes
        }
        var blob = ssh(Array("ssh-rsa".utf8))
        blob += ssh([0x01, 0x00, 0x01])
        blob += ssh([0x00] + modulus)
        return "ssh-rsa " + Data(blob).base64EncodedString() + " weak@host\n"
    }

    @Test func versionHistoryRendersEmptyAndPopulated() async {
        // Disabled (nil-database) history → the empty branch.
        render(VersionHistoryView().environment(memoryConfigStore()))

        // A temp-database history with two differing versions drives the populated
        // branch. The diff between the newest version and its parent is non-empty.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewrender-hist-\(UUID().uuidString).store")
        let history = ConfigHistoryStore(database: AppDatabase.testDatabase(at: url))
        await history.waitUntilLoaded()
        await history.commit(
            files: [("config", "Host web\n    HostName old.example.com\n")],
            source: .initial, maxVersions: 100)
        await history.commit(
            files: [("config", "Host web\n    HostName web.example.com\n    User deploy\n")],
            source: .autosave, maxVersions: 100)
        #expect(history.versions.count == 2)

        if let newest = history.versions.first, let parent = newest.parentID {
            let newText = await history.displayText(for: newest.id)
            let oldText = await history.displayText(for: parent)
            let (added, removed) = TextDiff.stat(old: oldText, new: newText)
            #expect(added + removed > 0)
        }

        let store = ConfigStore(
            settings: isolatedSettings(),
            passphraseStore: FakePassphraseStore([:]), history: history)
        render(VersionHistoryView().environment(store))
    }

    @Test func settingsViewRenders() {
        render(SettingsView())
    }

    // MARK: - Top-level shells

    @Test func sidebarRendersWithAccessAndWithout() async throws {
        let tunnels = await populatedTunnelStore()
        render(
            SidebarView(selection: .constant(nil))
                .environment(memoryConfigStore()).environment(tunnels))
        let (store, dir) = try directoryConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        render(
            NavigationStack {
                SidebarView(selection: .constant(.keys))
                    .environment(store).environment(tunnels)
            })
    }

    /// Drives the Sidebar's data-dependent branches: favorites section, tag chips,
    /// the tag-filter toolbar, the save-status footer, and the "No matches" state.
    @Test func sidebarRendersFavoritesTagsAndStatusFooter() async {
        let store = memoryConfigStore(
            """
            Host web
                HostName web.example.com
            Host db
                HostName db.example.com
            """)
        let web = store.allHostBlocks.first { $0.title == "web" }!
        store.toggleFavorite(web) // favorites section appears
        store.setTags(["work", "prod"], for: web) // tag chips + tag-filter toolbar
        let tunnels = await populatedTunnelStore()

        // Default state: favorites + tag filter menu + up-to-date footer.
        render(
            NavigationStack {
                SidebarView(selection: .constant(nil)).environment(store).environment(tunnels)
            })
        // Active tag filter (favorites hidden, filtered list).
        store.tagFilter = "work"
        render(
            NavigationStack {
                SidebarView(selection: .constant(nil)).environment(store).environment(tunnels)
            })
        // Search with no matches (favorites hidden, "No matches" branch).
        store.tagFilter = nil
        store.searchText = "zzz-no-such-host"
        render(
            NavigationStack {
                SidebarView(selection: .constant(nil)).environment(store).environment(tunnels)
            })
    }

    @Test func menuBarContentRendersNoAccessAndPopulated() async throws {
        render(
            MenuBarContentView().environment(memoryConfigStore()).environment(emptyTunnelStore())
                .environment(HostKeyMonitor.shared))
        let (store, dir) = try directoryConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        render(
            MenuBarContentView().environment(store).environment(await populatedTunnelStore())
                .environment(HostKeyMonitor.shared))
    }

    @Test func commandPaletteRendersEmptyAndMatching() async {
        let config = memoryConfigStore()
        let tunnels = await populatedTunnelStore()
        render(CommandPaletteView { _ in }.environment(config).environment(tunnels))
    }

    @Test func contentViewRendersGrantedAndUngranted() async throws {
        // Ungranted (no access) → GrantAccessView branch.
        render(ContentView().environment(memoryConfigStore()).environment(emptyTunnelStore()))
        // Granted → the full split view.
        let (store, dir) = try directoryConfigStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        render(ContentView().environment(store).environment(await populatedTunnelStore()))
    }
}

/// A render-only engine: never touches the network, just satisfies the protocol
/// so `TunnelStore.start` can flip a preset to "running" (and append a log line).
@MainActor
private final class RenderNoopEngine: TunnelEngine {
    let capabilities = TunnelEngineCapabilities(reportsLiveness: false, canStop: true, survivesAppQuit: false)
    func start(_ preset: TunnelPreset) throws {
        if !preset.isValid { throw TunnelEngineError.invalidPreset }
    }
    func stop(_ preset: TunnelPreset) {}
}
