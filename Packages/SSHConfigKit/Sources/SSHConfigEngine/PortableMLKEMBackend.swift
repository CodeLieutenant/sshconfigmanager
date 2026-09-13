//
//  PortableMLKEMBackend.swift
//  SSHConfigMacUI
//
//  ML-KEM-768 for systems whose CryptoKit has none.
//
//  `mlkem768x25519-sha256` is the key exchange OpenSSH 9.9 offers first, and the only one
//  some hardened servers accept. swift-crypto forwards to CryptoKit on Apple platforms, and
//  CryptoKit only gained `MLKEM768` in the 26 releases — so on macOS 14.4 and 15, the app's
//  deployment floor, there is no system implementation. This registers a portable one so the
//  method stays available across every supported system rather than only the newest.
//
//  Above macOS 26 nothing is registered and CryptoKit's implementation is used: it is the
//  one the platform maintains, and it is not pure Swift.
//
//  Both are FIPS 203 ML-KEM-768 and therefore wire-compatible — 1184-byte encapsulation key,
//  1088-byte ciphertext, 32-byte shared secret. `PortableMLKEMBackendTests` proves that by
//  crossing the two implementations in both directions, so a system on either side of the
//  macOS 26 line talks to the same servers.
//
//  This whole file is Apple-only. SwiftKyber's BigInt dependency takes its randomness from
//  Security.framework, so it does not build on Linux — and it is not needed there: NIOSSH
//  gates its built-in backend on an Apple availability check, which non-Apple platforms
//  always satisfy, so Linux gets swift-crypto's BoringSSL ML-KEM-768 with nothing
//  registered. `MLKEMBackendRegistration.install` still exists everywhere and is a no-op
//  where the system already has an implementation, so callers need no conditional code.
//

import Foundation
import NIOSSH

/// Registers the portable ML-KEM implementation when, and only when, the system has none.
public enum MLKEMBackendRegistration {
    /// Idempotent: reading this once installs the backend. Mirrors how `NIOTunnelEngine`
    /// registers the RSA custom key type.
    public static let install: Void = {
        #if canImport(SwiftKyber)
            if #available(macOS 26.0, *) {
                // CryptoKit has ML-KEM here; NIOSSH picks it up on its own.
                return
            }
            NIOSSHMLKEM.registerBackend(PortableMLKEM768Backend())
        #endif
        // Off Apple, NIOSSH's own swift-crypto backend is always available, so there
        // is nothing to register.
    }()
}

#if canImport(SwiftKyber)

    import SwiftKyber

    /// ML-KEM-768 backed by SwiftKyber, a pure-Swift FIPS 203 implementation.
    public struct PortableMLKEM768Backend: NIOSSHMLKEM768Backend {
        public init() {}

        public func generateKeyPair() throws -> (encapsulationKey: [UInt8], privateKey: any NIOSSHMLKEM768PrivateKey) {
            let pair = Kyber.GenerateKeyPair(kind: .K768)
            return (pair.encap.keyBytes, PortableMLKEM768PrivateKey(key: pair.decap))
        }

        public func encapsulate(encapsulationKey: [UInt8]) throws -> (sharedSecret: [UInt8], ciphertext: [UInt8]) {
            let result = try EncapsulationKey(keyBytes: encapsulationKey).Encapsulate()
            return (result.K, result.ct)
        }
    }

    public struct PortableMLKEM768PrivateKey: NIOSSHMLKEM768PrivateKey {
        public let key: DecapsulationKey

        public init(key: DecapsulationKey) {
            self.key = key
        }

        public func decapsulate(_ ciphertext: [UInt8]) throws -> [UInt8] {
            try self.key.Decapsulate(ct: ciphertext)
        }
    }

#endif
