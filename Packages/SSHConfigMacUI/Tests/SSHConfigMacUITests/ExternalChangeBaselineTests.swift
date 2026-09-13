//
//  ExternalChangeBaselineTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for bug #4 in docs/macos-prerelease-bug-audit.md:
//  writeDirtyDocuments() re-baselined the mtime of EVERY document, not just the
//  files it actually wrote. So if an external tool edited an Include'd file while a
//  different file was dirty in-app, the autosave folded that file's new mtime into
//  the baseline — the external change was then never detected and a later in-app
//  edit overwrote it. The fix re-baselines only written/deleted URLs.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
struct ExternalChangeBaselineTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scm-extchg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func autosaveOffStore() -> ConfigStore {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        return ConfigStore(settings: settings)
    }

    @Test func autosaveDoesNotAbsorbExternalEditToUntouchedInclude() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config")
        let workURL = dir.appendingPathComponent("work.conf")
        try write("Include work.conf\n\nHost main\n    HostName m\n", to: configURL)
        try write("Host prod\n    HostName db\n", to: workURL)

        let store = autosaveOffStore()
        await store.waitForGroupsLoadedForTesting()
        store.useDirectoryForTesting(dir)
        store.reload() // baselines both config and work.conf

        // Dirty the MAIN config only; work.conf is never touched in-app.
        store.addHost(to: configURL)
        #expect(store.isDirty)

        // An external tool edits work.conf, pushing its mtime forward so the change is
        // unambiguous regardless of filesystem mtime granularity.
        try write("Host prod\n    HostName db\n\nHost extra\n    HostName x\n", to: workURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: workURL.path)

        // Autosave writes ONLY the dirty main config.
        store.flushPendingSave()
        #expect(!store.isDirty)

        // The external edit to work.conf must still be detectable — the save must not
        // have re-baselined work.conf's mtime. (Before the fix this returned false.)
        #expect(store.checkForExternalChanges() == true)
    }
}
