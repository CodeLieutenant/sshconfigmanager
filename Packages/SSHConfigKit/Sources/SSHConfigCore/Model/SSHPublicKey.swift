//
//  SSHPublicKey.swift
//  SSHConfigCore
//
//  The value type for a key discovered in the SSH folder. Discovery + fingerprint
//  computation live in the platform `SSHKeyService`; this pure record is shared.
//

import Foundation

/// A key discovered in the SSH folder. Usually backed by a `.pub` file (optionally
/// paired with its private key), but may also be a **standalone private key with no
/// `.pub` sibling** (e.g. imported cloud/`.pem` keys), in which case `publicKeyURL`
/// is `nil`. Invariant: at least one of `publicKeyURL` / `privateKeyURL` is non-nil.
public struct SSHPublicKey: Identifiable, Equatable {
    public let id: UUID
    /// The `.pub` file URL, or `nil` for a private-key-only entry.
    public let publicKeyURL: URL?
    /// The private key file, if one exists.
    public let privateKeyURL: URL?
    /// Wire algorithm name, e.g. `ssh-ed25519`, `ssh-rsa` (may be empty if unknown).
    public let algorithm: String
    /// `SHA256:...` fingerprint, matching `ssh-keygen -lf` (empty if it couldn't be derived).
    public let fingerprint: String
    /// Trailing comment (often `user@host`), may be empty.
    public let comment: String

    public init(
        id: UUID = UUID(), publicKeyURL: URL?, privateKeyURL: URL?,
        algorithm: String, fingerprint: String, comment: String
    ) {
        self.id = id
        self.publicKeyURL = publicKeyURL
        self.privateKeyURL = privateKeyURL
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.comment = comment
    }

    public var name: String {
        if let publicKeyURL { return publicKeyURL.deletingPathExtension().lastPathComponent }
        return privateKeyURL?.lastPathComponent ?? ""
    }

    /// The SHA-256 fingerprint as colon-separated lowercase hex (e.g. `"32:9a:4a:…"`),
    /// derived from the stored `SHA256:<base64>` form. A secure, modern alternative to
    /// the legacy MD5 hex layout some tools still display — for eyeball cross-checking.
    /// `nil` when no SHA-256 fingerprint is available.
    public var sha256HexFingerprint: String? {
        let prefix = "SHA256:"
        guard fingerprint.hasPrefix(prefix) else { return nil }
        var base64 = String(fingerprint.dropFirst(prefix.count))
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return data.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// A friendly key-type label.
    public var typeLabel: String {
        switch algorithm {
        case "ssh-ed25519": return "Ed25519"
        case "ssh-rsa": return "RSA"
        case "ssh-dss", "dsa": return "DSA"
        case "ecdsa": return "ECDSA"
        case let a where a.hasPrefix("ecdsa-sha2-"): return "ECDSA"
        case let a where a.hasPrefix("sk-"): return "Security Key"
        case "": return "Unknown"
        default: return algorithm
        }
    }

    /// The path to use as an `IdentityFile` value: the private key's path, collapsed
    /// to `~/…` when it lives under `home`. The caller passes the *real* home —
    /// under the App Sandbox `FileManager.homeDirectoryForCurrentUser` is the
    /// container, so anchoring on it here left every path absolute.
    public func identityFilePath(relativeTo home: String) -> String {
        let url = privateKeyURL ?? publicKeyURL!.deletingPathExtension()
        return HomePath.abbreviating(url.path, home: home)
    }
}
