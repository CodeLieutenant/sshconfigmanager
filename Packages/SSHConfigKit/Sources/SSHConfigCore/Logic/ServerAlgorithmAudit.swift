//
//  ServerAlgorithmAudit.swift
//  SSHConfigCore
//
//  Judges the cryptography on the *server* side of a connection, the way `KeyAuditor`
//  judges the user's own keys — same severities, same thresholds, so a 2048-bit RSA key
//  reads the same whether it is yours or the server's.
//
//  Three callers feed it, and they see different things:
//    - the known_hosts audit, which knows only the stored host key (offline, every server
//      you have ever trusted),
//    - the Verify scan, which sees everything a server *offers* before you trust it,
//    - a live tunnel, which sees the one set of algorithms actually negotiated.
//
//  Pure: names and bit lengths in, verdicts out. No I/O, no network.
//

import Foundation

public enum ServerAlgorithmAudit {
    /// Which part of the handshake an algorithm belongs to. Drives the wording, and lets
    /// the UI group offered algorithms under the right heading.
    public enum Role: String, Sendable, CaseIterable {
        case hostKey
        case keyExchange
        case cipher
        case mac

        public var label: String {
            switch self {
            case .hostKey: return "Host key"
            case .keyExchange: return "Key exchange"
            case .cipher: return "Cipher"
            case .mac: return "MAC"
            }
        }
    }

    /// One algorithm and what we think of it.
    public struct Verdict: Sendable, Equatable, Identifiable {
        public var id: String { "\(role.rawValue)\u{1}\(name)" }
        public let role: Role
        /// The algorithm name as it appears on the wire.
        public let name: String
        /// nil when the algorithm is fine — the common case, and what lets a caller
        /// filter to just the problems.
        public let severity: LintFinding.Severity?
        /// Why, in one sentence. Empty when there is nothing wrong.
        public let reason: String

        public var isWeak: Bool { severity != nil }

        public init(role: Role, name: String, severity: LintFinding.Severity?, reason: String) {
            self.role = role
            self.name = name
            self.severity = severity
            self.reason = reason
        }
    }

    // MARK: - Host keys

    /// Judges a host key by type and, for RSA, modulus size.
    ///
    /// The RSA thresholds match `KeyAuditor`: under 2048 is broken, under 3072 is weak.
    /// `bits` is nil when the key is not RSA or the blob could not be decoded, in which
    /// case only the type is judged.
    ///
    /// `nameIsSignatureAlgorithm` distinguishes the two places a host key type is read.
    /// On the wire the name *is* the signature algorithm, so `ssh-rsa` means SHA-1 and is
    /// worth mentioning. In `known_hosts` the same field only names the key family — an
    /// RSA key stored as `ssh-rsa` is signed with `rsa-sha2-*` by any current server — so
    /// saying the same thing there would be wrong.
    public static func hostKeyVerdict(
        type: String, bits: Int? = nil, nameIsSignatureAlgorithm: Bool = true
    ) -> Verdict {
        let name = type.lowercased()
        let display = bits.map { "\(type) (\($0)-bit)" } ?? type

        if name == "ssh-dss" || name == "ssh-dsa" {
            return Verdict(
                role: .hostKey, name: display, severity: .error,
                reason:
                    "DSA host keys are capped at 1024 bits and are disabled by default in modern OpenSSH.")
        }

        if name == "ssh-rsa" || name.hasPrefix("rsa-sha2") {
            if let bits {
                if bits < 2048 {
                    return Verdict(
                        role: .hostKey, name: display, severity: .error,
                        reason: "RSA host keys under 2048 bits are broken.")
                }
                if bits < 3072 {
                    return Verdict(
                        role: .hostKey, name: display, severity: .warning,
                        reason:
                            "RSA host keys under 3072 bits are considered weak. Ed25519 or 3072+-bit RSA is preferred.")
                }
            }
            // `ssh-rsa` names the SHA-1 signature algorithm, which OpenSSH 8.8 disabled by
            // default. The key itself is the same as `rsa-sha2-*` — only the signature
            // algorithm differs — so this is worth saying, not worth alarming over.
            if name == "ssh-rsa", nameIsSignatureAlgorithm {
                return Verdict(
                    role: .hostKey, name: display, severity: .info,
                    reason:
                        "This key is announced as `ssh-rsa`, the SHA-1 signature algorithm OpenSSH 8.8 disabled by default. The key itself is fine; the server should offer `rsa-sha2-256`/`rsa-sha2-512`."
                )
            }
            return ok(.hostKey, display)
        }

        if name.contains("nistp256") {
            return Verdict(
                role: .hostKey, name: display, severity: .info,
                reason: "P-256 is acceptable, but the NIST curves are less trusted than Ed25519.")
        }

        return ok(.hostKey, display)
    }

