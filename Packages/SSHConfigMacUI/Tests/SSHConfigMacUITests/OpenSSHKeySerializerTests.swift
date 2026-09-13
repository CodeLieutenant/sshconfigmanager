//
//  OpenSSHKeySerializerTests.swift
//  sshconfigmanagerTests
//
//  Round-trips the serializer against the parser it inverts: material →
//  OpenSSHKeySerializer → OpenSSHPrivateKey.parse must recover the same material,
//  and the `.pub` it emits must parse through SSHKeyService. This is the decisive
//  correctness check — if the bytes are wrong, the existing (independently tested)
//  parser rejects them.
//

import CryptoKit
import Foundation
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

struct OpenSSHKeySerializerTests {
    private let salt: [UInt8] = Array(0..<16)
    private let check: UInt32 = 0x0A0B_0C0D

    // MARK: - Ed25519

    @Test func ed25519UnencryptedRoundTrips() throws {
        let key = Curve25519.Signing.PrivateKey()
        let seed = [UInt8](key.rawRepresentation)
        let pub = [UInt8](key.publicKey.rawRepresentation)
        let material = OpenSSHKeySerializer.Material.ed25519(seed: seed, pub: pub)

        let pem = try OpenSSHKeySerializer.privateKeyPEM(
            for: material, comment: "t@h", encryption: .none, checkBytes: check)
        let parsed = try OpenSSHPrivateKey.parse(pem: pem)

        #expect(parsed.keyType == "ssh-ed25519")
        #expect(parsed.ed25519Seed == seed)
        #expect(parsed.publicKey == pub)
    }

    @Test func ed25519EncryptedRoundTripsAndRejectsWrongPassphrase() throws {
        let key = Curve25519.Signing.PrivateKey()
        let seed = [UInt8](key.rawRepresentation)
        let pub = [UInt8](key.publicKey.rawRepresentation)
        let material = OpenSSHKeySerializer.Material.ed25519(seed: seed, pub: pub)

        let pem = try OpenSSHKeySerializer.privateKeyPEM(
            for: material, comment: "t@h",
            encryption: .encrypted(passphrase: "hunter2", salt: salt, rounds: 16),
            checkBytes: check)

        // Header-only check sees it as encrypted.
        #expect(OpenSSHPrivateKey.isEncrypted(pem: pem) == true)

        // Correct passphrase recovers the seed.
        let parsed = try OpenSSHPrivateKey.parse(pem: pem, passphrase: "hunter2")
        #expect(parsed.ed25519Seed == seed)

        // Wrong / missing passphrase is rejected with the right error.
        #expect(throws: OpenSSHKeyError.incorrectPassphrase) {
            try OpenSSHPrivateKey.parse(pem: pem, passphrase: "wrong")
        }
        #expect(throws: OpenSSHKeyError.passphraseRequired) {
            try OpenSSHPrivateKey.parse(pem: pem)
        }
    }

    // MARK: - ECDSA (all three curves)

    @Test(arguments: [ECDSACurve.p256, .p384, .p521])
    func ecdsaUnencryptedRoundTrips(curve: ECDSACurve) throws {
        let (material, expectedScalar, expectedPoint) = makeECDSAMaterial(curve)

        let pem = try OpenSSHKeySerializer.privateKeyPEM(
            for: material, comment: "ec@h", encryption: .none, checkBytes: check)
        let parsed = try OpenSSHPrivateKey.parse(pem: pem)

        #expect(parsed.keyType == "ecdsa-sha2-\(curve.rawValue)")
        guard case .ecdsa(let parsedCurve, let parsedScalar) = parsed.material else {
            Issue.record("expected ecdsa material")
            return
        }
        #expect(parsedCurve == curve)
        #expect(parsedScalar == expectedScalar)
        #expect(parsed.publicKey == expectedPoint)
    }

    @Test func ecdsaEncryptedRoundTrips() throws {
        let (material, expectedScalar, _) = makeECDSAMaterial(.p256)
        let pem = try OpenSSHKeySerializer.privateKeyPEM(
            for: material, comment: "ec@h",
            encryption: .encrypted(passphrase: "s3cret", salt: salt, rounds: 16),
            checkBytes: check)

        let parsed = try OpenSSHPrivateKey.parse(pem: pem, passphrase: "s3cret")
        guard case .ecdsa(_, let parsedScalar) = parsed.material else {
            Issue.record("expected ecdsa material")
            return
        }
        #expect(parsedScalar == expectedScalar)
    }

    // MARK: - Public key line

    @Test func publicKeyLineParsesAndFingerprints() throws {
        let key = Curve25519.Signing.PrivateKey()
        let material = OpenSSHKeySerializer.Material.ed25519(
            seed: [UInt8](key.rawRepresentation), pub: [UInt8](key.publicKey.rawRepresentation))

        let line = OpenSSHKeySerializer.publicKeyLine(for: material, comment: "alice@laptop")
        let url = URL(fileURLWithPath: "/tmp/id_ed25519.pub")
        let parsed = try #require(SSHKeyService.parsePublicKey(line, url: url, siblings: []))

        #expect(parsed.algorithm == "ssh-ed25519")
        #expect(parsed.comment == "alice@laptop")
        #expect(parsed.fingerprint.hasPrefix("SHA256:"))
    }

    // MARK: - End-to-end through the generator

    @Test func generatorProducesParseableEncryptedKeyWithMatchingPub() throws {
        let generated = try SSHKeyGenerator.generate(
            algorithm: .ed25519, comment: "gen@host", passphrase: "pp")

        // The private key parses with the passphrase…
        let parsed = try OpenSSHPrivateKey.parse(pem: generated.privateKeyPEM, passphrase: "pp")
        let seed = try #require(parsed.ed25519Seed)

        // …and the emitted `.pub` is the public key for exactly that private key.
        let derivedPub = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey
        let pubField = generated.publicKeyText
            .split(separator: " ", maxSplits: 2).map(String.init)
        let blob = try #require(Data(base64Encoded: pubField[1]))
        // blob = string("ssh-ed25519") + string(pub32); the trailing 32 bytes are the point.
        #expect(Array(blob.suffix(32)) == [UInt8](derivedPub.rawRepresentation))
    }

    // MARK: - Helpers

    private func makeECDSAMaterial(_ curve: ECDSACurve)
        -> (OpenSSHKeySerializer.Material, scalar: [UInt8], point: [UInt8])
    {
        let scalar: [UInt8]
        let point: [UInt8]
        switch curve {
        case .p256:
            let k = P256.Signing.PrivateKey()
            scalar = [UInt8](k.rawRepresentation)
            point = [UInt8](k.publicKey.x963Representation)
        case .p384:
            let k = P384.Signing.PrivateKey()
            scalar = [UInt8](k.rawRepresentation)
            point = [UInt8](k.publicKey.x963Representation)
        case .p521:
            let k = P521.Signing.PrivateKey()
            scalar = [UInt8](k.rawRepresentation)
            point = [UInt8](k.publicKey.x963Representation)
        }
        return (.ecdsa(curve: curve, scalar: scalar, point: point), scalar, point)
    }
}
