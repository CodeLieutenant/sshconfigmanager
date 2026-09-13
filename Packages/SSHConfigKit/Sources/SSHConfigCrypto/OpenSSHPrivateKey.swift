//
//  OpenSSHPrivateKey.swift
//  sshconfigmanager
//
//  Parses the `-----BEGIN OPENSSH PRIVATE KEY-----` container into the raw key
//  material the in-process tunnel engine needs (swift-nio-ssh has no agent/
//  custom-signer hook, so we must hold the key ourselves). No file I/O — it works
//  on a PEM string, so it's unit-testable against known keys.
//
//  Supports ed25519, ECDSA (P-256/384/521), and RSA, including passphrase-encrypted
//  keys (`bcrypt_pbkdf` KDF via the BcryptPBKDF package + AES-CTR via _CryptoExtras).
//  Unsupported ciphers/KDFs/key types throw clear errors.
//

import BcryptPBKDF
import Crypto
import Foundation
import SSHConfigCore
import _CryptoExtras

public enum OpenSSHKeyError: LocalizedError, Equatable {
    case notOpenSSHFormat
    case passphraseRequired
    case incorrectPassphrase
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case unsupportedKeyType(String)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .notOpenSSHFormat:
            return "Not an OpenSSH private key (expected the -----BEGIN OPENSSH PRIVATE KEY----- format)."
        case .passphraseRequired:
            return "This key is passphrase-protected. A passphrase is required to unlock it."
        case .incorrectPassphrase:
            return "Incorrect passphrase for this key."
        case .unsupportedCipher(let cipher):
            return "Unsupported key cipher '\(cipher)'. Supported: aes128/192/256-ctr."
        case .unsupportedKDF(let kdf):
            return "Unsupported key derivation '\(kdf)'. Only the bcrypt KDF is supported."
        case .unsupportedKeyType(let type):
            return
                "Unsupported key type '\(type)'. The in-process engine supports ed25519, ECDSA (P-256/384/521), and RSA."
        case .malformed:
            return "The private key file is malformed or truncated."
        }
    }
}

/// The parsed contents of an unencrypted OpenSSH private key.
/// The NIST curves NIOSSH/CryptoKit support for ECDSA.
public enum ECDSACurve: String, Equatable, Sendable {
    case p256 = "nistp256"
    case p384 = "nistp384"
    case p521 = "nistp521"
    /// The fixed scalar/coordinate byte length CryptoKit expects.
    public var scalarBytes: Int {
        switch self {
        case .p256: return 32
        case .p384: return 48
        case .p521: return 66
        }
    }
}

public struct ParsedOpenSSHKey: Equatable {
    public enum Material: Equatable {
        /// 32-byte ed25519 seed (CryptoKit `rawRepresentation`).
        case ed25519(seed: [UInt8])
        /// ECDSA private scalar, left-padded to the curve's fixed length.
        case ecdsa(curve: ECDSACurve, scalar: [UInt8])
        /// RSA private components as big-endian magnitudes (the CRT coefficient
        /// `iqmp` from the file is dropped — `_RSA`/BoringSSL recomputes it).
        case rsa(n: [UInt8], e: [UInt8], d: [UInt8], p: [UInt8], q: [UInt8])
    }

    /// e.g. "ssh-ed25519" / "ecdsa-sha2-nistp256".
    public let keyType: String
    /// The raw public-key bytes as stored (ed25519 point, or the EC point Q).
    public let publicKey: [UInt8]
    public let material: Material
    /// RSA CRT coefficient `iqmp` (= q⁻¹ mod p), retained for the ssh-agent
    /// ADD_IDENTITY message which requires it; nil for non-RSA keys. (The signing
    /// path drops it because `_RSA` recomputes it — but the agent wire format needs
    /// it supplied.) Stored as a big-endian magnitude.
    public var rsaIQMP: [UInt8]? = nil

    public init(keyType: String, publicKey: [UInt8], material: Material, rsaIQMP: [UInt8]? = nil) {
        self.keyType = keyType
        self.publicKey = publicKey
        self.material = material
        self.rsaIQMP = rsaIQMP
    }

    /// Convenience for ed25519 callers/tests.
    public var ed25519Seed: [UInt8]? {
        if case .ed25519(let seed) = material { return seed }
        return nil
    }
}

public enum OpenSSHPrivateKey {
    private static let magic = Array("openssh-key-v1\0".utf8) // 15 bytes
    private static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let end = "-----END OPENSSH PRIVATE KEY-----"

    /// Ciphers we can decrypt → (key length, IV length).
    private static let supportedCiphers: [String: (keyLen: Int, ivLen: Int)] = [
        "aes256-ctr": (32, 16), "aes192-ctr": (24, 16), "aes128-ctr": (16, 16),
    ]

