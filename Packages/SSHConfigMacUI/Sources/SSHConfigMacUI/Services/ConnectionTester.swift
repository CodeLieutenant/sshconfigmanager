//
//  ConnectionTester.swift
//  sshconfigmanager
//
//  A TCP reachability probe (Network.framework). Real SSH auth can't run in the
//  sandbox, but "can I reach host:port" covers the common case.
//

import Foundation
import Network
import SSHConfigCore

// `ConnectionResult` now lives in SSHConfigCore (Model/ConnectionResult.swift).

enum ConnectionTester {
    /// Opens a TCP connection to `host:port`, returning reachability + latency.
    static func probe(host: String, port: Int, timeout: TimeInterval = 5) async -> ConnectionResult {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else {
            return .failed("Invalid port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = DispatchTime.now()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConnectionResult, Never>) in
                let state = ResultBox(continuation: continuation, connection: connection)

                connection.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                        state.finish(.reachable(milliseconds: Int(Double(elapsed) / 1_000_000)))
                    case .failed(let error):
                        state.finish(.failed(error.localizedDescription))
                    case .waiting:
                        // Refused / unreachable surfaces here; don't sit and retry.
                        state.finish(.unreachable)
                    case .cancelled:
                        // `onCancel` below calls `connection.cancel()` on task
                        // cancellation, but without this case the continuation
                        // was never resumed for it (audit #29) — a cancelled
                        // probe sat blocked until the `timeout` fallback fired
                        // (up to several seconds later) instead of returning
                        // promptly like every other cancellation-aware await.
                        state.finish(.failed("cancelled"))
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    state.finish(.timedOut)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Serializes the single allowed completion and cleans up the connection.
    /// `nonisolated`: `finish` is called from Network.framework's callback queue.
    private nonisolated final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<ConnectionResult, Never>
        private let connection: NWConnection

        init(continuation: CheckedContinuation<ConnectionResult, Never>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func finish(_ result: ConnectionResult) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            connection.cancel()
            continuation.resume(returning: result)
        }
    }
}
