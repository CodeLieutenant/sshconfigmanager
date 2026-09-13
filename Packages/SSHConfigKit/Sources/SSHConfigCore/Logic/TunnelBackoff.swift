//
//  TunnelBackoff.swift
//  sshconfigmanager
//
//  Pure exponential-backoff-with-jitter schedule for tunnel reconnect
//  attempts. Kept separate from the live supervisor (`TunnelStore`) so the
//  schedule can be unit-tested without touching `AppSettings` or the system
//  RNG. See docs/plans/tunneling/monitor.md.
//

import Foundation

/// Exponential backoff with ±20% jitter (1s, 2s, 5s, 15s, then `cap`).
public enum TunnelBackoff {
    /// Production entry point: jitter drawn from the system RNG.
    public static func duration(forAttempt attempt: Int, cap: Int) -> Duration {
        var rng = SystemRandomNumberGenerator()
        return duration(forAttempt: attempt, cap: cap, rng: &rng)
    }

    /// Test entry point: `rng` is injected so the jittered result is deterministic.
    public static func duration(
        forAttempt attempt: Int, cap: Int,
        rng: inout some RandomNumberGenerator
    ) -> Duration {
        let normalizedCap = max(1, cap)
        let step: Int
        switch attempt {
        case 1: step = 1
        case 2: step = 2
        case 3: step = 5
        case 4: step = 15
        default: step = normalizedCap
        }
        let base = min(step, normalizedCap)
        let jitter = Int.random(in: -(base * 200)...(base * 200), using: &rng) // ±20% in ms
        return .milliseconds(base * 1000 + jitter)
    }
}
