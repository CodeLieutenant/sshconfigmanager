//===----------------------------------------------------------------------===//
//
//  RSA.swift
//  NIOSSHRSA
//
//  RSA public-key authentication for NIOSSH, implemented on top of the CustomKeys
//  extension point (see NIOSSH/Keys And Signatures/CustomKeys.swift). Unlike the
//  Citadel implementation this is ported from, the crypto is backed entirely by
//  swift-crypto's `_CryptoExtras._RSA.Signing` — no BigInt, no BoringSSL SPI — and
//  authenticates with the modern RFC 8332 `rsa-sha2-256` signature algorithm while
//  keeping the legacy `ssh-rsa` key-blob format on the wire.
//
//  Call `Insecure.RSA.register()` once at startup to make NIOSSH aware of the type.
//
//  NIOSSH patch (sshconfigmanager): see Vendor/PATCH.md.
//

import Crypto
import Foundation
import NIOCore
import NIOSSH
import _CryptoExtras

extension Insecure {
    /// RSA key support for NIOSSH. Named `Insecure` to mirror CryptoKit's treatment
    /// of RSA — it remains widely required for SSH interop even though ed25519/ECDSA
    /// are preferred. Signing/verification use RSASSA-PKCS1-v1_5 over SHA-256.
    public enum RSA {}
}

extension Insecure.RSA {
    /// An SSH RSA public key. Wire blob format (RFC 4253): `string "ssh-rsa"`,
    /// `mpint e`, `mpint n`. The `"ssh-rsa"` prefix is written/consumed by NIOSSH;
    /// this type serializes only the `e`/`n` body.
    public struct PublicKey: NIOSSHPublicKeyProtocol {
        public static let publicKeyPrefix = "ssh-rsa"
        /// RFC 8332: authenticate with the stronger `rsa-sha2-256` algorithm even
        /// though the key blob still identifies itself as `ssh-rsa`.
        public static let publicKeyAuthAlgorithmName = "rsa-sha2-256"

        internal let backing: _RSA.Signing.PublicKey

        internal init(backing: _RSA.Signing.PublicKey) {
            self.backing = backing
        }

        /// Builds a public key from its raw RSA primitives (big-endian magnitudes).
        public init(modulus n: Data, publicExponent e: Data) throws {
            self.backing = try _RSA.Signing.PublicKey(n: n, e: e)
        }

        /// A stable representation used for equality/hashing.
        public var rawRepresentation: Data { self.backing.derRepresentation }

        public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
            guard let signature = signature as? Signature else { return false }
            let rsaSignature = _RSA.Signing.RSASignature(rawRepresentation: signature.rawRepresentation)
            return self.backing.isValidSignature(rsaSignature, for: data, padding: .insecurePKCS1v1_5)
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            let primitives = (try? self.backing.getKeyPrimitives()) ?? .init(modulus: Data(), publicExponent: Data())
            var written = buffer.writeSSHMPInt(primitives.publicExponent)
            written += buffer.writeSSHMPInt(primitives.modulus)
            return written
        }

