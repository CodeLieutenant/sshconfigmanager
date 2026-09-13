//
//  KeyFingerprint.swift
//  SSHConfigCrypto
//
//  The canonical `SHA256:` fingerprint of an SSH public-key blob, matching
//  `ssh-keygen -lf`. Uses swift-crypto's SHA256 (cross-platform), so it works the
//  same on macOS and Linux. Shared by key discovery, the Agent screen
//  (`AgentKeyCorrelation`), and the tunnel engine — so they can never disagree
//  about "is this key the same key?".
//

import Crypto
import Foundation

public enum KeyFingerprint {
    /// Fingerprint of a base64-encoded key blob (e.g. the second field of a `.pub`).
    public static func sha256(base64Blob: String) -> String? {
        guard let data = Data(base64Encoded: base64Blob) else { return nil }
        return sha256(blob: [UInt8](data))
    }

    /// Fingerprint of a raw SSH public-key blob: base64 SHA-256 with `=` padding
    /// stripped, prefixed `SHA256:`.
    public static func sha256(blob: [UInt8]) -> String? {
        guard !blob.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(blob))
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.replacingOccurrences(of: "=", with: "")
    }
}
