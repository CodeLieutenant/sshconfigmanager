//
//  TunnelBackoffTests.swift
//  sshconfigmanagerTests
//
//  Deterministic coverage for `TunnelBackoff`'s pure schedule. Jitter bounds
//  are asserted rather than exact values, since the mapping from RNG seed to
//  jittered output is an implementation detail of `Int.random(in:using:)`.
//

import Foundation
import SSHConfigCore
import Testing

/// A deterministic xorshift64 stream seeded by `value` — exercises a fixed
/// corner of the jitter range reproducibly. Can't just return `value` from
/// every `next()` call: `Int.random(in:using:)` rejection-samples internally,
/// and a truly constant generator makes that loop spin forever whenever the
/// constant falls in its reject-and-retry zone (confirmed by a hung test run).
private struct FixedRNG: RandomNumberGenerator {
    private var state: UInt64
    init(value: UInt64) { state = value == 0 ? 0x9E37_79B9_7F4A_7C15 : value }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

struct TunnelBackoffTests {
    @Test func schedulesTheDocumentedStepsWithinTwentyPercentJitter() {
        let cap = 60
        let expectedBase: [Int: Int] = [1: 1, 2: 2, 3: 5, 4: 15, 5: 60]
        for (attempt, base) in expectedBase {
            for seedValue in [UInt64.min, .max / 4, .max / 2, .max / 4 * 3, .max] {
                var rng = FixedRNG(value: seedValue)
                let duration = TunnelBackoff.duration(forAttempt: attempt, cap: cap, rng: &rng)
                let lower = Duration.milliseconds(Int(Double(base * 1000) * 0.8))
                let upper = Duration.milliseconds(Int(Double(base * 1000) * 1.2))
                #expect(
                    duration >= lower && duration <= upper,
                    "attempt \(attempt) seed \(seedValue): \(duration) outside ±20% of \(base)s")
            }
        }
    }

    @Test func neverExceedsCapEvenAtMaxJitter() {
        var rng = FixedRNG(value: .max)
        let duration = TunnelBackoff.duration(forAttempt: 4, cap: 10, rng: &rng)
        // step=15 clamps to cap=10, plus up to +20% jitter = 12s ceiling.
        #expect(duration <= .seconds(12))
    }

    @Test func attemptsBeyondTheScheduleHoldAtTheCap() {
        var rng = FixedRNG(value: .max / 2)
        let a4 = TunnelBackoff.duration(forAttempt: 4, cap: 100, rng: &rng)
        let a9 = TunnelBackoff.duration(forAttempt: 9, cap: 100, rng: &rng)
        // Attempt 4 (base 15s) is well under the 100s cap; attempt 9 sits at it.
        #expect(a4 < .seconds(30))
        #expect(a9 >= .seconds(80) && a9 <= .seconds(120))
    }

    @Test func nonPositiveCapIsNormalizedToAtLeastOneSecond() {
        var rng = FixedRNG(value: 0)
        let duration = TunnelBackoff.duration(forAttempt: 1, cap: 0, rng: &rng)
        #expect(duration > .zero)
        #expect(duration <= .seconds(2))
    }
}
