//===----------------------------------------------------------------------===//
//
// This file is part of the vendored, patched swift-nio-ssh. See Vendor/PATCH.md.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSSH

/// `mlkem768x25519-sha256` is offered whenever an ML-KEM backend is *registered*, which is
/// not the same as that backend being able to produce a keypair. A backend that registers
/// and then fails must abort the handshake, not the process: the peer chooses the key
/// exchange method, so a trap here is a remote peer deciding when the app dies.
final class MLKEMBackendFailureTests: XCTestCase {
    struct BackendFailure: Error {}

    /// Registers fine, generates nothing.
    private struct FailingBackend: NIOSSHMLKEM768Backend {
        func generateKeyPair() throws -> (encapsulationKey: [UInt8], privateKey: any NIOSSHMLKEM768PrivateKey) {
            throw BackendFailure()
        }

        func encapsulate(encapsulationKey: [UInt8]) throws -> (sharedSecret: [UInt8], ciphertext: [UInt8]) {
            throw BackendFailure()
        }
    }

    private func makeClient() -> SSHKeyExchangeStateMachine {
        SSHKeyExchangeStateMachine(
            allocator: ByteBufferAllocator(),
            loop: EmbeddedEventLoop(),
            role: .client(
                SSHClientConfiguration(
                    userAuthDelegate: ExplodingAuthDelegate(),
                    serverAuthDelegate: AcceptAllHostKeysDelegate()
                )),
            remoteVersion: Constants.version,
            protectionSchemes: [AES256GCMOpenSSHTransportProtection.self],
            previousSessionIdentifier: nil
        )
    }

    private func serverMessage(offering methods: [Substring]) -> SSHMessage.KeyExchangeMessage {
        SSHMessage.KeyExchangeMessage(
            cookie: ByteBufferAllocator().buffer(capacity: 16),
            keyExchangeAlgorithms: methods,
            serverHostKeyAlgorithms: ["ssh-ed25519"],
            encryptionAlgorithmsClientToServer: ["aes256-gcm@openssh.com"],
            encryptionAlgorithmsServerToClient: ["aes256-gcm@openssh.com"],
            macAlgorithmsClientToServer: ["hmac-sha2-256"],
            macAlgorithmsServerToClient: ["hmac-sha2-256"],
            compressionAlgorithmsClientToServer: ["none"],
            compressionAlgorithmsServerToClient: ["none"],
            languagesClientToServer: [],
            languagesServerToClient: [],
            firstKexPacketFollows: false
        )
    }

    /// The whole point: this used to be `preconditionFailure("ML-KEM key generation failed")`,
    /// so a server offering only the hybrid crashed the app.
    func testAFailingBackendThrowsRatherThanTrapping() throws {
        NIOSSHMLKEM.registerBackend(FailingBackend())
        defer { NIOSSHMLKEM.registerBackend(nil) }

        var client = self.makeClient()
        XCTAssertEqual(client.createKeyExchangeMessage().keyExchangeAlgorithms.first, "mlkem768x25519-sha256")

        client.send(keyExchange: client.createKeyExchangeMessage())
        XCTAssertThrowsError(try client.handle(keyExchange: self.serverMessage(offering: ["mlkem768x25519-sha256"])))
    }

    /// A failing backend must not be fatal when the server can speak ECDH too — the
    /// hybrid is still offered first, so this pins that the failure is contained to the
    /// method rather than to the connection.
    func testTheHybridIsStillOfferedFirstWithAFailingBackend() throws {
        NIOSSHMLKEM.registerBackend(FailingBackend())
        defer { NIOSSHMLKEM.registerBackend(nil) }

        var client = self.makeClient()
        let offered = client.createKeyExchangeMessage().keyExchangeAlgorithms
        XCTAssertEqual(offered.first, "mlkem768x25519-sha256")
        XCTAssertTrue(offered.contains("curve25519-sha256"))

        // A server that prefers ECDH picks it, and nothing ever asks the broken backend.
        client.send(keyExchange: client.createKeyExchangeMessage())
        let response = try client.handle(keyExchange: self.serverMessage(offering: ["curve25519-sha256"]))
        guard case .some(.keyExchangeInit) = response?.first else {
            XCTFail("Expected an ECDH key exchange init, got \(String(describing: response))")
            return
        }
    }

    /// With no backend at all the method must not appear, or a server would negotiate
    /// something this client cannot perform.
    func testTheHybridIsNotOfferedWithoutABackend() {
        NIOSSHMLKEM.registerBackend(nil)
        guard NIOSSHMLKEM.backend == nil else {
            // macOS 26+ supplies CryptoKit's, so there is nothing to assert here.
            return
        }
        let client = self.makeClient()
        XCTAssertFalse(client.createKeyExchangeMessage().keyExchangeAlgorithms.contains("mlkem768x25519-sha256"))
    }
}
