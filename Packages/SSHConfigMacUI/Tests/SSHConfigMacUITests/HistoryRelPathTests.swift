//
//  HistoryRelPathTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for bug #5 in docs/macos-prerelease-bug-audit.md:
//  a file-backed group living in a user-picked directory OUTSIDE ~/.ssh was keyed
//  in version history by its bare last path component. url(forRelPath:) then always
//  resolved that back INTO ~/.ssh, so on restore the group file's contents were
//  written to ~/.ssh/<name> — and a custom file named "config" collided with the
//  main config's key and could overwrite ~/.ssh/config itself.
//
//  The fix keys outside-files by their absolute path, so keys never collide and
//  round-trip back to the real location.
//

import Foundation
import Testing

@testable import SSHConfigMacUI

@MainActor
struct HistoryRelPathTests {
    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scm-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The dangerous case: a custom-directory group file named exactly `config`.
    @Test func customDirectoryConfigDoesNotCollideWithMainConfig() throws {
        let sshDir = try makeTempDir("ssh")
        let customDir = try makeTempDir("custom")
        defer {
            try? FileManager.default.removeItem(at: sshDir)
            try? FileManager.default.removeItem(at: customDir)
        }
        let store = ConfigStore(settings: AppSettings(database: nil))
        store.useDirectoryForTesting(sshDir)

        let mainURL = sshDir.appendingPathComponent("config")
        let customURL = customDir.appendingPathComponent("config") // same basename!

        let relMain = store.relPath(for: mainURL)
        let relCustom = store.relPath(for: customURL)

        // Distinct keys: no collision (before the fix both were "config").
        #expect(relMain != relCustom)
        #expect(relMain == "config")

        // Each key round-trips back to its OWN file, not into ~/.ssh.
        #expect(
            store.url(forRelPath: relMain)?.standardizedFileURL.path
                == mainURL.standardizedFileURL.path)
        #expect(
            store.url(forRelPath: relCustom)?.standardizedFileURL.path
                == customURL.standardizedFileURL.path)
    }

    /// Files genuinely inside ~/.ssh (incl. subdirectories) still use relative keys.
    @Test func insideSshDirectoryStillUsesRelativeKeys() throws {
        let sshDir = try makeTempDir("ssh")
        defer { try? FileManager.default.removeItem(at: sshDir) }
        let store = ConfigStore(settings: AppSettings(database: nil))
        store.useDirectoryForTesting(sshDir)

        let nested = sshDir.appendingPathComponent("conf.d/work.conf")
        let rel = store.relPath(for: nested)
        #expect(rel == "conf.d/work.conf")
        #expect(
            store.url(forRelPath: rel)?.standardizedFileURL.path
                == nested.standardizedFileURL.path)
    }
}
