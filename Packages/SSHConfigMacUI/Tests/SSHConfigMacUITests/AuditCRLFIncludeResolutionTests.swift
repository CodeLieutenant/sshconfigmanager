//
//  AuditCRLFIncludeResolutionTests.swift
//  sshconfigmanagerTests
//
//  AUDIT 2026-07-11 (docs/release/macos-bug-audit-2026-07-11.md, finding CFG-2) — FIXED.
//  On a config file saved with CRLF line endings, every `Include` used to silently
//  resolve to ZERO files. The parser deliberately keeps the trailing `\r` in a
//  directive's stored value (for byte-exact round-tripping — audit #27). Semantic getters
//  like `HostBlock.firstValue`/`values` strip it, but `ConfigStore.reload()` passes the
//  raw `include.value` to `SSHFileAccess.resolveIncludes`, whose `tokenize` split only on
//  space/tab and never stripped `\r`, so `Include config.d/*` became the glob
//  `config.d/*\r`, which matched nothing. `tokenize` now treats `\r`/`\n` as unquoted
//  whitespace (mirroring real ssh), so a CRLF include resolves the same as an LF one.
//

import Foundation
import Testing

@testable import SSHConfigMacUI

@MainActor
struct AuditCRLFIncludeResolutionTests {
    private func makeGrantedDir() throws -> (SSHFileAccess, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crlf-include-\(UUID().uuidString)", isDirectory: true)
        let confD = dir.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)
        try "Host web\n  HostName web.example.com\n"
            .write(to: confD.appendingPathComponent("work.conf"), atomically: true, encoding: .utf8)
        let fa = SSHFileAccess()
        fa.useDirectoryForTesting(dir)
        return (fa, dir)
    }

    /// Baseline: an LF (no trailing `\r`) include value resolves to the one file.
    @Test func lfIncludeResolvesToTheIncludedFile() throws {
        let (fa, dir) = try makeGrantedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = fa.resolveIncludes("config.d/*")
        #expect(resolved.count == 1)
        #expect(resolved.first?.lastPathComponent == "work.conf")
    }

    /// The former exploit, now fixed: the identical value with a trailing `\r` (what a
    /// CRLF file's parsed `include.value` actually carries) resolves the same as the LF
    /// case — the `\r` is treated as trailing whitespace, not glued onto the glob.
    @Test func crlfIncludeResolvesToTheIncludedFile() throws {
        let (fa, dir) = try makeGrantedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = fa.resolveIncludes("config.d/*\r")
        #expect(resolved.count == 1)
        #expect(resolved.first?.lastPathComponent == "work.conf")
    }
}
