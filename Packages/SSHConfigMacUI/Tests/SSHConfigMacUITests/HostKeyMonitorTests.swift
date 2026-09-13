//
//  HostKeyMonitorTests.swift
//  sshconfigmanagerTests
//
//  The background host-key monitor: turning live-probe results into alerts, only
//  notifying when an alert first appears, and clearing once the host verifies again.
//

import Foundation
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

@MainActor
struct HostKeyMonitorTests {
    private func group(host: String, keyType: String, fingerprint: String) -> [KnownHostGroup] {
        let entry = KnownHostEntry(
            id: UUID(), lineIndex: 0, raw: "", marker: nil,
            hostsDisplay: host, isHashed: false, keyType: keyType, fingerprint: fingerprint)
        return KnownHostGroup.build(from: [entry])
    }

    /// `AppSettings(database: nil)` keeps defaults without touching the real SQLite store
    /// (see the test-isolation note in the repo). Notifications are forced OFF so a test
    /// without an injected notifier never reaches the real `UNUserNotificationCenter`
    /// (which traps in an SPM test bundle); the notify-assertion test opts back in.
    private func settings(notifications: Bool = false) -> AppSettings {
        let s = AppSettings(database: nil)
        s.hostKeyNotificationsEnabled = notifications
        return s
    }

    @Test func changedKeyRaisesAlertAndNotifiesOnce() async {
        let groups = group(host: "example.com", keyType: "ssh-ed25519", fingerprint: "SHA256:OLD")
        var notifications: [[HostKeyAlert]] = []
        let monitor = HostKeyMonitor(
            groups: { groups },
            settings: settings(notifications: true),
            now: { Date(timeIntervalSince1970: 0) },
            scan: { _, _ in
                .success(
                    HostKeyScanner.Probe(keyType: "ssh-ed25519", fingerprint: "SHA256:NEW", openSSH: "ssh-ed25519 AAAA")
                )
            },
            notifier: { notifications.append($0) })

        await monitor.sweep(reason: .manual)
        #expect(monitor.alerts.count == 1)
        #expect(monitor.alerts.first?.kind == .changed)
        #expect(monitor.alerts.first?.serverFingerprint == "SHA256:NEW")
        #expect(notifications.count == 1)

        // A second sweep finds the same discrepancy — it must not re-notify.
        await monitor.sweep(reason: .manual)
        #expect(monitor.alerts.count == 1)
        #expect(notifications.count == 1)
    }

    @Test func newKeyTypeRaisesNewKeyAlert() async {
        let groups = group(host: "example.com", keyType: "ssh-ed25519", fingerprint: "SHA256:ED")
        let monitor = HostKeyMonitor(
            groups: { groups }, settings: settings(), now: { Date(timeIntervalSince1970: 0) },
            scan: { _, _ in
                .success(HostKeyScanner.Probe(keyType: "ssh-rsa", fingerprint: "SHA256:RSA", openSSH: "ssh-rsa AAAA"))
            })
        await monitor.sweep(reason: .manual)
        #expect(monitor.alerts.first?.kind == .newKey)
    }

    @Test func matchingKeyRaisesNoAlert() async {
        let groups = group(host: "example.com", keyType: "ssh-ed25519", fingerprint: "SHA256:SAME")
        let monitor = HostKeyMonitor(
            groups: { groups }, settings: settings(), now: { Date(timeIntervalSince1970: 0) },
            scan: { _, _ in
                .success(
                    HostKeyScanner.Probe(
                        keyType: "ssh-ed25519", fingerprint: "SHA256:SAME", openSSH: "ssh-ed25519 AAAA"))
            })
        await monitor.sweep(reason: .manual)
        #expect(monitor.alerts.isEmpty)
    }

    @Test func unreachableHostRaisesNoAlert() async {
        let groups = group(host: "example.com", keyType: "ssh-ed25519", fingerprint: "SHA256:OLD")
        let monitor = HostKeyMonitor(
            groups: { groups }, settings: settings(), now: { Date(timeIntervalSince1970: 0) },
            scan: { _, _ in .failure(.timedOut) })
        await monitor.sweep(reason: .manual)
        #expect(monitor.alerts.isEmpty)
    }

    @Test func resolvedKeyClearsAlertOnNextSweep() async {
        let groups = group(host: "example.com", keyType: "ssh-ed25519", fingerprint: "SHA256:OLD")
        // First the server presents a new key (alert), then it matches (cleared).
        let serverFingerprint = LockedFingerprint()
        serverFingerprint.value = "SHA256:NEW"
        let monitor = HostKeyMonitor(
            groups: { groups }, settings: settings(), now: { Date(timeIntervalSince1970: 0) },
            scan: { _, _ in
                .success(
                    HostKeyScanner.Probe(
                        keyType: "ssh-ed25519", fingerprint: serverFingerprint.value, openSSH: "ssh-ed25519 AAAA"))
            })

        await monitor.sweep(reason: .manual)
        #expect(monitor.alerts.count == 1)

        serverFingerprint.value = "SHA256:OLD" // host now matches what's stored
        await monitor.sweep(reason: .manual)
        #expect(monitor.alerts.isEmpty)
    }

    @Test func disabledMonitorSkipsScheduledButAllowsManual() async {
        let s = settings()
        s.hostKeyMonitorEnabled = false
        let groups = group(host: "example.com", keyType: "ssh-ed25519", fingerprint: "SHA256:OLD")
        let monitor = HostKeyMonitor(
            groups: { groups }, settings: s, now: { Date(timeIntervalSince1970: 0) },
            scan: { _, _ in
                .success(
                    HostKeyScanner.Probe(keyType: "ssh-ed25519", fingerprint: "SHA256:NEW", openSSH: "ssh-ed25519 AAAA")
                )
            })
        // A scheduled sweep respects the disabled toggle…
        await monitor.sweep(reason: .scheduled)
        #expect(monitor.alerts.isEmpty)
        // …but an explicit "Check Now" always runs.
        await monitor.sweep(reason: .manual)
        #expect(monitor.alerts.count == 1)
    }

    @Test func dismissAlertsForGroupRemovesThem() async {
        let groups = group(host: "example.com", keyType: "ssh-ed25519", fingerprint: "SHA256:OLD")
        let monitor = HostKeyMonitor(
            groups: { groups }, settings: settings(), now: { Date(timeIntervalSince1970: 0) },
            scan: { _, _ in
                .success(
                    HostKeyScanner.Probe(keyType: "ssh-ed25519", fingerprint: "SHA256:NEW", openSSH: "ssh-ed25519 AAAA")
                )
            })
        await monitor.sweep(reason: .manual)
        let id = monitor.alerts.first!.groupID
        monitor.dismissAlerts(forGroup: id)
        #expect(monitor.alerts.isEmpty)
    }
}

/// A tiny mutable box so the injected `scan` closure can change what the "server"
/// presents between sweeps without capturing a `var` (the closure is `@Sendable`).
private final class LockedFingerprint: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""
    var value: String {
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