    /// Parses a PEM-wrapped OpenSSH private key, decrypting it with `passphrase`
    /// if the key is encrypted.
    public static func parse(pem: String, passphrase: String? = nil) throws -> ParsedOpenSSHKey {
        guard let blob = decodeBase64Body(pem) else { throw OpenSSHKeyError.notOpenSSHFormat }
        do {
            return try parseBlob(blob, passphrase: passphrase)
        } catch let error as OpenSSHKeyError {
            throw error
        } catch {
            throw OpenSSHKeyError.malformed
        }
    }

    /// Cheap header-only check (no bcrypt) for whether the key is encrypted, so
    /// callers can prompt for a passphrase before doing expensive work off-thread.
    /// `nil` when the PEM can't be parsed at all (bad base64, wrong magic, truncated
    /// header) — distinct from a definitive `false`, so an unparseable key isn't
    /// audited as "has no passphrase" (audit #33).
    public static func isEncrypted(pem: String) -> Bool? {
        guard let blob = decodeBase64Body(pem) else { return nil }
        var reader = ByteReader(blob)
        guard let m = try? reader.readBytes(magic.count), m == magic,
            let cipher = try? reader.readString()
        else { return nil }
        return String(decoding: cipher, as: UTF8.self) != "none"
    }

    /// Reads the key type and the **cleartext** public-key blob from an OpenSSH
    /// private key, *without decrypting* — the public section is never encrypted, so
    /// this works for passphrase-protected keys too. Used to list standalone private
    /// keys (no `.pub` sibling) with their real type and fingerprint.
    ///
    /// Returns `(keyType, blob)` where `blob` is the full SSH wire public key
    /// (`string keytype` + key data), suitable for fingerprinting; `nil` if the input
    /// isn't an OpenSSH private key.
    public static func publicKeyInfo(pem: String) -> (keyType: String, blob: [UInt8])? {
        guard let data = decodeBase64Body(pem) else { return nil }
        var reader = ByteReader(data)
        guard let m = try? reader.readBytes(magic.count), m == magic,
            (try? reader.readString()) != nil, // cipher
            (try? reader.readString()) != nil, // kdfname
            (try? reader.readString()) != nil, // kdfoptions
            (try? reader.readUInt32()) != nil, // key count
            let blob = try? reader.readString()
        else { // public key blob (cleartext)
            return nil
        }
        var blobReader = ByteReader(blob)
        guard let typeBytes = try? blobReader.readString() else { return nil }
        return (String(decoding: typeBytes, as: UTF8.self), blob)
    }

    /// Extracts and base64-decodes the body between the PEM markers.
    private static func decodeBase64Body(_ pem: String) -> [UInt8]? {
        let lines = pem.split(whereSeparator: \.isNewline).map(String.init)
        guard let beginIndex = lines.firstIndex(where: { $0.contains(begin) }),
            let endIndex = lines.firstIndex(where: { $0.contains(end) }),
            beginIndex < endIndex
        else { return nil }
        let body = lines[(beginIndex + 1)..<endIndex].joined()
        guard let data = Data(base64Encoded: body) else { return nil }
        return [UInt8](data)
    }