        public static func read(from buffer: inout ByteBuffer) throws -> Insecure.RSA.PublicKey {
            guard let e = buffer.readSSHMPInt(), let n = buffer.readSSHMPInt() else {
                throw RSAError.invalidPublicKeyBlob
            }
            return try PublicKey(modulus: n, publicExponent: e)
        }
    }

    /// An SSH RSA private key. Signs with RSASSA-PKCS1-v1_5 over SHA-256 (`rsa-sha2-256`).
    public struct PrivateKey: NIOSSHPrivateKeyProtocol {
        public static let keyPrefix = "ssh-rsa"

        internal let backing: _RSA.Signing.PrivateKey

        internal init(backing: _RSA.Signing.PrivateKey) {
            self.backing = backing
        }

        /// Builds a private key from the raw RSA components carried in an OpenSSH
        /// private-key blob (all big-endian magnitudes).
        public init(modulus n: Data, publicExponent e: Data, privateExponent d: Data, prime1 p: Data, prime2 q: Data) throws {
            self.backing = try _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q)
        }

        /// Builds a private key from a PEM/PKCS#1 representation.
        public init(pemRepresentation: String) throws {
            self.backing = try _RSA.Signing.PrivateKey(unsafePEMRepresentation: pemRepresentation)
        }

        public var publicKey: NIOSSHPublicKeyProtocol {
            PublicKey(backing: self.backing.publicKey)
        }

        public func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            // rsa-sha2-256 == RSASSA-PKCS1-v1_5 over SHA-256. `_RSA` hashes the data
            // with SHA-256 internally for the DataProtocol overload.
            let signature = try self.backing.signature(for: data, padding: .insecurePKCS1v1_5)
            return Signature(rawRepresentation: signature.rawRepresentation)
        }
    }

    /// An SSH RSA signature. Wire blob (after the `string "rsa-sha2-256"` prefix that
    /// NIOSSH writes/consumes) is `string signature`, the raw key-length signature bytes.
    public struct Signature: NIOSSHSignatureProtocol {
        public static let signaturePrefix = "rsa-sha2-256"
        // We only produce and verify rsa-sha2-256 (SHA-256). Legacy ssh-rsa (SHA-1) and
        // rsa-sha2-512 are intentionally not accepted, as our verify path assumes SHA-256.
        public static let acceptedSignaturePrefixes = ["rsa-sha2-256"]

        public let rawRepresentation: Data

        public init(rawRepresentation: Data) {
            self.rawRepresentation = rawRepresentation
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(self.rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> Insecure.RSA.Signature {
            guard let bytes = buffer.readSSHString() else {
                throw RSAError.invalidSignatureBlob
            }
            return Signature(rawRepresentation: Data(bytes))
        }
    }

    /// Registers the RSA public-key/signature pair with NIOSSH. Call once at startup,
    /// before opening connections. Idempotent.
    public static func register() {
        NIOSSHAlgorithms.register(publicKey: PublicKey.self, signature: Signature.self)
    }
}

public struct RSAError: Error, Equatable {
    public let message: String
    public static let invalidPublicKeyBlob = RSAError(message: "Malformed ssh-rsa public key blob.")
    public static let invalidSignatureBlob = RSAError(message: "Malformed rsa-sha2-256 signature blob.")
}

// MARK: - SSH wire helpers (string / mpint)
//
// Reimplemented on public NIOCore API because NIOSSH's own helpers are internal to
// that module. SSH strings and mpints share the same framing: a big-endian uint32
// length followed by the bytes; an mpint additionally prepends a 0x00 byte when the
// top bit of the first byte is set, to keep the two's-complement value positive.

extension ByteBuffer {
    fileprivate mutating func writeSSHString<Bytes: Collection>(_ bytes: Bytes) -> Int where Bytes.Element == UInt8 {
        var written = self.writeInteger(UInt32(bytes.count))
        written += self.writeBytes(bytes)
        return written
    }

    fileprivate mutating func writeSSHMPInt(_ value: Data) -> Int {
        var magnitude = value.drop { $0 == 0 }  // strip leading zero bytes
        if magnitude.isEmpty {
            return self.writeInteger(UInt32(0))
        }
        if magnitude.first! & 0x80 != 0 {
            // High bit set: prepend a zero byte so the value reads as positive.
            var padded = Data([0x00])
            padded.append(contentsOf: magnitude)
            magnitude = padded[...]
        }
        var written = self.writeInteger(UInt32(magnitude.count))
        written += self.writeBytes(magnitude)
        return written
    }

    fileprivate mutating func readSSHString() -> ByteBufferView? {
        guard let length = self.readInteger(as: UInt32.self),
            let slice = self.readSlice(length: Int(length))
        else {
            return nil
        }
        return slice.readableBytesView
    }

    /// Reads an mpint and returns its magnitude as `Data`, stripping a leading
    /// sign-padding zero so the result is a clean big-endian magnitude.
    fileprivate mutating func readSSHMPInt() -> Data? {
        guard let view = self.readSSHString() else { return nil }
        return Data(view.drop { $0 == 0 })
    }
}
