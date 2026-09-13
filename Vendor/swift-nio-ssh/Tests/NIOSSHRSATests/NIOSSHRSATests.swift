//===----------------------------------------------------------------------===//
//
//  NIOSSHRSATests.swift
//
//  End-to-end tests for the NIOSSHRSA custom-key implementation: sign/verify,
//  SSH wire (de)serialization of signatures and public keys, and RFC 8332
//  algorithm naming. Run with `swift test --filter NIOSSHRSATests`.
//
//  NIOSSH patch (sshconfigmanager).
//

import NIOCore
import NIOSSH
import XCTest
import _CryptoExtras

@testable import NIOSSHRSA

final class NIOSSHRSATests: XCTestCase {
    /// Builds a fresh RSA key wrapped in our NIOSSHRSA type.
    private func makeKey() throws -> Insecure.RSA.PrivateKey {
        let backing = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        return try Insecure.RSA.PrivateKey(pemRepresentation: backing.pemRepresentation)
    }

    func testSignVerifyRoundTrip() throws {
        let key = try makeKey()
        let message = Array("the quick brown fox".utf8)
        let signature = try key.signature(for: message)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: message))
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: Array("tampered".utf8)))
    }

    /// Directly exercises the public-key component constructor
    /// `Insecure.RSA.PublicKey(modulus:publicExponent:)` (the shape used when
    /// reading a key off the wire): a key rebuilt from raw (n, e) must verify a
    /// signature from the matching private key. The private-key component
    /// constructor `init(modulus:publicExponent:privateExponent:prime1:prime2:)` is
    /// covered end-to-end by the app's RSA tunnel test (parse → construct → sign →
    /// server-verify).
    func testPublicKeyComponentConstructorRoundTrips() throws {
        let backing = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let priv = try Insecure.RSA.PrivateKey(pemRepresentation: backing.pemRepresentation)

        let primitives = try backing.publicKey.getKeyPrimitives()
        let pub = try Insecure.RSA.PublicKey(modulus: primitives.modulus,
                                             publicExponent: primitives.publicExponent)

        let message = Array("component-constructor".utf8)
        let signature = try priv.signature(for: message)
        XCTAssertTrue(pub.isValidSignature(signature, for: message))
        XCTAssertFalse(pub.isValidSignature(signature, for: Array("other".utf8)))
    }

    func testRFC8332AlgorithmNames() {
        XCTAssertEqual(Insecure.RSA.PublicKey.publicKeyPrefix, "ssh-rsa")
        XCTAssertEqual(Insecure.RSA.PublicKey.publicKeyAuthAlgorithmName, "rsa-sha2-256")
        XCTAssertEqual(Insecure.RSA.Signature.signaturePrefix, "rsa-sha2-256")
        XCTAssertEqual(Insecure.RSA.Signature.acceptedSignaturePrefixes, ["rsa-sha2-256"])
    }

    func testSignatureWireRoundTrip() throws {
        let key = try makeKey()
        let signature = try key.signature(for: Array("hello".utf8))
        var buffer = ByteBuffer()
        XCTAssertGreaterThan(signature.write(to: &buffer), 0)
        let reread = try Insecure.RSA.Signature.read(from: &buffer)
        XCTAssertEqual(reread.rawRepresentation, signature.rawRepresentation)
    }

    /// The custom key must serialize to, and parse back from, the standard
    /// OpenSSH `ssh-rsa` representation via NIOSSH (exercising the registry).
    func testPublicKeyWireRoundTripThroughNIOSSH() throws {
        Insecure.RSA.register()
        let key = try makeKey()
        let priv = NIOSSHPrivateKey(custom: key)

        let openSSH = String(openSSHPublicKey: priv.publicKey)
        XCTAssertTrue(openSSH.hasPrefix("ssh-rsa "))

        let reparsed = try NIOSSHPublicKey(openSSHPublicKey: openSSH)
        XCTAssertEqual(String(openSSHPublicKey: reparsed), openSSH)
    }
}
