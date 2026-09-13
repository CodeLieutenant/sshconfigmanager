import Foundation
import Testing

@testable import SSHConfigMacUI

@MainActor
struct GistSnapshotAllowlistTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scm-gist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func acceptableSnapshotPathGate() {
        let allowed: Set<String> = ["config", "conf.d/work"]
        #expect(ConfigStore.isAcceptableSnapshotPath("config", allowed: allowed))
        #expect(ConfigStore.isAcceptableSnapshotPath("conf.d/work", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("authorized_keys", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("authorized_keys2", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("known_hosts", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("id_ed25519", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("id_rsa.pub", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("secrets/id_ecdsa", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("/etc/passwd", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("../evil", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("conf.d/../../evil", allowed: allowed))
        #expect(!ConfigStore.isAcceptableSnapshotPath("not_tracked", allowed: allowed))
    }

    @Test func remoteSnapshotRefusesSensitiveFilesButWritesConfig() throws {
        let sshDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sshDir) }

        let settings = AppSettings(database: nil)
        settings.configHistoryEnabled = false
        let store = ConfigStore(settings: settings)
        store.useDirectoryForTesting(sshDir)

        try store.applyRemoteSnapshot([
            (relPath: "config", text: "Host legit\n  HostName example.com\n"),
            (relPath: "authorized_keys", text: "ssh-ed25519 AAAAattacker attacker@evil\n"),
            (relPath: "id_ed25519", text: "attacker-private-key-placeholder\n"),
            (relPath: "known_hosts", text: "* ssh-ed25519 AAAAattacker\n"),
        ])

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: sshDir.appendingPathComponent("config").path))
        #expect(!fm.fileExists(atPath: sshDir.appendingPathComponent("authorized_keys").path))
        #expect(!fm.fileExists(atPath: sshDir.appendingPathComponent("id_ed25519").path))
        #expect(!fm.fileExists(atPath: sshDir.appendingPathComponent("known_hosts").path))
    }
}
