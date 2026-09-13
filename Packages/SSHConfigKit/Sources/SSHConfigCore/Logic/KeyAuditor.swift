//
//  KeyAuditor.swift
//  SSHConfigCore
//
//  A security audit of the user's SSH keys: weak algorithms, missing passphrases,
//  unsafe file permissions, and orphaned keys no host references. Produces the same
//  `LintFinding` type as `ConfigLinter`, so results render in the one Issues view.
//
//  Pure: it takes already-loaded data plus a permission/encryption snapshot (gathered
//  by the platform layer, never read from disk in here) so the whole audit is unit-
//  testable without a sandbox or real key files.
//

import Foundation

public enum KeyAuditor {
    /// The independently toggleable families of key-health checks. The app lets the
    /// user silence any of these from Settings, so each one gates a `find*` group.
    public enum Category: String, CaseIterable, Sendable {
        /// DSA, short RSA, and NIST P-256 keys.
        case weakAlgorithm
        /// Loose POSIX modes on `~/.ssh`, private keys, and `.pub` files.
        case permissions
        /// Private keys stored without a passphrase.
        case passphrase
        /// Private keys no host's `IdentityFile` references.
        case orphan
    }

    /// One key plus the few facts the audit needs that aren't on `SSHPublicKey`.
    /// The platform layer fills these in (RSA bit length decoded from the blob,
    /// encryption read from the private-key header, POSIX modes from the filesystem).
    public struct KeyInput: Equatable {
        public let key: SSHPublicKey
        /// RSA modulus bit length, when the key is RSA and it could be decoded.
        public let rsaBits: Int?
        /// Whether the private key is passphrase-encrypted. `nil` when unknown
        /// (no private key on disk, or an unrecognized format).
        public let isEncrypted: Bool?
        /// POSIX permission bits of the private/public key files, or `nil` if absent.
        public let privateKeyMode: Int?
        public let publicKeyMode: Int?

        public init(
            key: SSHPublicKey, rsaBits: Int? = nil, isEncrypted: Bool? = nil,
            privateKeyMode: Int? = nil, publicKeyMode: Int? = nil
        ) {
            self.key = key
            self.rsaBits = rsaBits
            self.isEncrypted = isEncrypted
            self.privateKeyMode = privateKeyMode
            self.publicKeyMode = publicKeyMode
        }
    }

    /// Key base names ssh tries automatically even without an explicit `IdentityFile`,
    /// so they must never be reported as "orphaned".
    private static let defaultIdentityNames: Set<String> = [
        "id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk", "id_dsa",
    ]

    /// Runs every enabled check. `sshDirectory` is the granted folder's path + mode,
    /// used to flag (and offer to fix) a too-permissive `~/.ssh`. `enabled` selects
    /// which check families run, so the user can silence categories from Settings;
    /// it defaults to everything.
    public static func audit(
        keys: [KeyInput],
        documents: [SSHConfigDocument],
        sshDirectory: (path: String, mode: Int)? = nil,
        enabled: Set<Category> = Set(Category.allCases)
    ) -> [LintFinding] {
        var findings: [LintFinding] = []

        if enabled.contains(.permissions), let dir = sshDirectory, dir.mode & 0o077 != 0 {
            findings.append(
                LintFinding(
                    severity: .warning, blockID: nil,
                    title: "SSH folder has loose permissions",
                    detail: "“\(octal(dir.mode))” lets other users into ~/.ssh. It should be 0700 (owner-only).",
                    fix: .setPermissions(path: dir.path, mode: 0o700, label: "Fix to 0700")))
        }

        let referenced = referencedIdentityNames(documents).union(defaultIdentityNames)

        for input in keys {
            if enabled.contains(.weakAlgorithm) { findings.append(contentsOf: weakAlgorithmFindings(input)) }
            if enabled.contains(.permissions) { findings.append(contentsOf: permissionFindings(input)) }
            if enabled.contains(.passphrase) { findings.append(contentsOf: passphraseFindings(input)) }
            if enabled.contains(.orphan) { findings.append(contentsOf: orphanFindings(input, referenced: referenced)) }
        }

        return findings.sorted { $0.severity > $1.severity }
    }

    // MARK: - Checks

    private static func weakAlgorithmFindings(_ input: KeyInput) -> [LintFinding] {
        let name = input.key.name
        let algo = input.key.algorithm.lowercased()
        // Only weak keys with a private half are worth replacing in-app.
        let replacement: LintFix? =
            input.key.privateKeyURL != nil
            ? .generateReplacement(comment: input.key.comment, originalName: name)
            : nil

        if algo == "ssh-dss" || algo == "dsa" {
            return [
                LintFinding(
                    severity: .error, blockID: nil,
                    title: "“\(name)” is a DSA key",
                    detail:
                        "DSA keys are limited to 1024 bits and are disabled by default in modern OpenSSH. Replace it with an Ed25519 key.",
                    fix: replacement)
            ]
        }

        if algo == "ssh-rsa", let bits = input.rsaBits {
            if bits < 2048 {
                return [
                    LintFinding(
                        severity: .error, blockID: nil,
                        title: "“\(name)” is a \(bits)-bit RSA key",
                        detail:
                            "RSA keys under 2048 bits are broken. Generate an Ed25519 (or ≥3072-bit RSA) replacement.",
                        fix: replacement)
                ]
            }
            if bits < 3072 {
                return [
                    LintFinding(
                        severity: .warning, blockID: nil,
                        title: "“\(name)” is a \(bits)-bit RSA key",
                        detail:
                            "RSA keys under 3072 bits are considered weak. Prefer an Ed25519 key, or a 3072+-bit RSA key.",
                        fix: replacement)
                ]
            }
        }

        if algo.hasPrefix("ecdsa"), algo.contains("nistp256") {
            return [
                LintFinding(
                    severity: .info, blockID: nil,
                    title: "“\(name)” uses NIST P-256 (ECDSA)",
                    detail:
                        "P-256 is acceptable but the NIST curves are less trusted than Ed25519. Consider Ed25519 for new keys."
                )
            ]
        }

        return []
    }

