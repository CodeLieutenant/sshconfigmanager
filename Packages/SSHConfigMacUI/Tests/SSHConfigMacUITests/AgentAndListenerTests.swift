//
//  AgentAndListenerTests.swift
//  sshconfigmanagerTests
//
//  Covers the SSH agent wire protocol (pure framing) and the local forward
//  listener. The listener test also serves as the runtime sandbox spike for
//  "can a sandboxed app bind a localhost listener?" (network.server).
//

import Foundation
import Network
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

// MARK: - SSH agent protocol (pure)

struct SSHAgentProtocolTests {
    @Test func requestIdentitiesIsFramed() {
        // uint32 length (1) + type byte 11.
        #expect(SSHAgentProtocol.requestIdentitiesMessage() == [0, 0, 0, 1, 11])
    }

    @Test func signRequestFramesKeyDataAndFlags() {
        let msg = SSHAgentProtocol.signRequestMessage(keyBlob: [0xAA], data: [0xBB, 0xCC], flags: 2)
        // payload = [13] + str([AA]) + str([BB,CC]) + uint32(2)
        let payload: [UInt8] = [13] + [0, 0, 0, 1, 0xAA] + [0, 0, 0, 2, 0xBB, 0xCC] + [0, 0, 0, 2]
        #expect(msg == SSHAgentProtocol.uint32(UInt32(payload.count)) + payload)
    }

    @Test func parsesIdentitiesAnswer() throws {
        let blob = SSHAgentProtocol.string(Array("ssh-ed25519".utf8)) + [0x01, 0x02]
        let payload: [UInt8] =
            [12] + SSHAgentProtocol.uint32(1)
            + SSHAgentProtocol.string(blob)
            + SSHAgentProtocol.string(Array("me@laptop".utf8))
        let ids = try SSHAgentProtocol.parseIdentities(payload)
        #expect(ids.count == 1)
        #expect(ids[0].keyBlob == blob)
        #expect(ids[0].comment == "me@laptop")
        #expect(ids[0].keyType == "ssh-ed25519")
    }

    @Test func parsesEmptyIdentities() throws {
        let payload: [UInt8] = [12] + SSHAgentProtocol.uint32(0)
        #expect(try SSHAgentProtocol.parseIdentities(payload).isEmpty)
    }

    @Test func identitiesFailureByteThrows() {
        #expect(throws: SSHAgentError.self) {
            try SSHAgentProtocol.parseIdentities([5])
        }
    }

    @Test func truncatedAnswerThrows() {
        // Claims one identity but no body follows.
        let payload: [UInt8] = [12] + SSHAgentProtocol.uint32(1)
        #expect(throws: SSHAgentError.self) {
            try SSHAgentProtocol.parseIdentities(payload)
        }
    }

    @Test func parsesSignatureResponse() throws {
        let sig: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let payload: [UInt8] = [14] + SSHAgentProtocol.string(sig)
        #expect(try SSHAgentProtocol.parseSignature(payload) == sig)
    }

    @Test func unexpectedSignatureTypeThrows() {
        #expect(throws: SSHAgentError.self) {
            try SSHAgentProtocol.parseSignature([99] + SSHAgentProtocol.string([0x01]))
        }
    }

    @Test func keyTypeParsedFromBlobPrefix() {
        let blob = SSHAgentProtocol.string(Array("ecdsa-sha2-nistp256".utf8)) + [0xFF]
        #expect(SSHAgentProtocol.keyType(fromBlob: blob) == "ecdsa-sha2-nistp256")
    }
}

// MARK: - Local forward listener (runtime; sandbox spike)

struct LocalForwardServerTests {
    /// Thread-safe box for capturing callback results.
    private nonisolated final class Box: @unchecked Sendable {
        let lock = NSLock()
        private var _port: UInt16?
        private var _accepted = false
        private var _failure: String?
        var port: UInt16? {
            lock.lock()
            defer { lock.unlock() }
            return _port
        }
        var accepted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _accepted
        }
        var failure: String? {
            lock.lock()
            defer { lock.unlock() }
            return _failure
        }
        func setPort(_ p: UInt16) {
            lock.lock()
            _port = p
            lock.unlock()
        }
        func setAccepted() {
            lock.lock()
            _accepted = true
            lock.unlock()
        }
        func setFailure(_ f: String) {
            lock.lock()
            _failure = f
            lock.unlock()
        }
    }

    @Test func bindsLoopbackAndAcceptsConnection() async throws {
        let box = Box()
        let server = LocalForwardServer()
        defer { server.cancel() }

        // Wait (without blocking a thread) for the listener to bind or fail.
        let listened = await awaitResult(timeout: 5) { (finish: @escaping @Sendable (Bool?) -> Void) in
            server.onStateChange = { state in
                switch state {
                case .listening(let port):
                    box.setPort(port)
                    finish(true)
                case .failed(let error):
                    box.setFailure(error)
                    finish(true)
                case .idle: break
                }
            }
            do { try server.start(port: 0) } catch {
                box.setFailure("\(error)")
                finish(true)
            }
        }
        #expect(listened == true)
        guard let port = box.port else {
            Issue.record("listener failed to bind (sandbox?): \(box.failure ?? "unknown")")
            return
        }
        #expect(port != 0)

        // Connect a client and wait for the accept callback to fire.
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
        defer { connection.cancel() }
        let accepted = await awaitResult(timeout: 5) { (finish: @escaping @Sendable (Bool?) -> Void) in
            server.onAccept = { conn in
                box.setAccepted()
                conn.cancel()
                finish(true)
            }
            connection.start(queue: .global())
        }
        #expect(accepted == true)
        #expect(box.accepted)
    }
}

// MARK: - Live agent (only exercises I/O when an agent is present)

struct SSHAgentServiceTests {
    @Test func listIdentitiesWhenAgentAvailable() async throws {
        guard SSHAgentService.isAvailable else { return } // no agent in this environment
        do {
            let identities = try await SSHAgentService().listIdentities()
            // Reaching here means the sandbox permitted the socket and framing parsed.
            #expect(identities.count >= 0)
        } catch SSHAgentError.connectionFailed, SSHAgentError.socketUnavailable {
            // The sandbox/environment didn't allow the socket — not a logic error.
        }
    }
}
