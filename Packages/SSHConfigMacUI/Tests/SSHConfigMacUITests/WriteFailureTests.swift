//
//  WriteFailureTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for bug #7 in docs/macos-prerelease-bug-audit.md:
//  writeDirtyDocuments() advanced lastSavedDate and recorded a history version
//  unconditionally, even when every disk write threw — claiming a save that never
//  happened and snapshotting an in-memory state that never reached disk.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
struct WriteFailureTests {
    @Test func failedWriteDoesNotClaimASave() {
        let settings = AppSettings(database: nil)
        settings.autosaveEnabled = false
        let store = ConfigStore(settings: settings)
        // No useDirectoryForTesting → no write grant, so every writeText throws.
        let url = URL(fileURLWithPath: "/nonexistent-ungranted-dir-\(UUID().uuidString)/config")
        store.loadForTesting([SSHConfigParser.parse("Host a\n    HostName x\n", sourceURL: url)])

        store.addHost() // makes the document dirty
        #expect(store.isDirty)
        let before = store.lastSavedDate // nil on a fresh store

        store.flushPendingSave() // all writes fail (ungranted path)

        #expect(store.isDirty, "a failed write must leave the document dirty for retry")
        #expect(store.lastSavedDate == before, "a failed write must not advance lastSavedDate")
    }
}
