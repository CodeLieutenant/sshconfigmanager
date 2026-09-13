import Foundation
import Testing

@testable import SSHManagerUI

@Suite("SSHDirectory")
struct SSHDirectoryTests {
    @Test("a directory that does not exist reports missing")
    func missing() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshmanager-\(UUID().uuidString)").path
        #expect(SSHDirectory.inspect(path: path) == .missing(path: path))
    }

    @Test("a readable and writable directory reports ready")
    func ready() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshmanager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SSHDirectory.inspect(path: url.path) == .ready(path: url.path))
    }

    @Test("a file where a directory is expected reports missing")
    func fileIsNotADirectory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshmanager-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SSHDirectory.inspect(path: url.path) == .missing(path: url.path))
    }

    @Test("home comes from the passwd entry, not $HOME")
    func homeIgnoresEnvironment() {
        setenv("HOME", "/nonexistent-home-for-test", 1)
        defer { unsetenv("HOME") }
        #expect(SSHDirectory.home != "/nonexistent-home-for-test")
    }
}
