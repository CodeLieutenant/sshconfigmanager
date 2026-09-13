//
//  SSHFileAccessExtraTests.swift
//  sshconfigmanagerTests
//
//  Covers the parts of SSHFileAccess that FileAccessTests doesn't: the backup
//  listing/reading API, revoke, the URL accessors, `?`-glob matching, and the
//  no-directory error paths. The security-scoped bookmark / open-panel flow needs
//  real UI and is out of scope for unit tests.
//

import Foundation
import Testing

@testable import SSHConfigMacUI

@MainActor
struct SSHFileAccessExtraTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshextra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func access(_ dir: URL) -> SSHFileAccess {
        let fa = SSHFileAccess()
        fa.useDirectoryForTesting(dir)
        return fa
    }

    @Test func urlAccessorsTrackGrantedDirectory() throws {
        let fa = SSHFileAccess()
        #expect(!fa.hasAccess)
        #expect(fa.configURL == nil)
        #expect(fa.knownHostsURL == nil)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        fa.useDirectoryForTesting(dir)
        #expect(fa.hasAccess)
        #expect(fa.configURL?.lastPathComponent == "config")
        #expect(fa.knownHostsURL?.lastPathComponent == "known_hosts")
    }

    @Test func backupsAreListedNewestFirstAndReadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let url = dir.appendingPathComponent("config")

        // Three successive writes-with-backup create backups of the prior contents.
        try fa.writeText("v1\n", to: url, makeBackup: false)
        try fa.writeText("v2\n", to: url, makeBackup: true) // backs up v1
        // The backup name embeds a 1-second-resolution timestamp; space the writes
        // so the two backups get distinct names rather than colliding.
        Thread.sleep(forTimeInterval: 1.1)
        try fa.writeText("v3\n", to: url, makeBackup: true) // backs up v2

        let backups = fa.backups(forFileNamed: "config")
        #expect(backups.count == 2)
        #expect(backups.allSatisfy { $0.originalName == "config" })
        // Newest first.
        #expect(backups[0].date >= backups[1].date)
        // The newest backup holds the most recently overwritten contents (v2).
        #expect(try fa.readBackup(backups[0]) == "v2\n")
        #expect(try fa.readBackup(backups[1]) == "v1\n")
    }

    @Test func backupsForUnknownFileAreEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        try fa.writeText("x\n", to: dir.appendingPathComponent("config"), makeBackup: false)
        #expect(fa.backups(forFileNamed: "known_hosts").isEmpty) // no backups for it
    }

    @Test func questionMarkGlobMatchesSingleCharacter() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        try fa.writeText("a\n", to: dir.appendingPathComponent("host1.conf"), makeBackup: false)
        try fa.writeText("b\n", to: dir.appendingPathComponent("host2.conf"), makeBackup: false)
        try fa.writeText("c\n", to: dir.appendingPathComponent("host10.conf"), makeBackup: false)

        let names = fa.resolveIncludes("host?.conf").map(\.lastPathComponent).sorted()
        #expect(names == ["host1.conf", "host2.conf"]) // host10 has two digits → excluded
    }

    @Test func readTextOfMissingFileReturnsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        #expect(try fa.readText(at: dir.appendingPathComponent("nope")) == "")
    }

    @Test func revokeClearsAccess() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        #expect(fa.hasAccess)
        fa.revokeAccess()
        #expect(!fa.hasAccess)
        #expect(fa.directoryURL == nil)
    }

    @Test func operationsWithoutADirectoryThrowOrReturnEmpty() {
        let fa = SSHFileAccess() // no directory granted
        #expect(throws: SSHFileAccessError.self) { try fa.directoryFiles() }
        #expect(throws: SSHFileAccessError.self) {
            try fa.readText(at: URL(fileURLWithPath: "/tmp/anything"))
        }
        #expect(fa.resolveIncludes("conf.d/*.conf").isEmpty)
        #expect(fa.backups(forFileNamed: "config").isEmpty)
    }

    @Test func restoreAccessWithoutBookmarkReturnsFalse() {
        UserDefaults.standard.removeObject(forKey: "sshDirectoryBookmark")
        let fa = SSHFileAccess()
        #expect(fa.restoreAccess() == false)
        #expect(!fa.hasAccess)
    }

    @Test func permissionsRoundTripThroughChmod() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let key = dir.appendingPathComponent("id_test")
        try fa.writeText("secret", to: key, makeBackup: false, permissions: 0o644)
        #expect(try fa.permissions(of: key) & 0o777 == 0o644)

        try fa.setPermissions(0o600, on: key)
        #expect(try fa.permissions(of: key) & 0o777 == 0o600)
    }

    @Test func deleteFileBacksUpThenRemoves() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let key = dir.appendingPathComponent("orphan")
        try fa.writeText("private-key-bytes", to: key, makeBackup: false)

        try fa.deleteFile(at: key, makeBackup: true)
        #expect(!FileManager.default.fileExists(atPath: key.path))
        // The backup is recoverable.
        let backups = fa.backups(forFileNamed: "orphan")
        #expect(backups.count == 1)
        #expect(try fa.readBackup(backups[0]) == "private-key-bytes")
    }

    @Test func permissionAndDeleteRejectPathsOutsideGrant() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let outside = URL(fileURLWithPath: "/tmp/not-in-grant-\(UUID().uuidString)")
        #expect(throws: SSHFileAccessError.self) { try fa.permissions(of: outside) }
        #expect(throws: SSHFileAccessError.self) { try fa.setPermissions(0o600, on: outside) }
        #expect(throws: SSHFileAccessError.self) { try fa.deleteFile(at: outside, makeBackup: false) }
    }
}
