//
//  HostKeyCheckStoreTests.swift
//  sshconfigmanagerTests
//
//  Persistence + pruning for the host-key check log, and the monitor's freshness
//  classification (the green/amber/red security badge).
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

@MainActor
struct HostKeyCheckStoreTests {
    private func makeDatabase() -> AppDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hkc-test-\(UUID().uuidString).store")
        return AppDatabase.testDatabase(at: url)
    }

    private func record(
        _ group: String, outcome: String, at: TimeInterval,
        fingerprint: String = "SHA256:x"
    ) -> AppDatabase.HostKeyCheckRecord {
        .init(
            groupID: group, hostTitle: group, displayName: group, hostToken: group,
            keyType: "ssh-ed25519", fingerprint: fingerprint, serverOpenSSH: "ssh-ed25519 AAAA",
            outcome: outcome, checkedAt: Date(timeIntervalSince1970: at))
    }

    @Test func recordsAndLoadsLatestPerHost() async throws {
        let db = makeDatabase()
        try await db.recordHostKeyChecks([
            record("host:a", outcome: "verified", at: 100),
            record("host:b", outcome: "changed", at: 100),
        ])
        // A newer check for host:a should win.
        try await db.recordHostKeyChecks([record("host:a", outcome: "verified", at: 200)])

        let latest = try await db.loadLatestHostKeyChecks()
        #expect(latest.count == 2)
        let a = latest.first { $0.groupID == "host:a" }
        #expect(a?.checkedAt == Date(timeIntervalSince1970: 200))
        #expect(latest.first { $0.groupID == "host:b" }?.outcome == "changed")
    }

    @Test func prunesToCap() async throws {
        let db = makeDatabase()
        // 10 checks for distinct hosts, cap at 4 → only the 4 newest survive.
        for i in 0..<10 {
            try await db.recordHostKeyChecks([record("host:\(i)", outcome: "verified", at: Double(i))], cap: 4)
        }
        let latest = try await db.loadLatestHostKeyChecks()
        #expect(latest.count == 4)
        // The survivors are the newest ids (hosts 6..9).
        #expect(Set(latest.map(\.groupID)) == ["host:6", "host:7", "host:8", "host:9"])
    }

    // MARK: - Freshness

    @Test func freshnessNeverWithoutCheck() {
        let m = HostKeyMonitor(
            groups: { [] }, settings: AppSettings(database: nil),
            now: { Date(timeIntervalSince1970: 0) },
            scan: { _, _ in .failure(.timedOut) }, database: nil)
        #expect(m.freshness == .never)
    }

    @Test func freshnessBucketsByAge() async {
        // A mutable clock lets us advance "now" and read the real `freshness` property
        // after a sweep stamps `lastCheck`.
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_000_000))
        let m = HostKeyMonitor(
            groups: { [] }, settings: AppSettings(database: nil),
            now: { clock.value },
            scan: { _, _ in .failure(.timedOut) }, database: nil)
        await m.sweep(reason: .manual) // lastCheck = base
        #expect(m.freshness == .fresh)
        clock.value = clock.value.addingTimeInterval(2 * 86_400)
        #expect(m.freshness == .stale)
        clock.value = clock.value.addingTimeInterval(6 * 86_400) // 8 days from base
        #expect(m.freshness == .critical)
    }
}

/// A mutable reference clock for tests that need to advance "now".
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(start: Date) { _value = start }
    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}
