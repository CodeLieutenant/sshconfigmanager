//
//  TunnelE2ETests.swift
//  sshconfigmanagerTests
//
//  Live end-to-end test of the in-process engine against a real SSH server,
//  forwarding a remote service (e.g. Postgres) to a local port and confirming
//  bytes flow all the way through.
//
//  Opt-in: skipped unless ~/.ssh/.sshcfg-tunnel-e2e.json exists, so it never
//  runs in plain CI. That file describes the target:
//    { "host": "...", "port": 22, "user": "...", "keyPath": "~/.ssh/id_ed25519",
//      "passphrase": null, "remoteHost": "127.0.0.1", "remotePort": 5432 }
//
//  The local listen port is OS-assigned (random) so the test is safe to run in
//  parallel with others.
//

import Foundation
import Network
import SSHConfigCore
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

struct TunnelE2ETests {
    private struct Config: Decodable {
        let host: String
        let port: Int
        let user: String
        let keyPath: String
        let passphrase: String?
        let remoteHost: String
        let remotePort: Int
        // Optional ProxyJump hop (skip the ProxyJump test when absent).
        let jumpHost: String?
        let jumpPort: Int?
        let jumpUser: String?
        let jumpKeyPath: String?
        // Set true to exercise agent-backed auth (skip otherwise).
        let useAgent: Bool?
    }

