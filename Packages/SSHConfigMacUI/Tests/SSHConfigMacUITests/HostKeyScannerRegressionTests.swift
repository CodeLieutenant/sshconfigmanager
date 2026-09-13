//
//  HostKeyScannerRegressionTests.swift
//  sshconfigmanagerTests
//
//  Regression test for the pre-cancellation hang in HostKeyScanner.scan().
//
//  The bug: when a Task was already cancelled at the point scan() called
//  withTaskCancellationHandler, the onCancel handler ran synchronously (setting
//  ResultBox.done = true) before withCheckedContinuation's body executed.
//  The old attach() then stored the continuation with nothing left to resume it,
//  hanging forever.
//
//  The fix: attach() checks the `done` flag and immediately resumes the continuation
//  with a .failure(.unreachable("Cancelled.")) if finish() has already run.
//

import Foundation
import SSHConfigEngine
import Testing
import os

@testable import SSHConfigMacUI

struct HostKeyScannerCancellationTests {
    @Test func preCancelledScanReturnsWithoutHanging() async {
        // 192.0.2.1 is TEST-NET-1 per RFC 5737 — unroutable, no real server.
        let scanTask = Task<Result<HostKeyScanner.Probe, HostKeyScanner.ScanError>, Never> {
            await HostKeyScanner.scan(host: "192.0.2.1", port: 22, timeout: 0.5)
        }
        // Cancel before the task has a chance to run. This triggers the race where
        // onCancel fires before withCheckedContinuation's body in scan().
        scanTask.cancel()

        // Race scanTask.value against a 3-second wall-clock deadline.
        // Using DispatchQueue (not async Task) so the timeout fires even if the
        // Swift concurrency runtime is blocked waiting for scanTask.value.
        let completed = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            // `fired` is raced between the completion Task and the timeout; an
            // OSAllocatedUnfairLock owns it so the guard is Sendable and its
            // `withLock` works from the async Task too (NSLock.lock() is not).
            let fired = OSAllocatedUnfairLock(initialState: false)
            @Sendable func fireOnce(_ value: Bool) {
                let first = fired.withLock { alreadyFired in
                    defer { alreadyFired = true }
                    return !alreadyFired
                }
                if first { continuation.resume(returning: value) }
            }

            Task {
                _ = await scanTask.value // completes immediately with fix
                fireOnce(true)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                fireOnce(false) // timeout — hang detected
            }
        }

        #expect(completed, "Pre-cancelled HostKeyScanner.scan must return, not hang")
    }
}
