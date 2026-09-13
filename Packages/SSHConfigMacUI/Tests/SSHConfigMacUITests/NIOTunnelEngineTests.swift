//
//  NIOTunnelEngineTests.swift
//  sshconfigmanagerTests
//
//  Exercises the in-process SSH tunnel engine (NIOTunnelEngine, an SSH *client*)
//  end-to-end against an embedded, loopback-only SSH *server* — no external sshd,
//  no network beyond 127.0.0.1. The server lives in the app target behind #if DEBUG
//  (EmbeddedSSHTestServer) because the test target deliberately doesn't link NIOSSH;
//  it is reached through a NIOSSH-free static factory.
//
//  Each test drives a real forward: it pushes bytes into the engine's local listener
//  and asserts the same bytes come back out, having actually traversed publickey auth,
//  host-key validation (TOFU), an SSH `direct-tcpip`/`forwarded-tcpip` channel, and
//  the byte glue. Ports are OS-assigned (bindPort: 0) so the suite is parallel-safe.
//

import Foundation
import Network
import SSHConfigCore
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

struct NIOTunnelEngineTests {
    /// A throwaway unencrypted ed25519 key (same one OpenSSHKeyTests uses). The
    /// embedded server accepts any publickey, so any valid key authenticates.
    private let clientPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACCyAn5NRmG+y/ppGE5TkyYYq5u2dAUOXv2R/4h/iDWsKQAAAJidu9d1nbvX
        dQAAAAtzc2gtZWQyNTUxOQAAACCyAn5NRmG+y/ppGE5TkyYYq5u2dAUOXv2R/4h/iDWsKQ
        AAAEDovZ9fte4yiNTzU5CmKigp+BjeATCils/78K5rgql9qLICfk1GYb7L+mkYTlOTJhir
        m7Z0BQ5e/ZH/iH+INawpAAAAEXR1bm5lbC10ZXN0QGxvY2FsAQIDBA==
        -----END OPENSSH PRIVATE KEY-----
        """

    /// A throwaway unencrypted RSA-2048 key — exercises the RSA auth path
    /// (NIOSSHRSA custom key + rsa-sha2-256) end-to-end through the engine.
    private let rsaClientPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
        NhAAAAAwEAAQAAAQEA0W6xEDkrdKfs24OeK5z/iSyjBJkk4ICU48qETI3Ukk+Jc93HDMgK
        o3LFRQt3YkkJdGkGqkAK6ZNQqpMsS6cYWlcbiK+TAjrsf+fdEChjVst8SJ6a7zg9Uewib5
        MOvkiuXDNaOr83i71HKwnMqGPkPkig1WxeYnVB4LBjp2QUQkGhCyOKeML7U6GpgBYVVt6H
        qlxWufolGF6mxC8xJfgDileULX9qayH2urDWRfGC4ufHyUr+ezqHU785bDj+4JMdsW7ybF
        rJnHlFLXifJ4ar3PCEuiCwKX8k8VkrYucHz+G2KcVh+DFVYHj1yZwpCRpJEgqXLGsOIHex
        oaxb4yNyHQAAA8ia9gVVmvYFVQAAAAdzc2gtcnNhAAABAQDRbrEQOSt0p+zbg54rnP+JLK
        MEmSTggJTjyoRMjdSST4lz3ccMyAqjcsVFC3diSQl0aQaqQArpk1CqkyxLpxhaVxuIr5MC
        Oux/590QKGNWy3xInprvOD1R7CJvkw6+SK5cM1o6vzeLvUcrCcyoY+Q+SKDVbF5idUHgsG
        OnZBRCQaELI4p4wvtToamAFhVW3oeqXFa5+iUYXqbELzEl+AOKV5Qtf2prIfa6sNZF8YLi
        58fJSv57OodTvzlsOP7gkx2xbvJsWsmceUUteJ8nhqvc8IS6ILApfyTxWSti5wfP4bYpxW
        H4MVVgePXJnCkJGkkSCpcsaw4gd7GhrFvjI3IdAAAAAwEAAQAAAQBqr7GhKw5ZAcYl2Ll1
        TCfcUBHHIOBpQPcXxy139fQoiD3j+UER4MGSm7+kOYAaYExhsbLEfZVRgUrhadFxxHAibS
        dIjPAdfbjGO24gcgKQz13DfJA+dm6+UcUFA2vKQSoZK8u2C3yXQdeENBy+VwyJMeREdEzs
        aQEjHZfWSKQNT4aQJV8qndVVsBZYnBKeuO2qlpoPG7xUYE0MqQi0RlCoN2PjckKJ7paOwL
        EyZ7zrjR6rmEpjjgZCOxMXMU1Jh+22HXdFhodRwUH87IAhFNq6R1i8IVQpGGgEYLw4WzPj
        +k8HOHQiJrzkLPzkqCTjd0axRXVqvTbiTjk0Bl2D2SwhAAAAgQDMApoJGf3VUx5do5asSp
        jvz1BF82SXDwhuA1Zh/YN2kXoPLqUJVoykuC3fUTAjlhOxAd/vEdpDCbdk58sPQvB3qJrB
        wwjpc5F70NcHiojkbRnIi5iObp+p3F551qDJQMNvtUOCdjmSYVrFIJyMAdVioO7rOxB68S
        D1Bet4f9pWwAAAAIEA/N9CY4/Gv2DXpNJeY+sVq+X5qMjqTz7rljIJ3fdshTLm1jHYS3Y4
        JoPYS3AQSjGBxSc7H7v+njGY3NIioLqrPTiRgpus0MkBsJerNtc4fbPWIxXMSWnP+FosSX
        fxIK1pjpNMSs9slFYMPbO/xtxkoG/so1TdSyY223oyhZkZ+lUAAACBANQF4HeWH6dQNtYS
        +Mc7EJsk2yAPjUZRGQ+REF9yzHNdSnJedoc39GY1JjiAjqIkhQLCB9lxHaNto89C3AxOvK
        B3TpeY7xVHvfHriSskA7WEYES8tMWheahVIbp819t4VdrpBjQ9YaapvvtqBpuM65B5eY7l
        vhq0V51W2F2NmHCpAAAADnJzYS10ZXN0QGxvY2FsAQIDBA==
        -----END OPENSSH PRIVATE KEY-----
        """