    /// Loads the opt-in config + key, or returns nil to skip the test.
    private func loadConfigAndKey() -> (Config, String)? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/.sshcfg-tunnel-e2e.json")
        guard let data = FileManager.default.contents(atPath: path),
            let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return nil }
        let keyPath = (config.keyPath as NSString).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return nil }
        return (config, pem)
    }

    @Test func forwardsRemoteServiceThroughTheInProcessTunnel() async throws {
        guard let (cfg, pem) = loadConfigAndKey() else { return } // not configured → skip

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            pem: pem, passphrase: cfg.passphrase,
            sshHost: cfg.host, sshPort: cfg.port, username: cfg.user,
            bindHost: "127.0.0.1", bindPort: 0, // OS-assigned → parallel-safe
            targetHost: cfg.remoteHost, targetPort: cfg.remotePort)
        defer { connection.shutdown() }

        // Wait for the local listener to come up (SSH connect + bind).
        switch await awaitTunnelStart(connection, timeout: 30) {
        case nil:
            Issue.record("Tunnel did not become active within 30s")
            return
        case .failed(let reason):
            Issue.record("Tunnel failed: \(reason)")
            return
        case .active: break
        }
        guard let localPort = connection.boundPort else {
            Issue.record("Tunnel active but no bound port reported")
            return
        }

        // Drive a real Postgres SSLRequest through the forwarded local port. A
        // genuine Postgres server replies with a single 'S' or 'N' byte — which
        // can only arrive if auth + the direct-tcpip channel + byte glue all work.
        let reply = await postgresSSLRequest(toLocalPort: localPort)
        #expect(
            reply == UInt8(ascii: "S") || reply == UInt8(ascii: "N"),
            "expected a Postgres SSL response byte through the tunnel, got \(String(describing: reply))")
    }

    @Test func forwardsThroughAProxyJump() async throws {
        guard let (cfg, pem) = loadConfigAndKey() else { return } // not configured → skip
        guard let jumpHost = cfg.jumpHost else { return } // no jump configured → skip
        let jumpKeyPath = ((cfg.jumpKeyPath ?? cfg.keyPath) as NSString).expandingTildeInPath
        guard let jumpPem = try? String(contentsOfFile: jumpKeyPath, encoding: .utf8) else {
            Issue.record("jump key not readable at \(jumpKeyPath)")
            return
        }

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            hops: [
                .init(
                    pem: jumpPem, passphrase: cfg.passphrase,
                    host: jumpHost, port: cfg.jumpPort ?? 22, username: cfg.jumpUser ?? cfg.user),
                .init(
                    pem: pem, passphrase: cfg.passphrase,
                    host: cfg.host, port: cfg.port, username: cfg.user),
            ],
            bindHost: "127.0.0.1", bindPort: 0, // OS-assigned → parallel-safe
            targetHost: cfg.remoteHost, targetPort: cfg.remotePort)
        defer { connection.shutdown() }

        await expectPostgresThroughTunnel(connection, label: "ProxyJump")
    }

    @Test func authenticatesViaTheAgent() async throws {
        guard let (cfg, _) = loadConfigAndKey() else { return } // not configured → skip
        guard cfg.useAgent == true else { return } // agent test not requested → skip
        let identities = (try? await SSHAgentService().listIdentities()) ?? []
        guard !identities.isEmpty else {
            Issue.record("useAgent is set but the agent holds no identities")
            return
        }

        let connection = NIOTunnelEngine.makeAgentConnectionForTesting(
            identities: identities,
            sshHost: cfg.host, sshPort: cfg.port, username: cfg.user,
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: cfg.remoteHost, targetPort: cfg.remotePort)
        defer { connection.shutdown() }

        await expectPostgresThroughTunnel(connection, label: "agent auth")
    }

    /// Starts `connection`, waits for it to go active, and confirms a Postgres SSL
    /// response byte travels through the forwarded local port.
    private func expectPostgresThroughTunnel(_ connection: NIOTunnelConnection, label: String) async {
        switch await awaitTunnelStart(connection, timeout: 30) {
        case nil:
            Issue.record("\(label): tunnel did not become active within 30s")
            return
        case .failed(let reason):
            Issue.record("\(label): tunnel failed: \(reason)")
            return
        case .active: break
        }
        guard let localPort = connection.boundPort else {
            Issue.record("\(label): active but no bound port reported")
            return
        }
        let reply = await postgresSSLRequest(toLocalPort: localPort)
        #expect(
            reply == UInt8(ascii: "S") || reply == UInt8(ascii: "N"),
            "\(label): expected a Postgres SSL response byte, got \(String(describing: reply))")
    }

    @Test func forwardsRemoteServiceThroughADynamicSOCKSTunnel() async throws {
        guard let (cfg, pem) = loadConfigAndKey() else { return } // not configured → skip

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            mode: .dynamic, pem: pem, passphrase: cfg.passphrase,
            sshHost: cfg.host, sshPort: cfg.port, username: cfg.user,
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: "", targetPort: 0) // -D ignores a fixed target
        defer { connection.shutdown() }

        switch await awaitTunnelStart(connection, timeout: 30) {
        case nil:
            Issue.record("SOCKS tunnel did not become active within 30s")
            return
        case .failed(let reason):
            Issue.record("Tunnel failed: \(reason)")
            return
        case .active: break
        }
        guard let localPort = connection.boundPort else {
            Issue.record("active but no bound port")
            return
        }

        // Drive a SOCKS5 client: CONNECT to the remote Postgres, then SSLRequest.
        let reply = await socks5PostgresProbe(
            localPort: localPort,
            target: cfg.remoteHost, targetPort: cfg.remotePort)
        #expect(
            reply == UInt8(ascii: "S") || reply == UInt8(ascii: "N"),
            "expected a Postgres SSL byte via SOCKS5, got \(String(describing: reply))")
    }

    @Test func forwardsLocalServiceToRemotePortViaRemoteForward() async throws {
        guard let (cfg, pem) = loadConfigAndKey() else { return } // not configured → skip

        // A local echo server: whatever it receives, it sends straight back.
        let (echo, echoPort) = try await startEchoServer()
        defer { echo.cancel() }

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            mode: .remote, pem: pem, passphrase: cfg.passphrase,
            sshHost: cfg.host, sshPort: cfg.port, username: cfg.user,
            bindHost: "127.0.0.1", bindPort: 0, // server picks a remote port
            targetHost: "127.0.0.1", targetPort: echoPort)
        defer { connection.shutdown() }

        switch await awaitTunnelStart(connection, timeout: 30) {
        case nil:
            Issue.record("Remote forward did not become active within 30s")
            return
        case .failed(let reason):
            Issue.record("Tunnel failed: \(reason)")
            return
        case .active: break
        }
        guard let remotePort = connection.remoteBoundPort else {
            Issue.record("active but no remote bound port")
            return
        }

        // Poke the remote listener from the server itself; bytes should travel
        // back through the -R tunnel to our local echo and return.
        let reply = pokeRemotePort(cfg: cfg, port: remotePort, send: "PING")
        #expect(
            reply.contains("PING"),
            "expected the echoed bytes back through the -R tunnel, got \(reply.debugDescription)")
    }

    /// Starts a loopback TCP echo server; returns it and its bound port.
    private func startEchoServer() async throws -> (NWListener, Int) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            @Sendable func pump() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                    if let data, !data.isEmpty {
                        conn.send(content: data, completion: .idempotent)
                    }
                    if isComplete { conn.cancel() } else { pump() }
                }
            }
            pump()
        }
        let port = await awaitResult(timeout: 5) { (finish: @escaping @Sendable (Int?) -> Void) in
            listener.stateUpdateHandler = { if case .ready = $0 { finish(listener.port.map { Int($0.rawValue) }) } }
            listener.start(queue: .global())
        }
        guard let port else {
            listener.cancel()
            throw NSError(domain: "echo", code: 1)
        }
        return (listener, port)
    }

    /// Runs the system `ssh` to connect to 127.0.0.1:port *on the server* and
    /// exchange bytes (driving the remote end of the -R forward). Returns stdout.
    private func pokeRemotePort(cfg: Config, port: Int, send: String) -> String {
        let key = (cfg.keyPath as NSString).expandingTildeInPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "\(cfg.user)@\(cfg.host)",
            "exec 3<>/dev/tcp/127.0.0.1/\(port); printf '\(send)' >&3; head -c \(send.count) <&3",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Minimal SOCKS5 client: greeting → CONNECT(target) → Postgres SSLRequest.
    /// Returns the first Postgres reply byte (or nil).
    private func socks5PostgresProbe(localPort: Int, target: String, targetPort: Int) async -> UInt8? {
        let conn = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(localPort))!, using: .tcp)
        let host = Array(target.utf8)
        let connectReq = Data(
            [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + host
                + [UInt8(targetPort >> 8), UInt8(targetPort & 0xff)])
        let sslRequest = Data([0, 0, 0, 8, 0x04, 0xd2, 0x16, 0x2f])

        let result = await awaitResult(timeout: 15) { (finish: @escaping @Sendable (UInt8?) -> Void) in
            @Sendable func fail() { finish(nil) }
            @Sendable func recv(_ n: Int, _ next: @escaping @Sendable (Data) -> Void) {
                conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, _ in
                    guard let data, data.count == n else {
                        fail()
                        return
                    }
                    next(data)
                }
            }
            conn.stateUpdateHandler = { state in
                guard case .ready = state else {
                    if case .failed = state { fail() }
                    return
                }
                conn.send(
                    content: Data([0x05, 0x01, 0x00]),
                    completion: .contentProcessed { _ in // greeting
                        recv(2) { _ in
                            conn.send(
                                content: connectReq,
                                completion: .contentProcessed { _ in
                                    recv(10) { _ in // CONNECT reply
                                        conn.send(
                                            content: sslRequest,
                                            completion: .contentProcessed { _ in
                                                recv(1) { data in finish(data.first) }
                                            })
                                    }
                                })
                        }
                    })
            }
            conn.start(queue: .global())
        }
        conn.cancel()
        return result
    }

    /// Connects to 127.0.0.1:port, sends a Postgres SSLRequest, returns the first
    /// reply byte (or nil on failure/timeout).
    private func postgresSSLRequest(toLocalPort port: Int) async -> UInt8? {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp)

        // SSLRequest: int32 length (8) + int32 code (80877103).
        let sslRequest = Data([0, 0, 0, 8, 0x04, 0xd2, 0x16, 0x2f])

        let result = await awaitResult(timeout: 15) { (finish: @escaping @Sendable (UInt8?) -> Void) in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(
                        content: sslRequest,
                        completion: .contentProcessed { _ in
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
                                finish(data?.first)
                            }
                        })
                } else if case .failed = state {
                    finish(nil)
                }
            }
            connection.start(queue: .global())
        }
        connection.cancel()
        return result
    }
}
