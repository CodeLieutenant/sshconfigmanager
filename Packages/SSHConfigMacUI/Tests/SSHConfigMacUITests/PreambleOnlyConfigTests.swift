//
//  PreambleOnlyConfigTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for bug #2 in docs/macos-prerelease-bug-audit.md:
//  a config that has a preamble (global directives and/or comments) but NO
//  Host/Match block would crash every block-adding entry point with an
//  Array index out of range. The offending guard was
//      if !blocks.isEmpty || !preamble.isEmpty { blocks[blocks.count - 1]… }
//  which indexes blocks[-1] when blocks is empty but preamble is not.
//
//  A preamble-only ~/.ssh/config (e.g. just `ServerAliveInterval 60`) is a very
//  common shape, so these paths must be safe. Each test drives one of the five
//  affected methods against a preamble-only store and asserts a well-formed
//  result (and that the original preamble survives, byte-preserved).
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
struct PreambleOnlyConfigTests {
    private static let cfgURL = URL(fileURLWithPath: "/tmp/config")

    private func parse(_ text: String) -> SSHConfigDocument {
        SSHConfigParser.parse(text, sourceURL: Self.cfgURL)
    }

    private func makeStore(_ text: String) -> ConfigStore {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings)
        store.loadForTesting([parse(text)])
        return store
    }

    /// Two representative preamble-only shapes: global directives, and a comment
    /// banner. Both parse into a document with zero blocks and a non-empty preamble.
    private static let globalsOnly = "ServerAliveInterval 60\nServerAliveCountMax 3\n"
    private static let commentsOnly = "# my ssh config\n# do not edit above\n"

    @Test func preambleOnlyParsesToZeroBlocks() {
        let doc = parse(Self.globalsOnly)
        #expect(doc.blocks.isEmpty)
        #expect(!doc.preamble.isEmpty)
    }

    @Test func addHostOnGlobalsOnlyConfigDoesNotCrash() {
        let store = makeStore(Self.globalsOnly)
        let id = store.addHost()
        #expect(id != nil)
        #expect(store.documents[0].blocks.count == 1)
        // The preamble must still be present in the serialized output.
        let out = SSHConfigSerializer.serialize(store.documents[0])
        #expect(out.contains("ServerAliveInterval 60"))
    }

    @Test func addHostOnCommentsOnlyConfigDoesNotCrash() {
        let store = makeStore(Self.commentsOnly)
        let id = store.addHost()
        #expect(id != nil)
        #expect(store.documents[0].blocks.count == 1)
        let out = SSHConfigSerializer.serialize(store.documents[0])
        #expect(out.contains("# my ssh config"))
    }

    @Test func ensureGlobalDefaultsOnPreambleOnlyConfigDoesNotCrash() {
        let store = makeStore(Self.globalsOnly)
        let id = store.ensureGlobalDefaultsBlock()
        #expect(id != nil)
        #expect(store.documents[0].blocks.count == 1)
        #expect(store.documents[0].blocks[0].isWildcard)
    }

    @Test func addHostFromTemplateOnPreambleOnlyConfigDoesNotCrash() {
        let store = makeStore(Self.globalsOnly)
        let template = HostTemplate.all.first!
        let id = store.addHost(template: template)
        #expect(id != nil)
        #expect(store.documents[0].blocks.count == 1)
    }

    @Test func importHostsOntoPreambleOnlyConfigDoesNotCrash() {
        let store = makeStore(Self.globalsOnly)
        let count = store.importHosts(fromText: "Host beta\n    HostName b\n")
        #expect(count == 1)
        #expect(store.documents[0].blocks.count == 1)
        let out = SSHConfigSerializer.serialize(store.documents[0])
        #expect(out.contains("ServerAliveInterval 60"))
        #expect(out.contains("Host beta"))
    }

    @Test func createConfigBlockOnPreambleOnlyConfigDoesNotCrash() {
        let store = makeStore(Self.globalsOnly)
        let id = store.createConfigBlock(forKnownHost: "b.example.com", alias: "beta")
        #expect(id != nil)
        #expect(store.documents[0].blocks.count == 1)
        #expect(store.documents[0].blocks[0].firstValue(for: "HostName") == "b.example.com")
    }
}
