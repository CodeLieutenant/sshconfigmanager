//
//  BcryptPBKDF.swift
//
//  Thin Swift wrapper over OpenSSH's reference bcrypt_pbkdf C implementation
//  (see the CBcryptPBKDF target). bcrypt_pbkdf is the OpenSSH-specific KDF that
//  protects `-----BEGIN OPENSSH PRIVATE KEY-----` files; no platform crypto
//  framework ships it, hence the vendored C reference rather than a hand port.
//

import CBcryptPBKDF

public enum BcryptPBKDF {
    /// Derives `keyLength` bytes of key material from `passphrase` + `salt` using
    /// `rounds` iterations of OpenSSH's bcrypt_pbkdf. Returns `nil` on invalid
    /// arguments (non-positive rounds/length, empty passphrase or salt).
    public static func derive(passphrase: [UInt8], salt: [UInt8], rounds: Int, keyLength: Int) -> [UInt8]? {
        guard rounds > 0, keyLength > 0, !passphrase.isEmpty, !salt.isEmpty else { return nil }

        var key = [UInt8](repeating: 0, count: keyLength)
        let status = passphrase.withUnsafeBufferPointer { passBuf -> Int32 in
            salt.withUnsafeBufferPointer { saltBuf -> Int32 in
                key.withUnsafeMutableBufferPointer { keyBuf -> Int32 in
                    passBuf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: passBuf.count) { passPtr in
                        bcrypt_pbkdf(passPtr, passBuf.count,
                                     saltBuf.baseAddress, saltBuf.count,
                                     keyBuf.baseAddress, keyLength, UInt32(rounds))
                    }
                }
            }
        }
        return status == 0 ? key : nil
    }

    /// SHA-512 of `bytes`, from the same in-tree implementation bcrypt_pbkdf uses.
    /// Exposed so the hash has direct test coverage on every platform the package
    /// builds for.
    public static func sha512(_ bytes: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(SSHCM_SHA512_DIGEST_LENGTH))
        digest.withUnsafeMutableBufferPointer { out in
            bytes.withUnsafeBufferPointer { input in
                _ = crypto_hash_sha512(out.baseAddress, input.baseAddress, UInt64(input.count))
            }
        }
        return digest
    }
}
