//
//  ConnectionTesterTests.swift
//  sshconfigmanagerTests
//
//  Exercises the TCP reachability probe against real loopback sockets: a live
//  listener (reachable), a closed port (unreachable), and invalid input. Also
//  covers the ConnectionResult value type's summary/isReachable.
//

import Foundation
import Network
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct ConnectionTesterTests {
    /// Starts a loopback TCP listener and returns it plus its bound port.
    private func startListener() async throws -> (NWListener, Int) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { $0.cancel() } // accept then drop
        let port = await awaitResult(timeout: 5) { (finish: @escaping @Sendable (Int?) -> Void) in
            listener.stateUpdateHandler = { if case .ready = $0 { finish(listener.port.map { Int($0.rawValue) }) } }
            listener.start(queue: .global())
        }
        guard let port else {
            listener.cancel()
            throw NSError(domain: "listener", code: 1)
        }
        return (listener, port)
    }

    @Test func reachesALiveLocalListener() async throws {
        let (listener, port) = try await startListener()
        defer { listener.cancel() }
        let result = await ConnectionTester.probe(host: "127.0.0.1", port: port, timeout: 5)
        #expect(result.isReachable)
        if case .reachable(let ms) = result {
            #expect(ms >= 0)
        } else {
            Issue.record("expected .reachable, got \(result)")
        }
    }

    @Test func closedPortIsNotReachable() async {
        // A high loopback port with nothing listening: refused → not reachable.
        let result = await ConnectionTester.probe(host: "127.0.0.1", port: 1, timeout: 3)
        #expect(!result.isReachable)
    }

    @Test func zeroPortFailsFast() async {
        let zero = await ConnectionTester.probe(host: "127.0.0.1", port: 0)
        #expect(zero == .failed("Invalid port 0"))
        // An out-of-UInt16-range port isn't a valid target either: never reachable.
        let tooBig = await ConnectionTester.probe(host: "127.0.0.1", port: 70_000, timeout: 3)
        #expect(!tooBig.isReachable)
    }

    /// Regression guard for audit #29: without the `.cancelled` case in
    /// `probe`'s state handler, a cancelled task's continuation was never
    /// resumed until the `timeout` fallback fired — up to several seconds
    /// later — instead of returning promptly like every other
    /// cancellation-aware await in the app.
    ///
    /// `10.255.255.1` is a private, unrouted address that (verified
    /// empirically in this sandbox) sits in `NWConnection`'s `.preparing`
    /// state indefinitely, never reaching `.ready`/`.failed`/`.waiting` on its
    /// own — exactly the "still pending" window a cancellation needs to race.
    @Test func cancellingTheTaskReturnsPromptlyInsteadOfWaitingOutTheTimeout() async {
        let task = Task {
            await ConnectionTester.probe(host: "10.255.255.1", port: 54321, timeout: 30)
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let start = ContinuousClock.now
        _ = await task.value
        let elapsed = ContinuousClock.now - start
        #expect(
            elapsed < .seconds(3),
            "cancellation should resolve the probe almost immediately, not wait out the 30s timeout")
    }

    @Test func resultSummariesAreHumanReadable() {
        #expect(ConnectionResult.reachable(milliseconds: 12).summary.contains("12 ms"))
        #expect(ConnectionResult.unreachable.summary.contains("Unreachable"))
        #expect(ConnectionResult.timedOut.summary == "Timed out")
        #expect(ConnectionResult.failed("boom").summary == "Failed: boom")
        #expect(ConnectionResult.reachable(milliseconds: 1).isReachable)
        #expect(!ConnectionResult.unreachable.isReachable)
    }
}