    /// Judges the host key recorded in a `known_hosts` entry, decoding the RSA modulus
    /// size out of the stored blob so a 2048-bit key is caught without touching the network.
    public static func hostKeyVerdict(for entry: KnownHostEntry) -> Verdict {
        let bits = entry.keyBlobBase64.flatMap { KeyAuditor.rsaBitLength(base64Blob: $0) }
        return hostKeyVerdict(type: entry.keyType, bits: bits, nameIsSignatureAlgorithm: false)
    }

    /// Issues-screen findings for every weak host key in `known_hosts`.
    ///
    /// Revoked entries are skipped: the whole point of an `@revoked` marker is that the key
    /// is already refused, so warning that it is also weak is noise. Entries are collapsed
    /// by host and key type, because one server appearing under several names or addresses
    /// should not produce the same warning several times over.
    public static func knownHostsFindings(_ entries: [KnownHostEntry]) -> [LintFinding] {
        // Judged per host, not per entry. A server publishes one key per algorithm and
        // ssh negotiates the strongest both sides support, so a host that also offers
        // Ed25519 is not at risk because it happens to keep an ECDSA key around. Flagging
        // every stored key produced a dozen findings on a completely healthy machine —
        // which is how a security badge becomes something users learn to ignore.
        var byHost: [String: [Verdict]] = [:]
        var order: [String] = []

        for entry in entries where entry.resolvedMarker != .revoked {
            // A hashed entry's host cannot be recovered, so it can only stand alone.
            let host = entry.isHashed ? "hashed:\(entry.id)" : entry.hostsDisplay
            if byHost[host] == nil { order.append(host) }
            byHost[host, default: []].append(hostKeyVerdict(for: entry))
        }

        return order.compactMap { host -> LintFinding? in
            guard let verdicts = byHost[host] else { return nil }
            // One usable key is enough: that is the one ssh will pick.
            guard verdicts.allSatisfy(\.isWeak) else { return nil }
            // Report the best of a bad set, since that is still what would be negotiated.
            guard let best = verdicts.min(by: { ($0.severity ?? .info) < ($1.severity ?? .info) }),
                let severity = best.severity, severity > .info
            else { return nil }
            let display = host.hasPrefix("hashed:") ? "A hashed known_hosts entry" : host
            return self.finding(for: best, host: display)
        }
    }

    // MARK: - Negotiated / offered algorithms

    /// Judges a key exchange, cipher or MAC name.
    public static func verdict(role: Role, name: String) -> Verdict {
        switch role {
        case .hostKey: return hostKeyVerdict(type: name)
        case .keyExchange: return keyExchangeVerdict(name)
        case .cipher: return cipherVerdict(name)
        case .mac: return macVerdict(name)
        }
    }

