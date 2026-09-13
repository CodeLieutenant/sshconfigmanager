//
//  ProbeSchedulerTests.swift
//  sshconfigmanagerTests
//
//  The shared probe scheduler: the concurrency cap, pause-while-offline gating,
//  and jittered interval. No NWPathMonitor here — gating is driven through the
//  DEBUG test seam so the tests are deterministic.
//

import Foundation
import Testing

@testable import SSHConfigMacUI

struct ProbeSchedulerTests {
    /// Tracks live + peak concurrency across probes.
    private actor Concurrency {
        private(set) var current = 0
        private(set) var peak = 0
        func enter() {
            current += 1
            peak = max(peak, current)
        }
        func leave() { current -= 1 }
    }

    private actor Flag {
        private(set) var value = false
        func set() { value = true }
    }

    @Test func runNeverExceedsTheConcurrencyCap() async {
        let scheduler = ProbeScheduler(maxConcurrent: 3)
        let tracker = Concurrency()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await scheduler.run {
                        await tracker.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await tracker.leave()
                    }
                }
            }
        }
        let peak = await tracker.peak
        #expect(peak >= 1)
        #expect(peak <= 3)
    }

    @Test func runPausesWhileOfflineThenResumes() async {
        let scheduler = ProbeScheduler(maxConcurrent: 2)
        await scheduler.setPausedForTesting(true)

        let flag = Flag()
        let task = Task { await scheduler.run { await flag.set() } }

        // While "offline" the work should stay parked.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await flag.value == false)

        await scheduler.setPausedForTesting(false)
        await task.value
        #expect(await flag.value == true)
    }

    /// Regression guard for audit #29: a task parked in `acquire()` waiting for
    /// a free slot must unpark as soon as it's cancelled, not sit blocked until
    /// a slot actually frees (here: never, since probing stays paused for the
    /// whole test) — `run` returns nil rather than hanging indefinitely.
    @Test func runReturnsPromptlyWhenCancelledWhileParked() async {
        let scheduler = ProbeScheduler(maxConcurrent: 1)
        await scheduler.setPausedForTesting(true) // never resumes in this test

        let task = Task<Int?, Never> {
            await scheduler.run { 42 }
        }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()

        let start = ContinuousClock.now
        let result = await task.value
        let elapsed = ContinuousClock.now - start
        #expect(result == nil)
        #expect(elapsed < .seconds(1), "a cancelled waiter must unpark immediately, not stay blocked")
    }

    /// A slot that's genuinely available must still work normally after an
    /// unrelated waiter was cancelled — cancellation of one waiter shouldn't
    /// corrupt bookkeeping (`inFlight`, `waiters`) for anyone else.
    @Test func cancellingOneWaiterDoesNotAffectAnother() async {
        let scheduler = ProbeScheduler(maxConcurrent: 1)
        await scheduler.setPausedForTesting(true)

        let cancelled = Task<Int?, Never> { await scheduler.run { 1 } }
        try? await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        _ = await cancelled.value

        await scheduler.setPausedForTesting(false)
        let result = await scheduler.run { 42 }
        #expect(result == 42)
    }

    @Test func intervalStaysWithinJitterBounds() async {
        let scheduler = ProbeScheduler()
        let base = Duration.seconds(10) // 10_000 ms; jitter is ±20%
        for _ in 0..<50 {
            let millis = await scheduler.interval(base: base).milliseconds
            // Normal: 8_000…12_000. Under Low Power Mode the base is ×3
            // (24_000…36_000), so accept the wider envelope to stay robust on CI.
            #expect(millis >= 8_000)
            #expect(millis <= 36_000)
        }
    }
}

extension Duration {
    fileprivate var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