    private static func parseBlob(_ blob: [UInt8], passphrase: String?) throws -> ParsedOpenSSHKey {
        var reader = ByteReader(blob)

        guard try reader.readBytes(magic.count) == magic else {
            throw OpenSSHKeyError.notOpenSSHFormat
        }
        let cipher = String(decoding: try reader.readString(), as: UTF8.self)
        let kdfName = String(decoding: try reader.readString(), as: UTF8.self)
        let kdfOptions = try reader.readString()
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else { throw OpenSSHKeyError.malformed }

        _ = try reader.readString() // public key blob (derivable from private)
        let privateSection = try reader.readString()

        let decrypted = try decryptPrivateSection(
            privateSection, cipher: cipher, kdfName: kdfName,
            kdfOptions: kdfOptions, passphrase: passphrase)

        var priv = ByteReader(decrypted)
        let check1 = try priv.readUInt32()
        let check2 = try priv.readUInt32()
        // For an encrypted key, a check mismatch means the wrong passphrase.
        guard check1 == check2 else {
            throw cipher == "none" ? OpenSSHKeyError.malformed : OpenSSHKeyError.incorrectPassphrase
        }

        let keyType = String(decoding: try priv.readString(), as: UTF8.self)

        switch keyType {
        case "ssh-ed25519":
            // string publicKey(32) + string privateKey(64 = seed32 || pub32).
            let publicKey = try priv.readString()
            let secret = try priv.readString()
            guard publicKey.count == 32, secret.count == 64 else { throw OpenSSHKeyError.malformed }
            return ParsedOpenSSHKey(
                keyType: keyType, publicKey: publicKey,
                material: .ed25519(seed: Array(secret.prefix(32))))

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            // string curveName + string Q (point) + mpint d (private scalar).
            let curveName = String(decoding: try priv.readString(), as: UTF8.self)
            guard let curve = ECDSACurve(rawValue: curveName) else {
                throw OpenSSHKeyError.unsupportedKeyType(keyType)
            }
            let point = try priv.readString()
            let scalar = normalizeScalar(try priv.readString(), to: curve.scalarBytes)
            guard scalar.count == curve.scalarBytes else { throw OpenSSHKeyError.malformed }
            return ParsedOpenSSHKey(
                keyType: keyType, publicKey: point,
                material: .ecdsa(curve: curve, scalar: scalar))

        case "ssh-rsa":
            // OpenSSH private RSA layout: mpint n, e, d, iqmp, p, q (note: n before e,
            // unlike the public blob which is e, n). iqmp is dropped — it's recomputed.
            let n = stripLeadingZeros(try priv.readString())
            let e = stripLeadingZeros(try priv.readString())
            let d = stripLeadingZeros(try priv.readString())
            let iqmp = stripLeadingZeros(try priv.readString()) // CRT coefficient
            let p = stripLeadingZeros(try priv.readString())
            let q = stripLeadingZeros(try priv.readString())
            guard !n.isEmpty, !e.isEmpty, !d.isEmpty, !p.isEmpty, !q.isEmpty else {
                throw OpenSSHKeyError.malformed
            }
            // The public blob is derivable from the private components; not retained here.
            // iqmp is kept for the agent ADD_IDENTITY path (see ParsedOpenSSHKey.rsaIQMP).
            return ParsedOpenSSHKey(
                keyType: keyType, publicKey: [],
                material: .rsa(n: n, e: e, d: d, p: p, q: q),
                rsaIQMP: iqmp)

        default:
            throw OpenSSHKeyError.unsupportedKeyType(keyType)
        }
    }

    /// Normalizes an SSH mpint-style scalar to a fixed big-endian length: drop a
    /// leading sign byte / extra zeros, then left-pad with zeros.
    /// Drops leading zero bytes from an SSH mpint, yielding a clean big-endian
    /// magnitude (an all-zero value collapses to empty).
    private static func stripLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        Array(bytes.drop { $0 == 0 })
    }

    private static func normalizeScalar(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        var trimmed = bytes
        while trimmed.count > length, trimmed.first == 0 { trimmed.removeFirst() }
        if trimmed.count < length {
            trimmed = [UInt8](repeating: 0, count: length - trimmed.count) + trimmed
        }
        return trimmed
    }

    /// Returns the plaintext private section, decrypting via bcrypt_pbkdf +
    /// AES-CTR when the key is encrypted.
    private static func decryptPrivateSection(
        _ section: [UInt8], cipher: String, kdfName: String,
        kdfOptions: [UInt8], passphrase: String?
    ) throws -> [UInt8] {
        if cipher == "none" { return section }

        guard let spec = supportedCiphers[cipher] else {
            throw OpenSSHKeyError.unsupportedCipher(cipher)
        }
        guard kdfName == "bcrypt" else { throw OpenSSHKeyError.unsupportedKDF(kdfName) }
        guard let passphrase, !passphrase.isEmpty else { throw OpenSSHKeyError.passphraseRequired }

        // kdfoptions = string(salt) + uint32(rounds).
        var options = ByteReader(kdfOptions)
        let salt = try options.readString()
        let rounds = Int(try options.readUInt32())
        guard rounds > 0, !salt.isEmpty else { throw OpenSSHKeyError.malformed }

        guard
            let derived = BcryptPBKDF.derive(
                passphrase: Array(passphrase.utf8), salt: salt,
                rounds: rounds, keyLength: spec.keyLen + spec.ivLen)
        else {
            throw OpenSSHKeyError.malformed
        }
        let key = Array(derived[0..<spec.keyLen])
        let iv = Array(derived[spec.keyLen..<spec.keyLen + spec.ivLen])

        // AES-CTR via swift-crypto's _CryptoExtras (big-endian 128-bit counter, as
        // OpenSSH uses). The AES variant (128/192/256) follows the key length.
        do {
            let plaintext = try AES._CTR.decrypt(
                Data(section),
                using: SymmetricKey(data: Data(key)),
                nonce: try AES._CTR.Nonce(nonceBytes: iv))
            return [UInt8](plaintext)
        } catch {
            throw OpenSSHKeyError.malformed
        }
    }
}
