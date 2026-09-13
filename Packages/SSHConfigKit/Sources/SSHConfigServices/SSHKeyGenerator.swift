//
//  SSHKeyGenerator.swift
//  sshconfigmanager
//
//  Generates a fresh SSH key pair in-process (no `ssh-keygen` subprocess — the App
//  Sandbox blocks it). CryptoKit produces the key material; `OpenSSHKeySerializer`
//  frames it into the on-disk `.pub` text and OpenSSH PEM. This is the only impure
//  layer: it draws the randomness (key material, check bytes, KDF salt) that the
//  serializer takes as input.
//

import Crypto
import Foundation
import SSHConfigCrypto

/// The algorithms the in-app generator can produce. ECDSA curves map onto the
/// same `ECDSACurve` the parser already understands; RSA is intentionally out of
/// scope here (it needs a separate Security-framework path).
public enum KeyAlgorithm: Hashable, CaseIterable, Identifiable, Sendable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521

    public var id: Self { self }

    /// Human label for the picker.
    public var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA (P-256)"
        case .ecdsaP384: return "ECDSA (P-384)"
        case .ecdsaP521: return "ECDSA (P-521)"
        }
    }

    /// The conventional `id_*` base filename `ssh-keygen` would choose.
    public var defaultFileName: String {
        switch self {
        case .ed25519: return "id_ed25519"
        case .ecdsaP256, .ecdsaP384, .ecdsaP521: return "id_ecdsa"
        }
    }
}

/// The two text artifacts to write to disk.
public nonisolated struct GeneratedKey {
    public let publicKeyText: String // the `.pub` one-liner (write 0644)
    public let privateKeyPEM: String // the OPENSSH PRIVATE KEY block (write 0600)
}

// `nonisolated`: pure key generation (swift-crypto + OpenSSH serializer), usable
// off the main actor.
public nonisolated enum SSHKeyGenerator {
    /// Default bcrypt_pbkdf rounds for encrypted keys — the `ssh-keygen` default.
    private static let defaultKDFRounds = 16

    /// Generates a key pair. `passphrase` (when non-empty) encrypts the private key
    /// with bcrypt_pbkdf + aes256-ctr; it is used only for this call and never
    /// retained.
    public static func generate(
        algorithm: KeyAlgorithm, comment: String, passphrase: String?
    ) throws -> GeneratedKey {
        let material = makeMaterial(for: algorithm)

        let encryption: OpenSSHKeySerializer.Encryption
        if let passphrase, !passphrase.isEmpty {
            encryption = .encrypted(
                passphrase: passphrase,
                salt: randomBytes(16),
                rounds: defaultKDFRounds)
        } else {
            encryption = .none
        }

        let checkBytes = UInt32.random(in: .min ... .max)
        let pem = try OpenSSHKeySerializer.privateKeyPEM(
            for: material, comment: comment,
            encryption: encryption, checkBytes: checkBytes)
        let pub = OpenSSHKeySerializer.publicKeyLine(for: material, comment: comment)

        return GeneratedKey(publicKeyText: pub, privateKeyPEM: pem)
    }

    // MARK: - Key material

    private static func makeMaterial(for algorithm: KeyAlgorithm) -> OpenSSHKeySerializer.Material {
        switch algorithm {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            return .ed25519(
                seed: [UInt8](key.rawRepresentation),
                pub: [UInt8](key.publicKey.rawRepresentation))
        case .ecdsaP256:
            let key = P256.Signing.PrivateKey()
            return .ecdsa(
                curve: .p256,
                scalar: [UInt8](key.rawRepresentation),
                point: [UInt8](key.publicKey.x963Representation))
        case .ecdsaP384:
            let key = P384.Signing.PrivateKey()
            return .ecdsa(
                curve: .p384,
                scalar: [UInt8](key.rawRepresentation),
                point: [UInt8](key.publicKey.x963Representation))
        case .ecdsaP521:
            let key = P521.Signing.PrivateKey()
            return .ecdsa(
                curve: .p521,
                scalar: [UInt8](key.rawRepresentation),
                point: [UInt8](key.publicKey.x963Representation))
        }
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
