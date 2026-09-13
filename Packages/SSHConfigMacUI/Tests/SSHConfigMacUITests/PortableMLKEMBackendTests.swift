//
//  PortableMLKEMBackendTests.swift
//  SSHConfigMacUITests
//
//  The app uses CryptoKit's ML-KEM-768 on macOS 26 and a pure-Swift one below it. Two
//  implementations of the same key exchange is only safe if they are byte-compatible: a Mac
//  on either side of that line has to reach the same servers, and a server has to be able to
//  encapsulate against whichever encapsulation key we sent.
//
//  So these cross the two in both directions. FIPS 203 fixes every size, and a mismatch in
//  either shows up as a shared secret that does not agree.
//

import Crypto
import Foundation
import NIOSSH
import SSHConfigEngine
import SwiftKyber
import Testing

@testable import SSHConfigMacUI

struct PortableMLKEMBackendTests {
    private let portable = PortableMLKEM768Backend()

    /// FIPS 203 ML-KEM-768. A backend that disagrees is not interoperable.
    @Test func producesFIPS203Sizes() throws {
        let pair = try portable.generateKeyPair()
        #expect(pair.encapsulationKey.count == 1184)

        let result = try portable.encapsulate(encapsulationKey: pair.encapsulationKey)
        #expect(result.ciphertext.count == 1088)
        #expect(result.sharedSecret.count == 32)
    }

    @Test func roundTripsAgainstItself() throws {
        let pair = try portable.generateKeyPair()
        let result = try portable.encapsulate(encapsulationKey: pair.encapsulationKey)
        #expect(try pair.privateKey.decapsulate(result.ciphertext) == result.sharedSecret)
    }

    /// We generate the keypair, the peer encapsulates. This is the direction that matters
    /// for a client: an older Mac sends its encapsulation key and a modern server (or a
    /// CryptoKit peer) must be able to encapsulate against it.
    @available(macOS 26.0, *)
    @Test func cryptoKitCanEncapsulateAgainstAPortableKey() throws {
        let pair = try portable.generateKeyPair()

        let cryptoKitResult = try MLKEM768.PublicKey(rawRepresentation: pair.encapsulationKey).encapsulate()
        let theirSecret = cryptoKitResult.sharedSecret.withUnsafeBytes { Array($0) }
        let ourSecret = try pair.privateKey.decapsulate(Array(cryptoKitResult.encapsulated))

        #expect(ourSecret == theirSecret)
        #expect(ourSecret.count == 32)
    }

    /// The other direction: CryptoKit generates, the portable backend encapsulates. This is
    /// what happens when the app acts as the server side of the exchange.
    @available(macOS 26.0, *)
    @Test func portableCanEncapsulateAgainstACryptoKitKey() throws {
        let cryptoKitKey = try MLKEM768.PrivateKey()

        let result = try portable.encapsulate(
            encapsulationKey: Array(cryptoKitKey.publicKey.rawRepresentation))
        let theirSecret = try cryptoKitKey.decapsulate(result.ciphertext).withUnsafeBytes { Array($0) }

        #expect(result.sharedSecret == theirSecret)
    }

    /// A truncated or padded encapsulation key must be rejected, not silently accepted.
    @Test func rejectsAMalformedEncapsulationKey() throws {
        let pair = try portable.generateKeyPair()
        #expect(throws: (any Error).self) {
            _ = try portable.encapsulate(encapsulationKey: Array(pair.encapsulationKey.dropLast()))
        }
        #expect(throws: (any Error).self) {
            _ = try portable.encapsulate(encapsulationKey: pair.encapsulationKey + [0])
        }
    }

    /// Registering the portable backend must make the hybrid method reachable — that is the
    /// whole point of the seam on systems whose CryptoKit has no ML-KEM.
    @Test func registeringABackendOffersTheHybridMethod() {
        // The registry is global, so put it back — otherwise every later test in this
        // process silently runs on the portable implementation.
        defer { NIOSSHMLKEM.registerBackend(nil) }
        NIOSSHMLKEM.registerBackend(PortableMLKEM768Backend())
        #expect(SSHClientConfiguration.supportedKeyExchangeAlgorithms.contains("mlkem768x25519-sha256"))
    }
}
