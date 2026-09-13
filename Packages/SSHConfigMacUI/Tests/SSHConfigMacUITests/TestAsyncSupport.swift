//
//  TestAsyncSupport.swift
//  sshconfigmanagerTests
//
//  Bridges the tunnel/agent integration tests' callback-and-semaphore flows into
//  async/await. The old pattern — `DispatchSemaphore(value: 0)` + `.wait(timeout:)`
//  in the test body — blocks the calling thread, which is illegal on Swift
//  Concurrency's cooperative thread pool (where Swift Testing runs test bodies) and
//  faults at runtime under strict concurrency. `awaitResult` replaces it: it
//  suspends (never blocks) until a callback reports a result or a timeout elapses.
//

import Foundation
import SSHConfigEngine

@testable import SSHConfigMacUI

/// The terminal outcome of `NIOTunnelConnection.start`, captured for async waiting.
enum TunnelStartOutcome: Sendable {
    case active
    case failed(String)
}

/// Starts `connection` and suspends until it reports `.active` or `.failed`; returns
/// `nil` on timeout. The async replacement for the old `DispatchSemaphore` wait on a
/// tunnel becoming active — shared across the tunnel test suites.
func awaitTunnelStart(_ connection: NIOTunnelConnection, timeout: TimeInterval) async -> TunnelStartOutcome? {
    await awaitResult(timeout: timeout) { (finish: @escaping @Sendable (TunnelStartOutcome?) -> Void) in
        connection.start { status in
            switch status {
            case .active: finish(.active)
            case .failed(let reason): finish(.failed(reason))
            default: break
            }
        }
    }
}

/// A plain, message-carrying test failure for helpers that fail outside an `#expect`.
struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

/// Guards a `CheckedContinuation` so it resumes exactly once, from whichever of the
/// competing callbacks (success, failure, timeout) fires first. Thread-safe.
nonisolated final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func resume(_ value: T?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value) // no-op after the first call
    }
}

/// Runs a callback-style flow and returns its result without blocking a thread.
/// `start` receives a `finish` closure it must call with the result; if `timeout`
/// elapses first, `nil` is returned. `finish` may be called more than once (e.g. a
/// late callback after timeout) — only the first call wins.
func awaitResult<T: Sendable>(
    timeout: TimeInterval,
    _ start: @escaping @Sendable (@escaping @Sendable (T?) -> Void) -> Void
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = OnceResume(continuation)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        start { once.resume($0) }
    }
}
