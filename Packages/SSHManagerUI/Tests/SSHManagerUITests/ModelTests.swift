import Foundation
import Testing

@testable import SSHManagerUI

/// The metadata type writes on every change. Point the XDG config directory at a
/// throwaway path first, so a test run can never overwrite the real hosts.json.
private func useTemporaryConfigDirectory() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sshmanager-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("XDG_CONFIG_HOME", directory.path, 1)
}

@Suite("Host metadata")
struct HostMetadataTests {
    init() { useTemporaryConfigDirectory() }

    /// Groups are recorded as a `group/<name>` tag, the same convention the macOS
    /// build uses. That tag is machinery and must never reach the tag UI.
    @Test("the group tag is hidden from the user's tags")
    func groupTagIsHidden() {
        var metadata = HostMetadata()
        metadata.tagsByAlias["web"] = ["work", "group/Production"]
        #expect(metadata.tags(for: "web") == ["work"])
        #expect(metadata.allTags == ["work"])
    }

    @Test("setting a group keeps the user's own tags")
    func settingGroupKeepsTags() {
        var metadata = HostMetadata()
        metadata.tagsByAlias["web"] = ["work"]
        metadata.groups = [.init(name: "Production", sortIndex: 0)]
        metadata.setGroup(metadata.groups[0], for: "web")
        #expect(metadata.tags(for: "web") == ["work"])
        #expect(metadata.group(for: "web")?.name == "Production")
    }

    @Test("setting tags keeps the group")
    func settingTagsKeepsGroup() {
        var metadata = HostMetadata()
        metadata.groups = [.init(name: "Production", sortIndex: 0)]
        metadata.setGroup(metadata.groups[0], for: "web")
        metadata.setTags(["db"], for: "web")
        #expect(metadata.group(for: "web")?.name == "Production")
        #expect(metadata.tags(for: "web") == ["db"])
    }

    @Test("renaming a group moves its members")
    func renameMovesMembers() {
        var metadata = HostMetadata()
        metadata.groups = [.init(name: "Prod", sortIndex: 0)]
        metadata.setGroup(metadata.groups[0], for: "web")
        metadata.renameGroup(from: "Prod", to: "Production")
        #expect(metadata.group(for: "web")?.name == "Production")
    }

    @Test("deleting a group releases its members")
    func deleteReleasesMembers() {
        var metadata = HostMetadata()
        metadata.groups = [.init(name: "Prod", sortIndex: 0)]
        metadata.setGroup(metadata.groups[0], for: "web")
        metadata.removeGroup(named: "Prod")
        #expect(metadata.group(for: "web") == nil)
        #expect(metadata.groups.isEmpty)
    }
}

@Suite("Tunnel command")
struct TunnelDraftTests {
    @Test("a local forward builds the -L form")
    func localForward() {
        var draft = TunnelDraft()
        draft.hostAlias = "bastion"
        draft.mode = .local
        draft.mappings = [.init(localPort: "5432", remoteHost: "localhost", remotePort: "5432")]
        draft.keepAlive = false
        draft.failIfPortBusy = false
        #expect(draft.command == "ssh -L 5432:localhost:5432 -N bastion")
    }

    /// A dynamic forward takes one port and no target — a host and port there
    /// would be silently ignored by ssh.
    @Test("a dynamic forward takes only the local port")
    func dynamicForward() {
        var draft = TunnelDraft()
        draft.hostAlias = "bastion"
        draft.mode = .dynamic
        draft.mappings = [.init(localPort: "1080", remoteHost: "ignored", remotePort: "99")]
        draft.keepAlive = false
        draft.failIfPortBusy = false
        #expect(draft.command == "ssh -D 1080 -N bastion")
    }

    @Test("options add the flags ssh expects")
    func options() {
        var draft = TunnelDraft()
        draft.hostAlias = "bastion"
        draft.mappings = [.init(localPort: "80", remoteHost: "web", remotePort: "80")]
        draft.compression = true
        draft.keepAlive = true
        draft.failIfPortBusy = true
        #expect(draft.command.contains("-C"))
        #expect(draft.command.contains("ServerAliveInterval=30"))
        #expect(draft.command.contains("ExitOnForwardFailure=yes"))
    }
}

@Suite("Settings")
struct AppSettingsTests {
    /// The Issues screen asks for exactly the categories the toggles enable.
    @Test("audit toggles map to categories")
    func auditCategories() {
        var settings = AppSettings()
        settings.auditWeakAlgorithms = true
        settings.auditLoosePermissions = false
        settings.auditMissingPassphrase = false
        settings.auditUnusedKeys = true
        let categories = settings.enabledAuditCategories
        #expect(categories.contains(.weakAlgorithm))
        #expect(categories.contains(.orphan))
        #expect(!categories.contains(.permissions))
        #expect(!categories.contains(.passphrase))
    }

    @Test("settings round-trip through JSON")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.defaultUser = "deploy"
        settings.maximumVersionsKept = 7
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }
}
