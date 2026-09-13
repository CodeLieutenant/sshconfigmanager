//
//  OpenSSHKeySerializer.swift
//  sshconfigmanager
//
//  The inverse of `OpenSSHPrivateKey`: turns raw key material into the on-disk
//  OpenSSH artifacts — the one-line `.pub` text and the
//  `-----BEGIN OPENSSH PRIVATE KEY-----` PEM. The App Sandbox blocks shelling out
//  to `ssh-keygen`, so we own the serialization (CryptoKit/_CryptoExtras generate
//  and encrypt; this file frames the bytes).
//
//  Deliberately *pure*: no file I/O and no internal randomness — callers inject the
//  check bytes and (when encrypting) the salt, so a given input always produces the
//  same bytes and tests can round-trip the output back through `OpenSSHPrivateKey`.
//

import BcryptPBKDF
import Crypto
import Foundation
import SSHConfigCore
import _CryptoExtras

public enum OpenSSHKeySerializer {
    private static let magic = Array("openssh-key-v1\0".utf8) // 15 bytes

    /// The raw material to serialize — mirrors `ParsedOpenSSHKey.Material`, but the
    /// public bytes travel alongside (we don't recompute them here).
    public enum Material: Equatable {
        /// `seed` = 32-byte CryptoKit `rawRepresentation`; `pub` = 32-byte point.
        case ed25519(seed: [UInt8], pub: [UInt8])
        /// `scalar` = private scalar (curve's fixed length); `point` = X9.63 `Q`
        /// (`0x04 ‖ X ‖ Y`).
        case ecdsa(curve: ECDSACurve, scalar: [UInt8], point: [UInt8])

        /// The SSH key-type string, e.g. `ssh-ed25519` / `ecdsa-sha2-nistp256`.
        public var keyType: String {
            switch self {
            case .ed25519: return "ssh-ed25519"
            case .ecdsa(let curve, _, _): return "ecdsa-sha2-\(curve.rawValue)"
            }
        }
    }

    /// How to protect the private section. `.none` writes cipher/kdf `none`;
    /// `.encrypted` derives a key via bcrypt_pbkdf and wraps the section in
    /// aes256-ctr, exactly as `OpenSSHPrivateKey` expects to decrypt it.
    public enum Encryption {
        case none
        case encrypted(passphrase: String, salt: [UInt8], rounds: Int)
    }

    // MARK: - Public key (.pub)

    /// The single-line public key: `<keytype> <base64(blob)> <comment>` plus a
    /// trailing newline (matching `ssh-keygen`). Round-trips through
    /// `SSHKeyService.parsePublicKey`.
    public static func publicKeyLine(for material: Material, comment: String) -> String {
        let blob = publicBlob(for: material)
        let base64 = Data(blob).base64EncodedString()
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmedComment.isEmpty ? "" : " \(trimmedComment)"
        return "\(material.keyType) \(base64)\(suffix)\n"
    }

    // MARK: - Private key (PEM)

    /// The full `-----BEGIN OPENSSH PRIVATE KEY-----` block. `checkBytes` is the
    /// random 4-byte value written twice into the private section (OpenSSH uses it to
    /// detect a wrong passphrase); callers pass it so this stays deterministic.
    public static func privateKeyPEM(
        for material: Material, comment: String,
        encryption: Encryption, checkBytes: UInt32
    ) throws -> String {
        let publicBlob = publicBlob(for: material)

        // Private section, before padding: check1 ‖ check2 ‖ key fields ‖ comment.
        var section: [UInt8] = []
        section += SSHAgentProtocol.uint32(checkBytes)
        section += SSHAgentProtocol.uint32(checkBytes)
        section += privateKeyFields(for: material)
        section += SSHAgentProtocol.string(Array(comment.utf8))

        let blockSize = encryption.blockSize
        pad(&section, to: blockSize)

        let cipherName: String
        let kdfName: String
        let kdfOptions: [UInt8]
        let privateSection: [UInt8]

        switch encryption {
        case .none:
            cipherName = "none"
            kdfName = "none"
            kdfOptions = []
            privateSection = section
        case .encrypted(let passphrase, let salt, let rounds):
            cipherName = "aes256-ctr"
            kdfName = "bcrypt"
            kdfOptions = SSHAgentProtocol.string(salt) + SSHAgentProtocol.uint32(UInt32(rounds))
            privateSection = try encrypt(section, passphrase: passphrase, salt: salt, rounds: rounds)
        }

        var blob: [UInt8] = magic
        blob += SSHAgentProtocol.string(Array(cipherName.utf8))
        blob += SSHAgentProtocol.string(Array(kdfName.utf8))
        blob += SSHAgentProtocol.string(kdfOptions)
        blob += SSHAgentProtocol.uint32(1) // exactly one key
        blob += SSHAgentProtocol.string(publicBlob)
        blob += SSHAgentProtocol.string(privateSection)

        return wrapPEM(blob)
    }

