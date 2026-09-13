//
//  PerformanceTests.swift
//  sshconfigmanagerTests
//
//  Benchmark tests (a different type from the example/property suites): they pin
//  performance baselines for the hot pure-logic paths so a future change that makes
//  parsing, serializing, or auditing pathologically slow shows up as a regression.
//  These use XCTest's `measure` (Swift Testing has no benchmarking API); XCTest and
//  Swift Testing coexist in the same target.
//

import SSHConfigCore
import XCTest

final class PerformanceTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/config")

    /// A large but realistic config: 1,000 host blocks, 5 directives each.
    private lazy var largeConfig: String = {
        var lines: [String] = []
        for i in 0..<1_000 {
            lines.append("# host number \(i)")
            lines.append("Host host-\(i)")
            lines.append("    HostName \(i).example.com")
            lines.append("    User user\(i)")
            lines.append("    Port \(2000 + i)")
            lines.append("    IdentityFile ~/.ssh/id_\(i)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }()

    func testParseLargeConfig() {
        measure { _ = SSHConfigParser.parse(largeConfig, sourceURL: url) }
    }

    func testRoundTripLargeConfig() {
        let doc = SSHConfigParser.parse(largeConfig, sourceURL: url)
        measure { _ = SSHConfigSerializer.serialize(doc) }
    }

    func testLintLargeConfig() {
        let doc = SSHConfigParser.parse(largeConfig, sourceURL: url)
        measure { _ = ConfigLinter.lint([doc]) }
    }

    func testAuditManyKeys() {
        let keys: [KeyAuditor.KeyInput] = (0..<500).map { i in
            KeyAuditor.KeyInput(
                key: SSHPublicKey(
                    publicKeyURL: url.appendingPathComponent("k\(i).pub"),
                    privateKeyURL: url.appendingPathComponent("k\(i)"),
                    algorithm: i % 2 == 0 ? "ssh-rsa" : "ssh-ed25519",
                    fingerprint: "SHA256:x", comment: "c"),
                rsaBits: 2048, isEncrypted: i % 3 == 0, privateKeyMode: 0o600)
        }
        let docs = [SSHConfigParser.parse("", sourceURL: url)]
        measure { _ = KeyAuditor.audit(keys: keys, documents: docs) }
    }

    func testRandomArtThroughput() {
        let digest = [UInt8](repeating: 0x5A, count: 32)
        measure {
            for _ in 0..<1_000 {
                _ = RandomArt.drunkenBishop(digest: digest, title: "ED25519 256", hashName: "SHA256")
            }
        }
    }
}
