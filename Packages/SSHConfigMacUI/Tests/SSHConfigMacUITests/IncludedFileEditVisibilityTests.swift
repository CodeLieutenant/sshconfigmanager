//
//  IncludedFileEditVisibilityTests.swift
//  SSHConfigMacUITests
//
//  Regression coverage: an edit to a host that lives in an `Include`d file stayed
//  invisible to `EffectiveConfigResolver` until the next full `reload()`.
//
//  `ConfigStore.configGraph` was built from an `[UUID: [SSHConfigDocument]]` map
//  captured at reload time, and the resolver reaches every included file through
//  that map — never through the live `documents` array. `SSHConfigDocument` is a
//  struct, so the map held pre-edit copies. Symptom: fix `User` on a host in
//  `~/.ssh/config.d/*.conf`, start its tunnel, and the engine still connected as
//  the old user, while `ssh` from a terminal used the new one.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
struct IncludedFileEditVisibilityTests {
    /// Writes a main config that includes `config.d/*.conf`, plus one included file
    /// holding the host under test, and loads both through a granted temp directory.
    private func makeStore() throws -> (store: ConfigStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inc-edit-\(UUID().uuidString)")
        let includeDirectory = directory.appendingPathComponent("config.d")
        try FileManager.default.createDirectory(at: includeDirectory, withIntermediateDirectories: true)
        try "Include \(directory.path)/config.d/*.conf\n"
            .write(to: directory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try """
        Host bastion
            HostName 10.0.0.1
            User deploy
        """
        .write(to: includeDirectory.appendingPathComponent("hosts.conf"), atomically: true, encoding: .utf8)

        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings)
        store.useDirectoryForTesting(directory)
        store.reload(trigger: "test")
        return (store, directory)
    }

    @Test func editingAHostInAnIncludedFileIsVisibleToTheResolver() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolvedBefore = EffectiveConfigResolver.resolve(target: "bastion", in: store.configGraph)
        #expect(resolvedBefore.firstValue(of: "user") == "deploy")

        let block = try #require(store.documents.flatMap(\.blocks).first { $0.patterns == ["bastion"] })
        store.updateBlock(id: block.id) { block in
            block.setValue("rocky", for: "User")
        }

        let resolvedAfter = EffectiveConfigResolver.resolve(target: "bastion", in: store.configGraph)
        #expect(resolvedAfter.firstValue(of: "user") == "rocky")
        #expect(resolvedAfter.firstValue(of: "hostname") == "10.0.0.1")
    }

    /// The tunnel engine reads the same graph to build its hop chain, which is where
    /// the stale value actually reached the network.
    @Test func tunnelHopUsesTheEditedUser() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let block = try #require(store.documents.flatMap(\.blocks).first { $0.patterns == ["bastion"] })
        store.updateBlock(id: block.id) { block in
            block.setValue("rocky", for: "User")
        }

        let hops = try TunnelJumpChain.resolve(alias: "bastion", in: store.configGraph)
        #expect(hops.count == 1)
        #expect(hops.first?.user == "rocky")
        #expect(hops.first?.host == "10.0.0.1")
    }
}