    // MARK: - -L: a local listener forwards bytes through the SSH link to a target

    @Test func localForwardRoundTripsBytesThroughTheTunnel() async throws {
        let server = try await EmbeddedSSHTestServer.start()
        defer { server.shutdown() }
        let (echo, echoPort) = try await startEchoServer()
        defer { echo.cancel() }

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            mode: .local, pem: clientPEM, passphrase: nil,
            sshHost: "127.0.0.1", sshPort: server.port, username: "test",
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: "127.0.0.1", targetPort: echoPort)
        defer { connection.shutdown() }

        let localPort = try await startAndAwaitLocalPort(connection)

        // Bytes pushed into the local listener must come back from the echo server,
        // proving auth + direct-tcpip + glue all work for real.
        let payload = Data("hello-through-the-tunnel".utf8)
        let reply = try #require(
            await roundTrip(localPort: localPort, send: payload, expect: payload.count),
            "no reply through the -L tunnel")
        #expect(reply == payload)

        // Throughput counters should reflect the bytes that crossed the SSH link.
        let counts = connection.byteCounts
        #expect(counts.out >= UInt64(payload.count))
        #expect(counts.in >= UInt64(payload.count))
    }

    /// Same -L round trip, but authenticating with an **RSA** key — exercises the
    /// NIOSSHRSA custom-key path (parse → offer as rsa-sha2-256 → sign → server
    /// verify) end-to-end, plus RSA registration on the connection-building path.
    @Test func localForwardRoundTripsBytesThroughTheTunnelWithRSAKey() async throws {
        let server = try await EmbeddedSSHTestServer.start()
        defer { server.shutdown() }
        let (echo, echoPort) = try await startEchoServer()
        defer { echo.cancel() }

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            mode: .local, pem: rsaClientPEM, passphrase: nil,
            sshHost: "127.0.0.1", sshPort: server.port, username: "test",
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: "127.0.0.1", targetPort: echoPort)
        defer { connection.shutdown() }

        let localPort = try await startAndAwaitLocalPort(connection)
        let payload = Data("hello-through-the-rsa-tunnel".utf8)
        let reply = try #require(
            await roundTrip(localPort: localPort, send: payload, expect: payload.count),
            "no reply through the RSA -L tunnel")
        #expect(reply == payload)
    }

    // MARK: - -D: a SOCKS5 listener forwards to a client-chosen target

    @Test func dynamicSOCKS5ForwardRoundTripsBytes() async throws {
        let server = try await EmbeddedSSHTestServer.start()
        defer { server.shutdown() }
        let (echo, echoPort) = try await startEchoServer()
        defer { echo.cancel() }

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            mode: .dynamic, pem: clientPEM, passphrase: nil,
            sshHost: "127.0.0.1", sshPort: server.port, username: "test",
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: "", targetPort: 0) // -D takes the target from each CONNECT
        defer { connection.shutdown() }

        let localPort = try await startAndAwaitLocalPort(connection)

        // Drive a minimal SOCKS5 CONNECT to the echo server, then a round-trip.
        let payload = Data("socks5-payload".utf8)
        let reply = try #require(
            await socks5RoundTrip(
                localPort: localPort, target: "127.0.0.1", targetPort: echoPort,
                send: payload),
            "no reply through the -D SOCKS5 tunnel")
        #expect(reply == payload)
    }

    /// Regression guard for audit #30: an optimistic-data SOCKS5 client (Tor is
    /// the canonical example) pipelines its payload right after the CONNECT
    /// request instead of waiting for the reply first. Those bytes land while
    /// the direct-tcpip channel is still opening — `SOCKS5InboundHandler` used
    /// to remove itself on success without ever flushing what had piled up in
    /// `buffer` during that gap, silently dropping the payload.
    @Test func socks5OptimisticDataDuringConnectIsNotLost() async throws {
        let server = try await EmbeddedSSHTestServer.start()
        defer { server.shutdown() }
        let (echo, echoPort) = try await startEchoServer()
        defer { echo.cancel() }

        // A real (local/embedded) direct-tcpip channel-open completes near-
        // instantly, which makes the `.connecting`-window race this test
        // targets unreproducible on realistic timing — widen it deterministically.
        NIOTunnelConnection.openDirectTCPIPDelayForTesting = .milliseconds(200)
        defer { NIOTunnelConnection.openDirectTCPIPDelayForTesting = .zero }

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            mode: .dynamic, pem: clientPEM, passphrase: nil,
            sshHost: "127.0.0.1", sshPort: server.port, username: "test",
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: "", targetPort: 0)
        defer { connection.shutdown() }

        let localPort = try await startAndAwaitLocalPort(connection)

        let payload = Data("optimistic-payload".utf8)
        let reply = try #require(
            await socks5OptimisticRoundTrip(
                localPort: localPort, target: "127.0.0.1", targetPort: echoPort,
                send: payload),
            "no reply through the -D SOCKS5 tunnel for pipelined optimistic data")
        #expect(reply == payload)
    }

    // MARK: - -R: the server listens; inbound connections are forwarded to a local target

    @Test func remoteForwardRoundTripsBytesBackToALocalTarget() async throws {
        let server = try await EmbeddedSSHTestServer.start()
        defer { server.shutdown() }
        // The "local target" the -R forward delivers inbound connections to.
        let (echo, echoPort) = try await startEchoServer()
        defer { echo.cancel() }

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            mode: .remote, pem: clientPEM, passphrase: nil,
            sshHost: "127.0.0.1", sshPort: server.port, username: "test",
            bindHost: "127.0.0.1", bindPort: 0, // server picks the remote port
            targetHost: "127.0.0.1", targetPort: echoPort)
        defer { connection.shutdown() }

        // Wait for the remote listener (not a local one) to come up.
        switch await awaitTunnelStart(connection, timeout: 15) {
        case nil:
            Issue.record("-R tunnel did not become active within 15s")
            return
        case .failed(let reason):
            Issue.record("-R tunnel failed: \(reason)")
            return
        case .active: break
        }
        let remotePort = try #require(connection.remoteBoundPort, "no remote bound port reported")

        // Connecting to the server's remote listener should reach our local echo via
        // a forwarded-tcpip channel, and the bytes should come straight back.
        let payload = Data("remote-forward".utf8)
        let reply = try #require(
            await roundTrip(localPort: remotePort, send: payload, expect: payload.count),
            "no reply through the -R tunnel")
        #expect(reply == payload)
    }

    // MARK: - Helpers

    /// Starts a connection in `-L`/`-D` mode and returns the OS-assigned local port
    /// once it reports `.active`, failing the test on timeout or error.
    private func startAndAwaitLocalPort(
        _ connection: NIOTunnelConnection,
        timeout: TimeInterval = 15
    ) async throws -> Int {
        switch await awaitTunnelStart(connection, timeout: timeout) {
        case nil:
            throw TestFailure("tunnel did not become active within \(Int(timeout))s")
        case .failed(let reason):
            throw TestFailure("tunnel failed: \(reason)")
        case .active:
            return try #require(connection.boundPort, "tunnel active but no bound port reported")
        }
    }

    /// Connects to a loopback TCP port, sends `send`, and reads up to `expect` bytes
    /// back. Returns the echoed bytes (or nil on failure/timeout).
    private func roundTrip(
        localPort: Int, send: Data, expect: Int,
        timeout: TimeInterval = 15
    ) async -> Data? {
        let conn = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(localPort))!, using: .tcp)
        let result = await awaitResult(timeout: timeout) { finish in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(
                        content: send,
                        completion: .contentProcessed { _ in
                            conn.receive(minimumIncompleteLength: expect, maximumLength: expect) { data, _, _, _ in
                                finish(data)
                            }
                        })
                case .failed:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
        conn.cancel()
        return result
    }

    /// Minimal SOCKS5 client: no-auth greeting → CONNECT(target) → send/receive a
    /// round-trip. Returns the echoed bytes (or nil).
    private func socks5RoundTrip(
        localPort: Int, target: String, targetPort: Int,
        send: Data, timeout: TimeInterval = 15
    ) async -> Data? {
        let conn = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(localPort))!, using: .tcp)
        let host = Array(target.utf8)
        let connectReq = Data(
            [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + host
                + [UInt8(targetPort >> 8), UInt8(targetPort & 0xff)])

        let result = await awaitResult(timeout: timeout) { (finish: @escaping @Sendable (Data?) -> Void) in
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
                        recv(2) { _ in // method selection
                            conn.send(
                                content: connectReq,
                                completion: .contentProcessed { _ in
                                    recv(10) { _ in // CONNECT reply
                                        conn.send(
                                            content: send,
                                            completion: .contentProcessed { _ in
                                                recv(send.count) { data in finish(data) }
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

    /// Same SOCKS5 CONNECT-then-echo flow as `socks5RoundTrip`, but sends the
    /// greeting, CONNECT request, and payload all in one shot instead of
    /// waiting for each reply first — the optimistic-data client shape audit
    /// #30 covers. Still reads the method-selection and CONNECT replies (the
    /// bytes are there in the stream regardless of how eagerly the client
    /// wrote), then the echoed payload.
    private func socks5OptimisticRoundTrip(
        localPort: Int, target: String, targetPort: Int,
        send: Data, timeout: TimeInterval = 15
    ) async -> Data? {
        let conn = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(localPort))!, using: .tcp)
        let host = Array(target.utf8)
        let connectReq = Data(
            [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + host
                + [UInt8(targetPort >> 8), UInt8(targetPort & 0xff)])
        let greeting = Data([0x05, 0x01, 0x00])

        let result = await awaitResult(timeout: timeout) { (finish: @escaping @Sendable (Data?) -> Void) in
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
                    content: greeting,
                    completion: .contentProcessed { _ in
                        recv(2) { _ in // method selection — confirms the server parsed the greeting
                            conn.send(
                                content: connectReq,
                                completion: .contentProcessed { _ in
                                    // Don't wait for the CONNECT reply before sending the payload
                                    // (that's `socks5RoundTrip`'s well-behaved-client shape). A
                                    // short delay — instead of firing the payload write back to
                                    // back with the request — makes it very likely the server has
                                    // already parsed the request and kicked off the (async)
                                    // direct-tcpip channel-open by the time this lands, so the
                                    // payload reliably arrives inside the `.connecting` window
                                    // audit #30 covers, rather than racing into the same read as
                                    // the request and landing in the `earlyData` snapshot instead
                                    // (which already worked before this fix).
                                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                                        conn.send(
                                            content: send,
                                            completion: .contentProcessed { _ in
                                                recv(10) { _ in // CONNECT reply
                                                    recv(send.count) { data in finish(data) }
                                                }
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
}