    private static func permissionFindings(_ input: KeyInput) -> [LintFinding] {
        var findings: [LintFinding] = []
        let name = input.key.name

        // Private key: no group/other access at all (OpenSSH refuses otherwise).
        if let mode = input.privateKeyMode, let url = input.key.privateKeyURL, mode & 0o077 != 0 {
            findings.append(
                LintFinding(
                    severity: .warning, blockID: nil,
                    title: "Private key “\(name)” has loose permissions",
                    detail:
                        "“\(octal(mode))” exposes the private key to other users. It must be 0600 (owner read/write only).",
                    fix: .setPermissions(path: url.path, mode: 0o600, label: "Fix to 0600")))
        }

        // Public key: a `.pub` should not be group/other-writable.
        if let mode = input.publicKeyMode, let url = input.key.publicKeyURL, mode & 0o022 != 0 {
            findings.append(
                LintFinding(
                    severity: .warning, blockID: nil,
                    title: "Public key “\(name).pub” is writable by others",
                    detail: "“\(octal(mode))” lets other users modify the public key. It should be 0644.",
                    fix: .setPermissions(path: url.path, mode: 0o644, label: "Fix to 0644")))
        }

        return findings
    }

    private static func passphraseFindings(_ input: KeyInput) -> [LintFinding] {
        guard input.isEncrypted == false, input.key.privateKeyURL != nil else { return [] }
        return [
            LintFinding(
                severity: .warning, blockID: nil,
                title: "Private key “\(input.key.name)” has no passphrase",
                detail:
                    "An unencrypted private key is usable by anyone who can read the file. Add a passphrase with `ssh-keygen -p`, or load it into the agent instead."
            )
        ]
    }

    private static func orphanFindings(_ input: KeyInput, referenced: Set<String>) -> [LintFinding] {
        // Only private keys are worth flagging; a stray `.pub` is harmless.
        guard input.key.privateKeyURL != nil, !referenced.contains(input.key.name) else { return [] }
        return [
            LintFinding(
                severity: .info, blockID: nil,
                title: "“\(input.key.name)” isn't used by any host",
                detail:
                    "No host’s IdentityFile references this key. It may be used on a remote not in this config, or it may be safe to remove.",
                fix: .deleteOrphanedKey(
                    privateKeyPath: input.key.privateKeyURL?.path,
                    publicKeyPath: input.key.publicKeyURL?.path,
                    name: input.key.name))
        ]
    }

    // MARK: - Helpers

    /// The base file names of every `IdentityFile` referenced across all host blocks,
    /// `~`-expanded and `.pub` suffix dropped, for orphan matching.
    public static func referencedIdentityNames(_ documents: [SSHConfigDocument]) -> Set<String> {
        var names: Set<String> = []
        for document in documents {
            for block in document.blocks where block.kind == .host {
                for directive in block.directives(for: "IdentityFile") {
                    let value = directive.value
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    guard !value.isEmpty else { continue }
                    let expanded = (value as NSString).expandingTildeInPath
                    var base = (expanded as NSString).lastPathComponent
                    if base.hasSuffix(".pub") { base = String(base.dropLast(4)) }
                    names.insert(base)
                }
            }
        }
        return names
    }

    /// A `0NNN`-style octal rendering of POSIX permission bits, for messages.
    private static func octal(_ mode: Int) -> String {
        "0" + String(mode & 0o777, radix: 8)
    }

    // MARK: - RSA bit length (pure byte math over the public blob)

    /// The modulus bit length of an `ssh-rsa` public key from its base64 blob, or nil
    /// if the blob isn't RSA / can't be decoded.
    public static func rsaBitLength(base64Blob: String) -> Int? {
        guard let data = Data(base64Encoded: base64Blob) else { return nil }
        return rsaBitLength(blob: [UInt8](data))
    }

    /// The modulus bit length of an `ssh-rsa` public key from its raw wire blob.
    /// Layout: `string "ssh-rsa" || mpint e || mpint n`; `n`'s bit length is the size.
    public static func rsaBitLength(blob: [UInt8]) -> Int? {
        var reader = ByteReader(blob)
        guard let typeBytes = try? reader.readString(),
            String(decoding: typeBytes, as: UTF8.self) == "ssh-rsa",
            (try? reader.readString()) != nil, // e
            let n = try? reader.readString()
        else { return nil }
        return bitLength(of: n)
    }

    /// Bit length of a big-endian magnitude, ignoring leading zero (sign) bytes.
    private static func bitLength(of mpint: [UInt8]) -> Int? {
        let trimmed = Array(mpint.drop { $0 == 0 })
        guard let top = trimmed.first else { return 0 }
        var bits = (trimmed.count - 1) * 8
        var value = top
        while value != 0 {
            bits += 1
            value >>= 1
        }
        return bits
    }
}
