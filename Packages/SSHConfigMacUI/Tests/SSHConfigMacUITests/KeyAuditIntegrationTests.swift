//
//  KeyAuditIntegrationTests.swift
//  sshconfigmanagerTests
//
//  End-to-end key health audit against a real temp ~/.ssh through ConfigStore's
//  test seam: discovery → findings → the one-click permission fix and the
//  orphaned-key delete actually touch the filesystem (chmod, backup, remove) and
//  the audit recomputes. This covers the file operations behind the Issues-view
//  buttons so only the SwiftUI presentation itself is left to the render suite.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
struct KeyAuditIntegrationTests {
    private func makeSSHDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshaudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Tighten the folder itself so it doesn't add its own "loose folder" finding.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    private func mode(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions])
            as? NSNumber)?.intValue ?? -1
    }

    /// The discovered key's private-key path — the canonical form (symlink-resolved by
    /// `contentsOfDirectory`) that findings carry, which may differ from a hand-built
    /// `/var` vs `/private/var` temp path.
    private func discoveredPath(_ store: ConfigStore, _ name: String) -> String {
        store.publicKeys.first { $0.name == name }?.privateKeyURL?.path ?? ""
    }

    /// A store granted access to `dir`, with the config loaded and audited.
    private func store(for dir: URL) -> ConfigStore {
        let store = ConfigStore(settings: AppSettings(database: nil))
        store.useDirectoryForTesting(dir)
        store.reload()
        return store
    }

    /// Writes a loose-permission (0644), unreferenced private key — an orphaned key
    /// with a permission problem — and returns its URL.
    private func writeOrphanKey(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Detection from real files

    @Test func discoversOrphanedKeyAndLoosePermissions() throws {
        let dir = try makeSSHDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Host web\n    HostName web.example.com\n".write(
            to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        _ = try writeOrphanKey(named: "deploykey", in: dir)

        let store = store(for: dir)
        let path = discoveredPath(store, "deploykey")

        let fixes = store.keyFindings.compactMap(\.fix)
        #expect(fixes.contains(.setPermissions(path: path, mode: 0o600, label: "Fix to 0600")))
        #expect(
            fixes.contains(
                .deleteOrphanedKey(
                    privateKeyPath: path, publicKeyPath: nil, name: "deploykey")))
    }

    // MARK: - The permission fix actually chmods + re-audits

    @Test func applyingPermissionFixChmodsAndClearsTheFinding() throws {
        let dir = try makeSSHDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeOrphanKey(named: "deploykey", in: dir)
        let store = store(for: dir)
        let path = discoveredPath(store, "deploykey")

        let permFix = LintFix.setPermissions(path: path, mode: 0o600, label: "Fix to 0600")
        #expect(store.keyFindings.compactMap(\.fix).contains(permFix))

        store.applyFix(permFix)

        #expect(mode(of: URL(fileURLWithPath: path)) & 0o777 == 0o600) // really chmod'd on disk
        #expect(!store.keyFindings.compactMap(\.fix).contains(permFix)) // finding cleared
    }

    // MARK: - The orphaned delete actually backs up + removes + re-audits

    @Test func deletingOrphanedKeyBacksUpRemovesAndClearsTheFinding() throws {
        let dir = try makeSSHDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try writeOrphanKey(named: "deploykey", in: dir)
        let store = store(for: dir)
        #expect(store.publicKeys.contains { $0.name == "deploykey" })

        store.deleteOrphanedKey(privateKeyPath: key.path, publicKeyPath: nil)

        #expect(!FileManager.default.fileExists(atPath: key.path)) // removed
        #expect(!store.publicKeys.contains { $0.name == "deploykey" }) // gone from list
        #expect(
            !store.keyFindings.contains { // finding cleared
                if case .deleteOrphanedKey = $0.fix { return true } else { return false }
            })

        // A recoverable backup was written first.
        let backupDir = dir.appendingPathComponent(".sshmanager-backups", isDirectory: true)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []
        #expect(backups.contains { $0.hasPrefix("deploykey.") && $0.hasSuffix(".bak") })
    }

    // MARK: - UI-test fixture seam

    /// The app-seeded UI-test fixture must produce exactly the findings the XCUITests
    /// drive: a permission fix, an orphaned-key delete, and a generate-replacement.
    @Test func uiTestSeedProducesTheExpectedFindings() throws {
        let dir = try makeSSHDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ConfigStore.seedUITestSSHDirectory(in: dir)

        // Files exist with the intended permissions.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("config").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("weakrsa.pub").path))
        #expect(mode(of: dir.appendingPathComponent("orphan")) & 0o777 == 0o644)

        let store = store(for: dir)
        let fixes = store.keyFindings.compactMap(\.fix)
        func has(_ match: (LintFix) -> Bool) -> Bool { fixes.contains(where: match) }
        #expect(has { if case .setPermissions = $0 { return true } else { return false } })
        #expect(has { if case .deleteOrphanedKey = $0 { return true } else { return false } })
        #expect(has { if case .generateReplacement = $0 { return true } else { return false } })
    }

    // MARK: - Generate-replacement deep-link contract

    @Test func generatedReplacementKeepsTheOriginalComment() throws {
        let dir = try makeSSHDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "".write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let store = store(for: dir)

        // Mirrors what the deep-link does: the prefilled comment flows into createKey.
        let request = ConfigStore.KeyGenerationRequest(comment: "legacy@host")
        let created = try store.createKey(
            algorithm: .ed25519, fileName: "id_ed25519_new",
            comment: request.comment, passphrase: nil)

        #expect(created.comment == "legacy@host")
        #expect(created.algorithm == "ssh-ed25519")
    }
}
