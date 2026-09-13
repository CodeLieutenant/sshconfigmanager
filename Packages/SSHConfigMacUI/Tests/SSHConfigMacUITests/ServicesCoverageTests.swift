//
//  ServicesCoverageTests.swift
//  sshconfigmanagerTests
//
//  Fills coverage gaps in the testable (non-UI, non-agent-socket) parts of the
//  Services/State layer: key generation across algorithms, error descriptions,
//  the private-key-encryption sniffer, and the store's fix dispatch.
//

import Foundation
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

struct KeyGeneratorCoverageTests {

    @Test func keyAlgorithmMetadata() {
        for algo in KeyAlgorithm.allCases {
            #expect(algo.id == algo)
            #expect(!algo.displayName.isEmpty)
            #expect(algo.defaultFileName.hasPrefix("id_"))
        }
    }

    /// Generating each algorithm exercises every `makeMaterial(for:)` branch and
    /// proves the emitted key parses back to the expected type.
    @Test(arguments: [
        (KeyAlgorithm.ed25519, "ssh-ed25519"),
        (.ecdsaP256, "ecdsa-sha2-nistp256"),
        (.ecdsaP384, "ecdsa-sha2-nistp384"),
        (.ecdsaP521, "ecdsa-sha2-nistp521"),
    ])
    func generatesEachAlgorithm(algo: KeyAlgorithm, expectedType: String) throws {
        let generated = try SSHKeyGenerator.generate(algorithm: algo, comment: "c@h", passphrase: nil)
        let parsed = try OpenSSHPrivateKey.parse(pem: generated.privateKeyPEM)
        #expect(parsed.keyType == expectedType)
        #expect(generated.publicKeyText.hasPrefix(expectedType))
    }
}

struct PrivateKeyEncryptionSnifferTests {
    @Test func detectsEachFormat() {
        // Classic PEM with the encryption header.
        #expect(
            SSHKeyService.privateKeyEncrypted(
                pem: "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n...\n") == true)
        // Plain classic PEM private key.
        #expect(
            SSHKeyService.privateKeyEncrypted(
                pem: "-----BEGIN RSA PRIVATE KEY-----\nMIIxxx\n-----END RSA PRIVATE KEY-----") == false)
        // Not a private key at all → unknown.
        #expect(SSHKeyService.privateKeyEncrypted(pem: "just some text") == nil)
        // A real unencrypted OpenSSH key reports false.
        let generated = try? SSHKeyGenerator.generate(algorithm: .ed25519, comment: "", passphrase: nil)
        #expect(SSHKeyService.privateKeyEncrypted(pem: generated?.privateKeyPEM ?? "") == false)
        // A real encrypted OpenSSH key reports true.
        let enc = try? SSHKeyGenerator.generate(algorithm: .ed25519, comment: "", passphrase: "pw")
        #expect(SSHKeyService.privateKeyEncrypted(pem: enc?.privateKeyPEM ?? "") == true)
    }
}

@MainActor
struct FileAccessErrorCoverageTests {
    @Test func errorDescriptionsAndAccessors() {
        let errors: [SSHFileAccessError] = [
            .accessDenied, .noDirectory,
            .outsideGrantedDirectory(URL(fileURLWithPath: "/tmp/x")),
            .fileTooLarge(URL(fileURLWithPath: "/tmp/big")),
        ]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }

        #expect(SSHFileAccess.defaultSSHDirectory.lastPathComponent == ".ssh")
    }

    @Test func backupInfoEquatable() {
        let url = URL(fileURLWithPath: "/tmp/.sshmanager-backups/config.20260101-000000.bak")
        let a = SSHFileAccess.BackupInfo(url: url, originalName: "config", date: Date(timeIntervalSince1970: 0))
        let b = SSHFileAccess.BackupInfo(url: url, originalName: "config", date: Date(timeIntervalSince1970: 999))
        #expect(a == b) // equality is by URL
    }
}

@MainActor
struct StoreFixDispatchCoverageTests {
    private func makeSSHDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    @Test func applyFixIgnoresNonPermissionFixes() throws {
        let dir = try makeSSHDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(settings: AppSettings(database: nil))
        store.useDirectoryForTesting(dir)
        store.reload()
        // Non-permission fixes are UI-driven; applyFix must no-op (guard else) with no error.
        store.applyFix(.deleteOrphanedKey(privateKeyPath: "/x", publicKeyPath: nil, name: "x"))
        store.applyFix(.generateReplacement(comment: "c", originalName: "x"))
        #expect(store.errorMessage == nil)
    }

    @Test func deleteOrphanedKeyRemovesBothHalves() throws {
        let dir = try makeSSHDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let priv = dir.appendingPathComponent("extra")
        let pub = dir.appendingPathComponent("extra.pub")
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
            .write(to: priv, atomically: true, encoding: .utf8)
        try "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa x@y\n"
            .write(to: pub, atomically: true, encoding: .utf8)

        let store = ConfigStore(settings: AppSettings(database: nil))
        store.useDirectoryForTesting(dir)
        store.reload()

        store.deleteOrphanedKey(privateKeyPath: priv.path, publicKeyPath: pub.path)
        #expect(!FileManager.default.fileExists(atPath: priv.path))
        #expect(!FileManager.default.fileExists(atPath: pub.path))
        #expect(store.errorMessage == nil)
    }

    @Test func agentAddErrorDescriptions() {
        #expect(ConfigStore.AgentAddError.noPrivateKey.errorDescription?.isEmpty == false)
        #expect(ConfigStore.AgentAddError.unreadable.errorDescription?.isEmpty == false)
        #expect(ConfigStore.AgentAddError.cancelled.errorDescription == nil)
    }

    @Test func uiTestDirectoryArgParsing() {
        // Flag with a value → that directory.
        #expect(
            ConfigStore.uiTestDirectory(arguments: ["app", "--uitest-ssh-dir", "/tmp/seed"])?
                .path == "/tmp/seed")
        // Flag absent → nil.
        #expect(ConfigStore.uiTestDirectory(arguments: ["app", "--other"]) == nil)
        // Flag present but no trailing value → nil (no crash).
        #expect(ConfigStore.uiTestDirectory(arguments: ["app", "--uitest-ssh-dir"]) == nil)
    }
}
