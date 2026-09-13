//
//  SSHKeyService.swift
//  sshconfigmanager
//
//  Inspects existing SSH public keys: type, comment, and SHA256 fingerprint.
//

import Foundation
import SSHConfigCore
import SSHConfigCrypto

// `SSHPublicKey` now lives in SSHConfigCore (Model/SSHPublicKey.swift); the SHA256
// fingerprint helper lives in SSHConfigCrypto (KeyFingerprint).

public enum SSHKeyService {
    /// File names in `~/.ssh` that are never keys, so we don't try to read them as such.
    public static let nonKeyFileNames: Set<String> = [
        "config", "known_hosts", "known_hosts.old", "authorized_keys", "authorized_keys2",
        "environment", "rc",
    ]

    /// Discovers every key in the SSH folder from a list of file URLs.
    ///
    /// Pure (no I/O of its own) so it's unit-testable: `readText` supplies file
    /// contents on demand. Lists both `.pub` files (paired with their private key
    /// when present) **and standalone private keys that have no `.pub` sibling** —
    /// the latter being the bug fix for imported cloud/`.pem` keys that never get a
    /// `.pub` and were previously invisible.
    public static func discoverKeys(files: [URL], readText: (URL) -> String?) -> [SSHPublicKey] {
        let names = Set(files.map(\.lastPathComponent))
        var keys: [SSHPublicKey] = []
        var pairedPrivateNames = Set<String>()

        // 1) Public keys (.pub), pairing the private sibling when it exists.
        for url in files where url.pathExtension == "pub" {
            if let text = readText(url), let key = parsePublicKey(text, url: url, siblings: names) {
                keys.append(key)
                if let priv = key.privateKeyURL { pairedPrivateNames.insert(priv.lastPathComponent) }
            }
        }

        // 2) Standalone private keys with no `.pub` sibling.
        for url in files {
            let fileName = url.lastPathComponent
            guard url.pathExtension != "pub",
                !url.hasDirectoryPath,
                !nonKeyFileNames.contains(fileName),
                !pairedPrivateNames.contains(fileName),
                !names.contains(fileName + ".pub")
            else { continue }
            if let text = readText(url), let key = parsePrivateKeyOnly(text, url: url) {
                keys.append(key)
            }
        }

        return keys.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Builds an `SSHPublicKey` for a standalone private key file (no `.pub`).
    /// Returns `nil` if `text` isn't a private key. For OpenSSH-format keys the
    /// type and fingerprint come from the cleartext public blob (works even when the
    /// key is passphrase-protected); for classic PEM keys the type is best-effort and
    /// the fingerprint is left empty.
    public static func parsePrivateKeyOnly(_ text: String, url: URL) -> SSHPublicKey? {
        guard text.contains("PRIVATE KEY-----") else { return nil }

        if let info = OpenSSHPrivateKey.publicKeyInfo(pem: text) {
            return SSHPublicKey(
                id: UUID(), publicKeyURL: nil, privateKeyURL: url,
                algorithm: info.keyType, fingerprint: fingerprint(blob: info.blob) ?? "", comment: "")
        }

        return SSHPublicKey(
            id: UUID(), publicKeyURL: nil, privateKeyURL: url,
            algorithm: classicPEMAlgorithm(text), fingerprint: "", comment: "")
    }

    /// Best-effort SSH algorithm name for a classic (non-OpenSSH) PEM private key.
    /// Empty string when the format doesn't reveal the type (e.g. PKCS#8).
    public static func classicPEMAlgorithm(_ text: String) -> String {
        if text.contains("BEGIN RSA PRIVATE KEY") { return "ssh-rsa" }
        if text.contains("BEGIN EC PRIVATE KEY") { return "ecdsa" }
        if text.contains("BEGIN DSA PRIVATE KEY") { return "ssh-dss" }
        return ""
    }

    /// Parses the contents of a `.pub` file into an `SSHPublicKey`.
    /// `siblings` is the set of files in the same directory, used to find the
    /// matching private key.
    public static func parsePublicKey(_ text: String, url: URL, siblings: Set<String>) -> SSHPublicKey? {
        let fields =
            text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            .map(String.init)
        guard fields.count >= 2 else { return nil }

        let algorithm = fields[0]
        let blob = fields[1]
        let comment = fields.count >= 3 ? fields[2] : ""
        guard let fingerprint = fingerprint(base64Blob: blob) else { return nil }

        let privateName = url.deletingPathExtension().lastPathComponent
        let privateKeyURL =
            siblings.contains(privateName)
            ? url.deletingLastPathComponent().appendingPathComponent(privateName)
            : nil

        return SSHPublicKey(
            id: UUID(),
            publicKeyURL: url,
            privateKeyURL: privateKeyURL,
            algorithm: algorithm,
            fingerprint: fingerprint,
            comment: comment
        )
    }

    // MARK: - Health audit inputs

    /// Gathers the per-key facts the pure `KeyAuditor` needs (RSA bit length,
    /// encryption state, file permissions) by reading files through the supplied
    /// closures. `readText`/`mode` come from the sandbox-scoped `SSHFileAccess`, so
    /// this stays I/O-injectable and the audit itself stays pure.
    public static func auditInputs(
        keys: [SSHPublicKey],
        readText: (URL) -> String?,
        mode: (URL) -> Int?
    ) -> [KeyAuditor.KeyInput] {
        keys.map { key in
            var rsaBits: Int? = nil
            if key.algorithm.lowercased() == "ssh-rsa" {
                if let pub = key.publicKeyURL, let text = readText(pub) {
                    rsaBits = rsaBitsFromPubFile(text)
                } else if let priv = key.privateKeyURL, let pem = readText(priv),
                    let info = OpenSSHPrivateKey.publicKeyInfo(pem: pem)
                {
                    rsaBits = KeyAuditor.rsaBitLength(blob: info.blob)
                }
            }

            var isEncrypted: Bool? = nil
            if let priv = key.privateKeyURL, let pem = readText(priv) {
                isEncrypted = privateKeyEncrypted(pem: pem)
            }

            return KeyAuditor.KeyInput(
                key: key,
                rsaBits: rsaBits,
                isEncrypted: isEncrypted,
                privateKeyMode: key.privateKeyURL.flatMap(mode),
                publicKeyMode: key.publicKeyURL.flatMap(mode))
        }
    }

    /// RSA modulus bit length parsed from a `.pub` file's contents, or nil if it
    /// isn't an `ssh-rsa` key.
    public static func rsaBitsFromPubFile(_ text: String) -> Int? {
        let fields =
            text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            .map(String.init)
        guard fields.count >= 2, fields[0] == "ssh-rsa" else { return nil }
        return KeyAuditor.rsaBitLength(base64Blob: fields[1])
    }

    /// Whether a private key is passphrase-encrypted. `nil` when the format isn't
    /// recognized. Only reads the header — never decrypts, never holds key material.
    public static func privateKeyEncrypted(pem: String) -> Bool? {
        if pem.contains("BEGIN OPENSSH PRIVATE KEY") {
            return OpenSSHPrivateKey.isEncrypted(pem: pem)
        }
        // Classic PEM ("Proc-Type: 4,ENCRYPTED") and encrypted PKCS#8 both say so.
        if pem.contains("ENCRYPTED") { return true }
        if pem.contains("PRIVATE KEY") { return false }
        return nil
    }

    /// `SHA256:` fingerprint of a base64 blob — see `KeyFingerprint` (SSHConfigCrypto).
    public static func fingerprint(base64Blob: String) -> String? {
        KeyFingerprint.sha256(base64Blob: base64Blob)
    }

    /// `SHA256:` fingerprint of a raw blob — see `KeyFingerprint` (SSHConfigCrypto).
    public static func fingerprint(blob: [UInt8]) -> String? {
        KeyFingerprint.sha256(blob: blob)
    }
}
