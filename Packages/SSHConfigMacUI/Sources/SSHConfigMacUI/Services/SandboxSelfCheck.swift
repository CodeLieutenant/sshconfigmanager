//
//  SandboxSelfCheck.swift
//  sshconfigmanager
//
//  Dev-only diagnostic that runs inside the real sandboxed process to confirm
//  the entitlements the in-process tunnel engine relies on actually work under
//  the App Sandbox — chiefly binding a loopback listener (network.server) and
//  connecting to it (network.client). Also probes the ssh-agent Unix-domain
//  socket, which lives *outside* the container (`SSH_AUTH_SOCK`), to confirm the
//  sandbox lets us reach it. Triggered with `--sandbox-selfcheck`.
//

#if DEBUG
    import Foundation
    import Network
    import SSHConfigCore

    enum SandboxSelfCheck {
        /// Runs each probe, prints the outcome, then exits.
        static func run() {
            let listener = checkLoopbackListener()
            FileHandle.standardError.write(Data("SANDBOX-SELFCHECK \(listener)\n".utf8))
            let agent = checkAgentSocket()
            FileHandle.standardError.write(Data("SANDBOX-SELFCHECK \(agent)\n".utf8))
            exit(0)
        }

        /// Connects to the live `SSH_AUTH_SOCK` and does one REQUEST_IDENTITIES
        /// round-trip via the engine's real socket path. A sandbox that blocked the
        /// outside-container Unix socket would surface here as a connect failure.
        private static func checkAgentSocket() -> String {
            guard let path = SSHAgentService.socketPath else {
                return "agent=SKIP (SSH_AUTH_SOCK unset — no agent to probe)"
            }
            do {
                let reply = try SSHAgentService.roundTripForTesting(
                    SSHAgentProtocol.requestIdentitiesMessage(), socketPath: path)
                let identities = try SSHAgentProtocol.parseIdentities(reply)
                return "agent=OK (reached \(path), agent holds \(identities.count) identity(ies) under sandbox)"
            } catch {
                return "agent=FAIL (\(path): \(error) — sandbox blocking the agent socket?)"
            }
        }

        private static func checkLoopbackListener() -> String {
            let server = LocalForwardServer()
            let listening = DispatchSemaphore(value: 0)
            let accepted = DispatchSemaphore(value: 0)
            let box = ResultBox()

            server.onStateChange = { state in
                switch state {
                case .listening(let port):
                    box.port = port
                    listening.signal()
                case .failed(let error):
                    box.error = error
                    listening.signal()
                case .idle: break
                }
            }
            server.onAccept = { connection in
                accepted.signal()
                connection.cancel()
            }

            do { try server.start(port: 0) } catch {
                return "listener=FAIL (start threw: \(error.localizedDescription))"
            }
            guard listening.wait(timeout: .now() + 5) == .success else {
                return "listener=FAIL (no state within 5s)"
            }
            guard let port = box.port else {
                return "listener=FAIL (bind failed: \(box.error ?? "unknown") — network.server denied?)"
            }

            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: .global())
            defer {
                connection.cancel()
                server.cancel()
            }
            guard accepted.wait(timeout: .now() + 5) == .success else {
                return "listener=PARTIAL (bound :\(port) but no inbound accept)"
            }
            return "listener=OK (bound :\(port), accepted loopback connection under sandbox)"
        }

        private nonisolated final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _port: UInt16?
            private var _error: String?
            var port: UInt16? {
                get {
                    lock.lock()
                    defer { lock.unlock() }
                    return _port
                }
                set {
                    lock.lock()
                    _port = newValue
                    lock.unlock()
                }
            }
            var error: String? {
                get {
                    lock.lock()
                    defer { lock.unlock() }
                    return _error
                }
                set {
                    lock.lock()
                    _error = newValue
                    lock.unlock()
                }
            }
        }
    }
#endif
