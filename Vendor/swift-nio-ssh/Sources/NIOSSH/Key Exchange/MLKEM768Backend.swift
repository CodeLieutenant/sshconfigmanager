//===----------------------------------------------------------------------===//
//
// This file is part of the vendored, patched swift-nio-ssh. See Vendor/PATCH.md.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOConcurrencyHelpers

/// An ML-KEM-768 (FIPS 203) implementation, behind a protocol so the post-quantum key
/// exchange does not depend on where it comes from.
///
/// swift-crypto forwards to CryptoKit on Apple platforms, and CryptoKit only gained
/// `MLKEM768` in the 26 releases — so on macOS 14 and 15 there is no system implementation
/// to use. Rather than drop the method there, an application can register a portable one
/// through ``NIOSSHMLKEM/registerBackend(_:)``, the same shape as `Insecure.RSA.register()`.
/// This keeps the third-party dependency an application concern; NIOSSH itself stays on
/// swift-nio, swift-crypto and swift-atomics.
///
/// All sizes are FIPS 203's, and an implementation that does not match them is not
/// interoperable: encapsulation key 1184 bytes, ciphertext 1088 bytes, shared secret 32.
public protocol NIOSSHMLKEM768Backend: Sendable {
    /// Generates a fresh ephemeral keypair.
    func generateKeyPair() throws -> (encapsulationKey: [UInt8], privateKey: any NIOSSHMLKEM768PrivateKey)

    /// Encapsulates a fresh shared secret against a peer's encapsulation key.
    func encapsulate(encapsulationKey: [UInt8]) throws -> (sharedSecret: [UInt8], ciphertext: [UInt8])
}

/// The decapsulating half of ``NIOSSHMLKEM768Backend``.
public protocol NIOSSHMLKEM768PrivateKey: Sendable {
    func decapsulate(_ ciphertext: [UInt8]) throws -> [UInt8]
}

/// Where the post-quantum key exchange gets its ML-KEM implementation.
public enum NIOSSHMLKEM {
    private static let registered = NIOLockedValueBox<(any NIOSSHMLKEM768Backend)?>(nil)

    /// Installs an ML-KEM-768 implementation, replacing the system one if there is one.
    ///
    /// Call this before connecting. Registering on a system that already has CryptoKit's
    /// ML-KEM overrides it, which is intentional: it lets one implementation be used
    /// everywhere when that matters more than using the system's, and it lets a test
    /// exercise the fallback path on a system that would not otherwise take it. Pass nil to
    /// clear the override and go back to whatever the system provides.
    public static func registerBackend(_ backend: (any NIOSSHMLKEM768Backend)?) {
        self.registered.withLockedValue { $0 = backend }
    }

    /// The implementation to use, or nil when this system has neither a registered backend
    /// nor CryptoKit's. Nil means `mlkem768x25519-sha256` is not offered at all and
    /// negotiation falls back to an ECDH method.
    static var backend: (any NIOSSHMLKEM768Backend)? {
        if let registered = self.registered.withLockedValue({ $0 }) {
            return registered
        }
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, macCatalyst 26.0, visionOS 26.0, *) {
            return CryptoKitMLKEM768Backend()
        }
        return nil
    }
}

/// swift-crypto's `MLKEM768`, which is CryptoKit's on Apple platforms.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, macCatalyst 26.0, visionOS 26.0, *)
struct CryptoKitMLKEM768Backend: NIOSSHMLKEM768Backend {
    func generateKeyPair() throws -> (encapsulationKey: [UInt8], privateKey: any NIOSSHMLKEM768PrivateKey) {
        let key = try MLKEM768.PrivateKey()
        return (Array(key.publicKey.rawRepresentation), CryptoKitMLKEM768PrivateKey(key: key))
    }

    func encapsulate(encapsulationKey: [UInt8]) throws -> (sharedSecret: [UInt8], ciphertext: [UInt8]) {
        let result = try MLKEM768.PublicKey(rawRepresentation: encapsulationKey).encapsulate()
        return (result.sharedSecret.withUnsafeBytes { Array($0) }, Array(result.encapsulated))
    }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, macCatalyst 26.0, visionOS 26.0, *)
struct CryptoKitMLKEM768PrivateKey: NIOSSHMLKEM768PrivateKey, @unchecked Sendable {
    let key: MLKEM768.PrivateKey

    func decapsulate(_ ciphertext: [UInt8]) throws -> [UInt8] {
        try self.key.decapsulate(ciphertext).withUnsafeBytes { Array($0) }
    }
}