    private static func keyExchangeVerdict(_ name: String) -> Verdict {
        let lower = name.lowercased()
        // The two outright-broken cases first: both end in `-sha1`, so the general SHA-1
        // rule below would otherwise swallow them and under-report as a mere warning.
        if lower == "diffie-hellman-group1-sha1" {
            return Verdict(
                role: .keyExchange, name: name, severity: .error,
                reason: "Group 1 is a 1024-bit MODP group and its exchange is SHA-1 based. It is considered broken.")
        }
        if lower == "diffie-hellman-group-exchange-sha1" {
            return Verdict(
                role: .keyExchange, name: name, severity: .error,
                reason: "SHA-1 group exchange lets the server pick a weak group. It is considered broken.")
        }
        if lower.hasSuffix("-sha1") {
            return Verdict(
                role: .keyExchange, name: name, severity: .warning,
                reason: "SHA-1 based key exchange is deprecated. Prefer curve25519-sha256 or an ML-KEM hybrid.")
        }
        return ok(.keyExchange, name)
    }

    private static func cipherVerdict(_ name: String) -> Verdict {
        let lower = name.lowercased()
        if lower.hasPrefix("arcfour") || lower == "none" {
            return Verdict(
                role: .cipher, name: name, severity: .error,
                reason: lower == "none"
                    ? "This connection would not be encrypted at all."
                    : "RC4 is broken and was removed from OpenSSH years ago.")
        }
        if lower.hasPrefix("3des") || lower.hasPrefix("blowfish") || lower.hasPrefix("cast128") {
            return Verdict(
                role: .cipher, name: name, severity: .error,
                reason: "64-bit block ciphers are vulnerable to birthday attacks on long-lived connections.")
        }
        if lower.hasSuffix("-cbc") {
            return Verdict(
                role: .cipher, name: name, severity: .warning,
                reason:
                    "CBC mode in SSH is vulnerable to a plaintext-recovery attack. Prefer a CTR or AEAD cipher.")
        }
        return ok(.cipher, name)
    }

    private static func macVerdict(_ name: String) -> Verdict {
        let lower = name.lowercased()
        if lower.contains("md5") {
            return Verdict(
                role: .mac, name: name, severity: .error,
                reason: "MD5 is broken and must not be used for integrity.")
        }
        if lower.contains("sha1") {
            return Verdict(
                role: .mac, name: name, severity: .warning,
                reason: "SHA-1 is deprecated. Prefer hmac-sha2-256-etm@openssh.com or hmac-sha2-512-etm@openssh.com.")
        }
        if lower.hasPrefix("umac-64") {
            return Verdict(
                role: .mac, name: name, severity: .warning,
                reason: "A 64-bit tag is too short. Prefer umac-128-etm@openssh.com or an HMAC-SHA2 variant.")
        }
        // Encrypt-and-MAC is weaker than encrypt-then-MAC, but saying so about every
        // non-ETM name would flag most of a healthy server's list. Not worth the noise.
        return ok(.mac, name)
    }

    // MARK: - Rollups

    /// Every weak algorithm in a set, worst first. Used for the "what does this server
    /// offer" view and for the negotiated-algorithm summary alike.
    public static func weaknesses(in verdicts: [Verdict]) -> [Verdict] {
        verdicts.filter(\.isWeak).sorted { ($0.severity ?? .info) > ($1.severity ?? .info) }
    }

    /// The worst severity across a set, or nil when everything is fine.
    public static func worstSeverity(in verdicts: [Verdict]) -> LintFinding.Severity? {
        verdicts.compactMap(\.severity).max()
    }

    /// Turns a host-key verdict into an Issues-screen finding. `host` is the known_hosts
    /// host field. Returns nil when there is nothing wrong.
    public static func finding(for verdict: Verdict, host: String) -> LintFinding? {
        guard let severity = verdict.severity else { return nil }
        return LintFinding(
            severity: severity, blockID: nil,
            title: "“\(host)” uses \(article(verdict.name)) \(verdict.name) \(verdict.role.label.lowercased())",
            detail: verdict.reason)
    }

    private static func ok(_ role: Role, _ name: String) -> Verdict {
        Verdict(role: role, name: name, severity: nil, reason: "")
    }

    private static func article(_ name: String) -> String {
        "aeiouAEIOU".contains(name.first ?? "x") ? "an" : "a"
    }
}
