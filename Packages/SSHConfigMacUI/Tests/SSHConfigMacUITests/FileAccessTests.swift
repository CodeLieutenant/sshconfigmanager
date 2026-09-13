//
//  FileAccessTests.swift
//  sshconfigmanagerTests
//
//  Exercises SSHFileAccess against a real temporary directory (via the test seam):
//  atomic writes, 0600 permissions, backups, directory listing, and Include/glob
//  resolution with out-of-directory rejection.
//

import Foundation
import Testing

@testable import SSHConfigMacUI

@MainActor
struct FileAccessTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func access(_ dir: URL) -> SSHFileAccess {
        let fa = SSHFileAccess()
        fa.useDirectoryForTesting(dir)
        return fa
    }

    @Test func writesAtomicallyWith0600Permissions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let url = dir.appendingPathComponent("config")

        try fa.writeText("Host a\n", to: url, makeBackup: false)

        #expect(try fa.readText(at: url) == "Host a\n")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    /// Regression guard for audit #6: `writeRegularFile` now `F_FULLFSYNC`s the
    /// temp file (and the containing directory) before/after publishing it —
    /// this can't observe durability across a simulated power loss in a unit
    /// test, but it can and must confirm the extra syscalls don't break the
    /// write itself, on both the create path and the overwrite (`replaceItemAt`)
    /// path.
    @Test func writeSucceedsOnCreateAndOverwriteWithFsyncEnabled() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let url = dir.appendingPathComponent("config")

        try fa.writeText("Host a\n", to: url, makeBackup: false)
        #expect(try fa.readText(at: url) == "Host a\n")

        try fa.writeText("Host b\n", to: url, makeBackup: false)
        #expect(try fa.readText(at: url) == "Host b\n")

        // No stray `.tmp-*` files left behind by the fsync step.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".") && $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func backsUpExistingFileBeforeOverwriting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let url = dir.appendingPathComponent("config")

        try fa.writeText("old contents\n", to: url, makeBackup: false)
        try fa.writeText("new contents\n", to: url, makeBackup: true)

        #expect(try fa.readText(at: url) == "new contents\n")
        let backupsDir = dir.appendingPathComponent(".sshmanager-backups")
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        #expect(backups.count == 1)
        let backupContent = try String(
            contentsOf: backupsDir.appendingPathComponent(backups[0]), encoding: .utf8)
        #expect(backupContent == "old contents\n")
    }

    @Test func directoryFilesListsRegularFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        try fa.writeText("Host a\n", to: dir.appendingPathComponent("config"), makeBackup: false)
        try fa.writeText("ssh-ed25519 AAAA x\n", to: dir.appendingPathComponent("id.pub"), makeBackup: false)

        let names = try fa.directoryFiles().map(\.lastPathComponent)
        #expect(names.contains("config"))
        #expect(names.contains("id.pub"))
    }

    @Test func resolveIncludesExpandsGlobsWithinDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let confd = dir.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: confd, withIntermediateDirectories: true)
        try fa.writeText("Host a\n", to: confd.appendingPathComponent("a.conf"), makeBackup: false)
        try fa.writeText("Host b\n", to: confd.appendingPathComponent("b.conf"), makeBackup: false)
        try fa.writeText("ignore\n", to: confd.appendingPathComponent("notes.txt"), makeBackup: false)

        let names = fa.resolveIncludes("conf.d/*.conf").map(\.lastPathComponent)
        #expect(names == ["a.conf", "b.conf"])
    }

    @Test func resolveIncludesHandlesMultipleTokens() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let confd = dir.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: confd, withIntermediateDirectories: true)
        try fa.writeText("Host x\n", to: dir.appendingPathComponent("extra.conf"), makeBackup: false)
        try fa.writeText("Host y\n", to: confd.appendingPathComponent("y.conf"), makeBackup: false)

        let names = fa.resolveIncludes("extra.conf conf.d/y.conf").map(\.lastPathComponent)
        #expect(Set(names) == ["extra.conf", "y.conf"])
    }

    @Test func resolveIncludesRejectsPathsOutsideGrantedDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        #expect(fa.resolveIncludes("/etc/ssh/ssh_config").isEmpty)
    }

    @Test func resolveIncludesExpandsTildeToRealHome() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        // Write a file inside the temp dir and synthesise a tilde-prefixed path that
        // points to it via the real home. We can't use the actual ~/.ssh here, so
        // verify the negative: a tilde path that resolves OUTSIDE the granted dir
        // (the normal case for non-.ssh directories) must still be rejected, while a
        // relative path for the same file is accepted.
        try fa.writeText("Host x\n", to: dir.appendingPathComponent("x.conf"), makeBackup: false)

        // Relative path → inside granted dir → resolved.
        #expect(fa.resolveIncludes("x.conf").count == 1)

        // A `~/`-prefixed path whose real-home expansion lands outside the temp dir
        // must be rejected by ensureInsideGrantedDirectory, not crash.
        let tildePattern = "~/.ssh/x.conf"
        let resolved = fa.resolveIncludes(tildePattern)
        // The real ~/.ssh dir is not the temp dir, so this either resolves to [] (file
        // doesn't exist there) or is rejected by the grant check — both are correct.
        let realSSH = SSHFileAccess.realHomeDirectory.appendingPathComponent(".ssh/x.conf")
        let existsInRealSSH = FileManager.default.fileExists(atPath: realSSH.path)
        if !existsInRealSSH {
            #expect(resolved.isEmpty, "tilde path outside granted dir must not resolve")
        }
        // The key invariant: the function must NOT expand `~` to the sandbox container.
        let containerHome = FileManager.default.homeDirectoryForCurrentUser.path
        let realHome = SSHFileAccess.realHomeDirectory.path
        if containerHome != realHome {
            // Confirm the tilde was expanded using the real home, not the container.
            let containerPath = containerHome + "/.ssh/x.conf"
            #expect(
                !fa.resolveIncludes("~/.ssh/x.conf")
                    .contains(where: { $0.path == containerPath }),
                "tilde must expand to real home, not sandbox container")
        }
    }

    @Test func resolveIncludesSkipsHiddenFilesAndDirectories() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let confd = dir.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: confd, withIntermediateDirectories: true)
        try fa.writeText("Host a\n", to: confd.appendingPathComponent("a.conf"), makeBackup: false)
        // Hidden file — should be skipped (matches `*` only with FNM_PERIOD disabled).
        try "DS_Store data".write(
            to: confd.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        // Subdirectory — should be skipped (not a regular file).
        try FileManager.default.createDirectory(
            at: confd.appendingPathComponent("subdir"), withIntermediateDirectories: true)

        let names = fa.resolveIncludes("conf.d/*").map(\.lastPathComponent)
        #expect(names == ["a.conf"], "hidden files and directories must not be included")
    }

    /// Reproduces the reported `Include ~/.ssh/config.d/*.conf` bug: a matched
    /// entry that is a symlink to a regular file elsewhere in the granted
    /// directory must be included — `isRegularFileKey` is false on the symlink
    /// itself, and filtering on it made the file (and its whole group) vanish.
    @Test func resolveIncludesFollowsSymlinkedFilesWithinGrant() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let confd = dir.appendingPathComponent("config.d")
        try FileManager.default.createDirectory(at: confd, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("real-target.txt")
        try fa.writeText("Host database\n", to: real, makeBackup: false)
        try FileManager.default.createSymbolicLink(
            at: confd.appendingPathComponent("database.conf"), withDestinationURL: real)

        let names = fa.resolveIncludes("config.d/*.conf").map(\.lastPathComponent)
        #expect(names == ["database.conf"], "a symlink to an in-grant regular file must resolve")
    }

    /// A glob-matched symlink whose target lies outside every granted root must
    /// be reported via `onSymlinkEscape` (feeding the grant-access flow), not
    /// silently dropped like the plain not-a-regular-file case.
    @Test func resolveIncludesReportsGlobMatchedSymlinkEscapingGrant() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let fa = access(dir)
        let confd = dir.appendingPathComponent("config.d")
        try FileManager.default.createDirectory(at: confd, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("ssh_config")
        try "Host dotfiles\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: confd.appendingPathComponent("work.conf"), withDestinationURL: target)

        var escapes: [(source: URL, target: URL)] = []
        let resolved = fa.resolveIncludes("config.d/*.conf") { escapes.append(($0, $1)) }

        #expect(resolved.isEmpty)
        #expect(escapes.count == 1)
        #expect(escapes.first?.source.lastPathComponent == "work.conf")
        #expect(escapes.first?.target.standardizedFileURL.path == target.standardizedFileURL.path)
    }

    /// Same two cases for a literal (non-glob) Include of a symlinked file.
    @Test func resolveIncludesFollowsLiteralSymlinkWithinGrant() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let real = dir.appendingPathComponent("real-target.txt")
        try fa.writeText("Host a\n", to: real, makeBackup: false)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("extra.conf"), withDestinationURL: real)

        #expect(fa.resolveIncludes("extra.conf").map(\.lastPathComponent) == ["extra.conf"])
    }

    @Test func resolveIncludesReportsLiteralSymlinkEscapingGrant() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        let fa = access(dir)
        let target = outside.appendingPathComponent("ssh_config")
        try "Host dotfiles\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("extra.conf"), withDestinationURL: target)

        var escapes: [(source: URL, target: URL)] = []
        let resolved = fa.resolveIncludes("extra.conf") { escapes.append(($0, $1)) }

        #expect(resolved.isEmpty)
        #expect(escapes.count == 1)
        #expect(escapes.first?.target.standardizedFileURL.path == target.standardizedFileURL.path)
    }

    @Test func writingOutsideGrantedDirectoryThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fa = access(dir)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)")
        #expect(throws: SSHFileAccessError.self) {
            try fa.writeText("x\n", to: outside, makeBackup: false)
        }
    }

    // MARK: - Symlinks escaping the granted directory (dotfiles-managed configs)

    /// Reproduces the real-world case: `~/.ssh/config` is a symlink into a dotfiles
    /// repo the sandbox has no bookmark for. The symlink itself lives inside the
    /// granted dir (so `ensureInsideGrantedDirectory` alone doesn't catch it), but
    /// its resolved target does not — reads must fail with a named, actionable error.
    @Test func readingThroughSymlinkOutsideGrantedDirectoryThrowsNamedError() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outsideDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let realConfig = outsideDir.appendingPathComponent("config")
        try "Host real\n".write(to: realConfig, atomically: true, encoding: .utf8)

        let fa = access(dir)
        let symlink = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realConfig)

        #expect(throws: SSHFileAccessError.self) {
            _ = try fa.readText(at: symlink)
        }
        do {
            _ = try fa.readText(at: symlink)
            Issue.record("expected readText to throw")
        } catch let error as SSHFileAccessError {
            guard case .symlinkOutsideGrantedDirectory(let source, let target) = error else {
                Issue.record("expected .symlinkOutsideGrantedDirectory, got \(error)")
                return
            }
            #expect(source.lastPathComponent == "config")
            #expect(target.standardizedFileURL.path == realConfig.standardizedFileURL.path)
        }
    }

    /// Writing through the same symlink must fail up front, before any temp file is
    /// created — otherwise a `.config.tmp-*` file is left behind on every attempt
    /// (the failure mode observed in production before this check was added).
    @Test func writingThroughSymlinkOutsideGrantedDirectoryThrowsWithoutLeavingTempFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outsideDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let realConfig = outsideDir.appendingPathComponent("config")
        try "Host real\n".write(to: realConfig, atomically: true, encoding: .utf8)

        let fa = access(dir)
        let symlink = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realConfig)

        #expect(throws: SSHFileAccessError.self) {
            try fa.writeText("Include config.d/*\n", to: symlink, makeBackup: false)
        }
        let leftoverTempFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".config.tmp-") }
        #expect(leftoverTempFiles.isEmpty, "writeText must not leave temp files behind on a symlink escape")
    }

    /// Once the target directory is separately granted (the "Grant Access" fix
    /// flow), reads through the same symlink must succeed.
    @Test func readingThroughSymlinkSucceedsAfterAdditionalDirectoryIsGranted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outsideDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let realConfig = outsideDir.appendingPathComponent("config")
        try "Host real\n".write(to: realConfig, atomically: true, encoding: .utf8)

        let fa = access(dir)
        let symlink = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realConfig)

        fa.useAdditionalDirectoryForTesting(outsideDir)

        #expect(try fa.readText(at: symlink) == "Host real\n")
    }

    /// Reproduces the actual production bug: once the target directory is granted,
    /// reads through the symlink already worked (see above) but *writes* still
    /// failed — `replaceItemAt` was called with the symlink's own path as the
    /// destination, which doesn't follow it, silently either failing or replacing
    /// the symlink itself. The write must land on the resolved target's real file,
    /// leave the symlink itself untouched, and not leave a `.tmp-*` file behind.
    @Test func writingThroughSymlinkSucceedsAfterAdditionalDirectoryIsGranted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outsideDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let realConfig = outsideDir.appendingPathComponent("config")
        try "Host real\n".write(to: realConfig, atomically: true, encoding: .utf8)

        let fa = access(dir)
        let symlink = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realConfig)
        fa.useAdditionalDirectoryForTesting(outsideDir)

        try fa.writeText("Host updated\n", to: symlink, makeBackup: false)

        #expect(
            try String(contentsOf: realConfig, encoding: .utf8) == "Host updated\n",
            "the write must land on the resolved target")
        var isSymlink: Bool {
            (try? FileManager.default
                .destinationOfSymbolicLink(atPath: symlink.path)) != nil
        }
        #expect(isSymlink, "the symlink itself must survive the write, not get replaced by a plain file")
        let leftoverInSymlinkDir = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".config.tmp-") }
        let leftoverInTargetDir = try FileManager.default.contentsOfDirectory(atPath: outsideDir.path)
            .filter { $0.hasPrefix(".config.tmp-") }
        #expect(
            leftoverInSymlinkDir.isEmpty && leftoverInTargetDir.isEmpty,
            "no temp-file debris should be left behind on a successful write")
    }

    /// Reproduces the directory variant: `Include ~/.ssh/conf.d/*` where `conf.d`
    /// itself is a symlink into a dotfiles repo, not an individual file. Before this
    /// was fixed, `matchGlob` enumerated through `try?` and silently returned no
    /// files — every host in the directory vanished with no error at all.
    @Test func resolveIncludesReportsSymlinkedDirectoryEscapeInsteadOfSilentlyDroppingIt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outsideDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        try "Host real\n".write(to: outsideDir.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)

        let fa = access(dir)
        let confD = dir.appendingPathComponent("conf.d")
        try FileManager.default.createSymbolicLink(at: confD, withDestinationURL: outsideDir)

        var escapes: [(source: URL, target: URL)] = []
        let resolved = fa.resolveIncludes("conf.d/*") { source, target in escapes.append((source, target)) }

        #expect(resolved.isEmpty)
        #expect(escapes.count == 1)
        #expect(escapes.first?.source.lastPathComponent == "conf.d")
        #expect(escapes.first?.target.standardizedFileURL.path == outsideDir.standardizedFileURL.path)
    }

    /// Once the directory's real target is granted, the glob resolves normally.
    @Test func resolveIncludesResolvesSymlinkedDirectoryAfterAdditionalDirectoryIsGranted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outsideDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        try "Host real\n".write(to: outsideDir.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)

        let fa = access(dir)
        let confD = dir.appendingPathComponent("conf.d")
        try FileManager.default.createSymbolicLink(at: confD, withDestinationURL: outsideDir)
        fa.useAdditionalDirectoryForTesting(outsideDir)

        let resolved = fa.resolveIncludes("conf.d/*")

        #expect(resolved.map(\.lastPathComponent) == ["a.conf"])
    }
}