    // MARK: - Blob builders

    /// The public-key blob — the same bytes `SSHKeyService` fingerprints.
    private static func publicBlob(for material: Material) -> [UInt8] {
        switch material {
        case .ed25519(_, let pub):
            return SSHAgentProtocol.string(Array("ssh-ed25519".utf8))
                + SSHAgentProtocol.string(pub)
        case .ecdsa(let curve, _, let point):
            return SSHAgentProtocol.string(Array(material.keyType.utf8))
                + SSHAgentProtocol.string(Array(curve.rawValue.utf8))
                + SSHAgentProtocol.string(point)
        }
    }

    /// The key-type-specific fields inside the private section, matching the layout
    /// `OpenSSHPrivateKey.parseBlob` reads back: each starts with the `string keytype`
    /// the parser reads before the per-type material.
    private static func privateKeyFields(for material: Material) -> [UInt8] {
        let keyType = SSHAgentProtocol.string(Array(material.keyType.utf8))
        switch material {
        case .ed25519(let seed, let pub):
            // string keytype + string publicKey(32) + string privateKey(64 = seed ‖ pub).
            return keyType + SSHAgentProtocol.string(pub) + SSHAgentProtocol.string(seed + pub)
        case .ecdsa(let curve, let scalar, let point):
            // string keytype + string curveName + string Q + mpint d.
            return keyType
                + SSHAgentProtocol.string(Array(curve.rawValue.utf8))
                + SSHAgentProtocol.string(point)
                + SSHAgentProtocol.string(mpint(scalar))
        }
    }

    // MARK: - Helpers

    /// Encodes a big-endian magnitude as an SSH mpint: drop leading zero bytes, then
    /// prepend a `0x00` when the top bit is set so the value stays positive.
    private static func mpint(_ magnitude: [UInt8]) -> [UInt8] {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if bytes.isEmpty { return [] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return bytes
    }

    /// Pads with the incrementing sequence 1, 2, 3, … to a multiple of `blockSize`,
    /// as OpenSSH does for the private section.
    private static func pad(_ section: inout [UInt8], to blockSize: Int) {
        var pad: UInt8 = 1
        while section.count % blockSize != 0 {
            section.append(pad)
            pad &+= 1
        }
    }

    /// Derives key+IV via bcrypt_pbkdf and encrypts the padded section with
    /// aes256-ctr — the exact inverse of `OpenSSHPrivateKey.decryptPrivateSection`.
    private static func encrypt(
        _ section: [UInt8], passphrase: String, salt: [UInt8], rounds: Int
    ) throws -> [UInt8] {
        guard
            let derived = BcryptPBKDF.derive(
                passphrase: Array(passphrase.utf8), salt: salt,
                rounds: rounds, keyLength: 32 + 16)
        else {
            throw OpenSSHKeyError.malformed
        }
        let key = Array(derived[0..<32])
        let iv = Array(derived[32..<48])
        let ciphertext = try AES._CTR.encrypt(
            Data(section),
            using: SymmetricKey(data: Data(key)),
            nonce: try AES._CTR.Nonce(nonceBytes: iv))
        return [UInt8](ciphertext)
    }

    /// Wraps the raw blob in the PEM markers with base64 lines of 70 chars
    /// (the width `ssh-keygen` emits).
    private static func wrapPEM(_ blob: [UInt8]) -> String {
        let base64 = Data(blob).base64EncodedString()
        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        return lines.joined(separator: "\n") + "\n"
    }
}

extension OpenSSHKeySerializer.Encryption {
    /// Padding block size: 8 for an unencrypted section, the cipher block (16) when
    /// encrypted.
    fileprivate var blockSize: Int {
        switch self {
        case .none: return 8
        case .encrypted: return 16
        }
    }
}
