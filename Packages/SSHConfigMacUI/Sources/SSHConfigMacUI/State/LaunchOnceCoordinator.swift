//
//  LaunchOnceCoordinator.swift
//  sshconfigmanager
//

import Foundation

/// Runs an async launch body exactly once, no matter how many times `runOnce` is
/// called (e.g. once per `.onAppear` firing). Kept as a plain object — not tied
/// to SwiftUI — so the ordering/idempotency it guarantees is unit-testable
/// without a view hierarchy.
@MainActor
final class LaunchOnceCoordinator {
    private(set) var didRun = false

    /// Runs `body` the first time this is called; every subsequent call
    /// (concurrent or sequential) is a no-op. Returns whether `body` ran, so a
    /// caller that also has non-idempotent work gated on the *same* launch can
    /// check it without a second flag.
    @discardableResult
    func runOnce(_ body: () async -> Void) async -> Bool {
        guard !didRun else { return false }
        didRun = true
        await body()
        return true
    }
}
