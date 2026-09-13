//
//  PortablePathTests.swift
//  sshconfigmanagerTests
//
//  A path written into ssh_config must come out `~/…`, not `/Users/<you>/…`:
//  the file gets synced between machines and to Linux, where an absolute macOS
//  home path resolves to nothing. Covers the `HomePath` primitive and the
//  `ConfigStore.updateBlock` chokepoint that applies it to every edit.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct HomePathTests {
    private let home = "/Users/dana"

    @Test func abbreviatesPathsUnderHome() {
        #expect(HomePath.abbreviating("/Users/dana/.ssh/id_ed25519", home: home) == "~/.ssh/id_ed25519")
        #expect(HomePath.abbreviating("/Users/dana", home: home) == "~")
        #expect(HomePath.abbreviating("/Users/dana/", home: home) == "~/")
    }

    /// A sibling directory that merely shares the prefix must not be rewritten —
    /// `~ana-old/…` would be a different (and wrong) path entirely.
    @Test func leavesPrefixSiblingsAlone() {
        #expect(HomePath.abbreviating("/Users/dana-old/.ssh/key", home: home) == "/Users/dana-old/.ssh/key")
        #expect(HomePath.abbreviating("/etc/ssh/ssh_config", home: home) == "/etc/ssh/ssh_config")
    }

    @Test func leavesAlreadyPortablePathsAlone() {
        #expect(HomePath.abbreviating("~/.ssh/id_ed25519", home: home) == "~/.ssh/id_ed25519")
        #expect(HomePath.abbreviating("~other/.ssh/key", home: home) == "~other/.ssh/key")
    }

    @Test func toleratesTrailingSlashOnHomeAndEmptyHome() {
        #expect(HomePath.abbreviating("/Users/dana/.ssh/key", home: "/Users/dana/") == "~/.ssh/key")
        #expect(HomePath.abbreviating("/Users/dana/.ssh/key", home: "") == "/Users/dana/.ssh/key")
    }

    @Test func expandingIsTheInverseForTildePaths() {
        #expect(HomePath.expanding("~/.ssh/key", home: home) == "/Users/dana/.ssh/key")
        #expect(HomePath.expanding("~", home: home) == "/Users/dana")
        // `~user` is the OS's job to resolve, not a string rewrite.
        #expect(HomePath.expanding("~other/.ssh/key", home: home) == "~other/.ssh/key")
        #expect(HomePath.expanding("/etc/ssh_config", home: home) == "/etc/ssh_config")
    }
}

@MainActor
struct PortablePathWriteTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshportable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store(seeding config: String, in dir: URL) throws -> ConfigStore {
        try config.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings)
        store.useDirectoryForTesting(dir)
        store.reload()
        return store
    }

    /// The file picker and the key list both hand back `/Users/<you>/…`. Writing that
    /// verbatim is what pinned a config to one machine.
    @Test func absoluteHomePathIsWrittenAsTilde() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(seeding: "Host alpha\n    HostName a\n", in: dir)
        let home = SSHFileAccess.realHomeDirectory.path

        guard let id = store.allHostBlocks.first?.id else {
            Issue.record("no block")
            return
        }
        store.updateBlock(id: id) { $0.setValue("\(home)/.ssh/id_ed25519", for: "IdentityFile") }

        #expect(store.block(id: id)?.firstValue(for: "IdentityFile") == "~/.ssh/id_ed25519")
    }

    @Test func pathOutsideHomeIsLeftAbsolute() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(seeding: "Host alpha\n    HostName a\n", in: dir)

        guard let id = store.allHostBlocks.first?.id else {
            Issue.record("no block")
            return
        }
        store.updateBlock(id: id) { $0.setValue("/etc/ssh/keys/id_ed25519", for: "IdentityFile") }

        #expect(store.block(id: id)?.firstValue(for: "IdentityFile") == "/etc/ssh/keys/id_ed25519")
    }

    /// Only what this edit touched gets rewritten — a hand-written absolute path on
    /// another line stays byte-exact, which is what keeps the parser lossless.
    @Test func untouchedDirectivesKeepTheirOriginalText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = SSHFileAccess.realHomeDirectory.path
        let store = try store(
            seeding: "Host alpha\n    HostName a\n    IdentityFile \(home)/.ssh/existing\n", in: dir)

        guard let id = store.allHostBlocks.first?.id else {
            Issue.record("no block")
            return
        }
        store.updateBlock(id: id) { $0.setValue("2222", for: "Port") }

        #expect(store.block(id: id)?.firstValue(for: "IdentityFile") == "\(home)/.ssh/existing")
    }

    /// A space-bearing path must stay quoted after abbreviation, or the written line
    /// splits into two tokens and ssh reads a different file.
    @Test func abbreviatedPathWithSpacesStaysQuoted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(seeding: "Host alpha\n    HostName a\n", in: dir)
        let home = SSHFileAccess.realHomeDirectory.path

        guard let id = store.allHostBlocks.first?.id else {
            Issue.record("no block")
            return
        }
        store.updateBlock(id: id) {
            $0.setValue("\(home)/Library/Group Containers/agent.sock", for: "IdentityAgent")
        }

        let block = store.block(id: id)
        #expect(block?.firstValue(for: "IdentityAgent") == "~/Library/Group Containers/agent.sock")
        #expect(
            block?.body.contains {
                $0.directive?.value == "\"~/Library/Group Containers/agent.sock\""
            } == true)
    }
}
