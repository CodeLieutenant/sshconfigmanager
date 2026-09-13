//
//  PathCompletionBrowserTests.swift
//  sshconfigmanagerTests
//
//  The FileManager-backed `FileSystemBrowsing` adapter that powers raw-editor file
//  completion: lists real entries inside the granted root, flags directories, and
//  refuses to list anything outside the grant.
//

import Foundation
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

struct PathCompletionBrowserTests {
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ssh-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try Data().write(to: base.appendingPathComponent("id_ed25519"))
        try Data().write(to: base.appendingPathComponent("config"))
        try fm.createDirectory(at: base.appendingPathComponent("work"), withIntermediateDirectories: true)
        return base
    }

    @Test func listsFilesAndFolders() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let browser = PathCompletionBrowser(homeDirectoryPath: "/Users/me", baseDirectoryPath: base.path)

        let entries = browser.listDirectory(base.path)
        #expect(entries.contains { $0.name == "id_ed25519" && !$0.isDirectory })
        #expect(entries.contains { $0.name == "work" && $0.isDirectory })
    }

    @Test func refusesToListOutsideTheGrant() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let browser = PathCompletionBrowser(homeDirectoryPath: "/Users/me", baseDirectoryPath: base.path)

        #expect(browser.listDirectory("/etc").isEmpty)
        #expect(browser.listDirectory(base.deletingLastPathComponent().path).isEmpty)
    }

    @Test func noBaseMeansNoListing() {
        let browser = PathCompletionBrowser(homeDirectoryPath: "/Users/me", baseDirectoryPath: nil)
        #expect(browser.listDirectory("/Users/me/.ssh").isEmpty)
    }
}
