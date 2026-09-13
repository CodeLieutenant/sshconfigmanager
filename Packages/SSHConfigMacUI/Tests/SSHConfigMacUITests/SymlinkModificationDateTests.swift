//
//  SymlinkModificationDateTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for bug #3 in docs/macos-prerelease-bug-audit.md:
//  ConfigStore.modificationDate(of:) used FileManager.attributesOfItem, which does
//  not follow the final symlink. A dotfiles-managed ~/.ssh/config is often a symlink,
//  so external edits (which change the *target's* mtime) were never detected and the
//  next in-app save overwrote them. The fix resolves symlinks before stat-ing.
//

import Foundation
import Testing

@testable import SSHConfigMacUI

@MainActor
struct SymlinkModificationDateTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scm-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func modificationDateFollowsSymlinkToTarget() throws {
        let fm = FileManager.default
        let dir = try tempDir()
        defer { try? fm.removeItem(at: dir) }

        let target = dir.appendingPathComponent("real_config")
        let link = dir.appendingPathComponent("config") // symlink → real_config
        try "Host a\n".write(to: target, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        // Stamp the TARGET's mtime to a fixed, distinctive date well in the past, so a
        // value near "now" (which is what the link node's own mtime would read) is an
        // unmistakable failure.
        let stamp = Date(timeIntervalSince1970: 1_600_000_000) // 2020-09-13
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: target.path)

        let store = ConfigStore(settings: AppSettings(database: nil))
        // Reading through the symlink must reflect the target's mtime. Before the fix
        // this returned the link node's creation mtime (≈ now), so external edits to
        // the target were invisible to change detection.
        let viaLink = try #require(store.modificationDate(of: link))
        #expect(abs(viaLink.timeIntervalSince(stamp)) < 1.0)
    }

    @Test func modificationDateStillWorksForPlainFile() throws {
        let fm = FileManager.default
        let dir = try tempDir()
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("config")
        try "Host a\n".write(to: file, atomically: true, encoding: .utf8)
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)

        let store = ConfigStore(settings: AppSettings(database: nil))
        let mtime = try #require(store.modificationDate(of: file))
        #expect(abs(mtime.timeIntervalSince(stamp)) < 1.0)
    }
}
