//
//  TunnelHealth.swift
//  sshconfigmanager
//
//  Pure state-machine reducer for a tunnel's health, driven by local-port
//  reachability probes. Kept separate from the live supervisor so the
//  transitions can be unit-tested by feeding synthetic probe results.
//  See docs/plans/tunneling/monitor.md.
//

import Foundation

/// Reduces probe results into a `TunnelStatus`, debouncing brief blips and giving
/// up after a threshold of consecutive failures.
public struct TunnelHealth {
    /// Consecutive failures tolerated before reporting `.degraded`.
    public let degradeAfter: Int
    /// Consecutive failures before reporting `.failed` (stops the watchdog).
    public let giveUpAfter: Int

    private(set) var consecutiveFailures = 0

    public init(degradeAfter: Int = 2, giveUpAfter: Int = 6) {
        self.degradeAfter = max(1, degradeAfter)
        self.giveUpAfter = max(degradeAfter + 1, giveUpAfter)
    }

    /// Applies one probe result to the current state and returns the next state.
    /// `now` is injected so tests are deterministic.
    public mutating func apply(
        _ probe: ConnectionResult,
        to state: TunnelStatus,
        now: Date
    ) -> TunnelStatus {
        if probe.isReachable {
            consecutiveFailures = 0
            // Preserve the original `since` once active so uptime keeps counting.
            if case .active = state { return state }
            return .active(since: now)
        }

        consecutiveFailures += 1
        if consecutiveFailures >= giveUpAfter {
            return .failed(reason: probe.summary)
        }
        if consecutiveFailures >= degradeAfter {
            return .degraded
        }
        // A single miss right after starting shouldn't flap the UI.
        return state
    }
}
