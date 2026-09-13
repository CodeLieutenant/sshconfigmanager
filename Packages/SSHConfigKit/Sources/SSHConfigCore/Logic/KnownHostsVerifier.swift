//
//  KnownHostsVerifier.swift
//  sshconfigmanager
//
//  Decides whether to trust a server's host key by comparing its fingerprint
//  against ~/.ssh/known_hosts entries. Pure (operates on parsed entries) so the
//  trust logic is unit-testable; the in-process tunnel engine wraps it in a
//  NIOSSH host-key delegate.
//

import Foundation

public enum HostKeyDecision: Equatable {
    case match // host known, key matches → trust
    case mismatch // host known, key differs → refuse (possible MITM)
    case unknown // host not in known_hosts → trust-on-first-use
}

/// `StrictHostKeyChecking` policy. Real ssh's default, `ask`, prompts interactively
/// for both an unknown host and a changed one; this engine has no TTY prompt mid
/// handshake, so unset/`ask` degrades to `.acceptNew` (today's TOFU behavior) rather
/// than hanging on a prompt that can never appear.
public enum HostKeyCheckingPolicy: Sendable, Equatable {
    case strict // `yes`/`strict`: refuse both unknown and changed keys
    case acceptNew // unset/`ask`/`accept-new`: trust unknown, refuse changed
    case off // `no`/`off`: trust unknown and changed keys

    public init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "yes", "strict": self = .strict
        case "no", "off": self = .off
        default: self = .acceptNew
        }
    }
}

/// What to actually do about a connection, once `HostKeyCheckingPolicy` is applied
/// on top of the raw `HostKeyDecision`. Kept separate from `decide` so the pure
/// fingerprint-matching logic stays policy-agnostic and its existing tests are
/// untouched.
public enum HostKeyAction: Equatable {
    case trust
    case refuse(reason: String)
}

public enum KnownHostsVerifier {
    /// Computes the known_hosts HMAC-SHA1 of a host name under a salt. Injected by
    /// the platform layer (CryptoKit / swift-crypto) so this module stays
    /// Foundation-only and portable. Signature: `(salt, message) -> digest`.
    public typealias HMACSHA1 = (_ salt: Data, _ message: Data) -> Data

    /// Decides trust for a server key (by SHA256 fingerprint) at `host:port`.
    ///
    /// Pass `hmacSHA1` to also match hashed (`|1|salt|hash`) entries — without it,
    /// a host whose only known_hosts records are hashed (the default when
    /// `HashKnownHosts yes`, e.g. on Debian/Ubuntu) would resolve to `.unknown`
    /// even when the key actually changed, silently downgrading a `.mismatch`
    /// (possible MITM) to trust-on-first-use.
    public static func decide(
        host: String, port: Int,
        fingerprint: String?,
        entries: [KnownHostEntry],
        hmacSHA1: HMACSHA1? = nil
    ) -> HostKeyDecision {
        let candidates = entries.filter { entry in
            if entry.isHashed {
                guard let hmacSHA1 else { return false }
                return matchesHashed(entry, host: host, port: port, hmacSHA1: hmacSHA1)
            }
            return matches(entry, host: host, port: port)
        }
        guard !candidates.isEmpty else { return .unknown }
        guard let fingerprint else { return .mismatch }
        // @revoked entries whose fingerprint matches must be refused, not trusted.
        // @cert-authority entries are CA trust records, not direct host-key records —
        // treat them as non-matching so they don't conflate CA and host-key trust.
        let directCandidates = candidates.filter { $0.resolvedMarker == .none }
        let revokedMatch = candidates.contains { $0.resolvedMarker == .revoked && $0.fingerprint == fingerprint }
        if revokedMatch { return .mismatch }
        guard !directCandidates.isEmpty else { return .unknown }
        return directCandidates.contains { $0.fingerprint == fingerprint } ? .match : .mismatch
    }

    /// Resolves a raw `HostKeyDecision` against `StrictHostKeyChecking` policy into
    /// what the caller should actually do. `.match` always trusts regardless of
    /// policy — policy only changes the `.unknown`/`.mismatch` outcomes.
    public static func action(
        for decision: HostKeyDecision, policy: HostKeyCheckingPolicy,
        host: String
    ) -> HostKeyAction {
        switch (decision, policy) {
        case (.match, _):
            return .trust
        case (.unknown, .strict):
            return .refuse(
                reason: "Host key for \(host) is unknown and StrictHostKeyChecking "
                    + "is enabled — refused")
        case (.unknown, .acceptNew), (.unknown, .off):
            return .trust
        case (.mismatch, .off):
            return .trust
        case (.mismatch, .strict), (.mismatch, .acceptNew):
            return .refuse(reason: "Host key MISMATCH for \(host) — refused (possible MITM)")
        }
    }

    /// Whether a (non-hashed) entry's host field covers `host`/`host:port`.
    ///
    /// Implements OpenSSH host-pattern matching: a comma-separated list of patterns,
    /// each of which may use `*` / `?` wildcards and may be negated with a leading `!`.
    /// A target matches if it matches at least one positive pattern and no negated one.
    /// Previously this was an exact string compare, so a real known_hosts wildcard entry
    /// like `*.corp.example.com` never matched `db1.corp.example.com` and silently
    /// downgraded to trust-on-first-use where ssh would hard-fail on a changed key
    /// (audit #10).
    ///
    /// The target is `host` for the default port and `[host]:port` otherwise — with NO
    /// fallback to a bare-`host` entry for a non-default port, matching OpenSSH (and the
    /// hashed path). Previously a plain `host` entry (recorded for port 22) also covered
    /// every other port, causing false MITM refusals on a legitimately different key on
    /// a second port (audit #12).
    public static func matches(_ entry: KnownHostEntry, host: String, port: Int) -> Bool {
        let patterns = entry.hostsDisplay
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // OpenSSH folds hostname case before matching, so an uppercase known_hosts
        // entry must still match a lowercase connection (audit #35). Case-fold at this
        // (SSH-hostname) layer, NOT inside hostPatternMatch, which stays an exact glob.
        let target = (port == 22 ? host : "[\(host)]:\(port)").lowercased()
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                // A negated pattern that matches excludes the host outright.
                if hostPatternMatch(String(pattern.dropFirst()).lowercased(), target) { return false }
            } else if hostPatternMatch(pattern.lowercased(), target) {
                matched = true
            }
        }
        return matched
    }

    /// glob-style match supporting `*` (zero or more chars) and `?` (exactly one char),
    /// like OpenSSH's `match_pattern`. No wildcards → exact comparison, so existing
    /// literal entries behave exactly as before.
    public static func hostPatternMatch(_ pattern: String, _ name: String) -> Bool {
        if !pattern.contains("*") && !pattern.contains("?") { return pattern == name }
        let p = Array(pattern)
        let s = Array(name)
        var pi = 0
        var si = 0
        var star = -1
        var mark = 0
        while si < s.count {
            // The `*` case MUST be checked before the literal/`?` case, otherwise a
            // literal `*` in the NAME would satisfy `p[pi] == s[si]` and consume the
            // pattern's star as an ordinary character instead of a wildcard.
            if pi < p.count, p[pi] == "*" {
                star = pi
                mark = si
                pi += 1 // remember the star position
            } else if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1
                si += 1
            } else if star != -1 {
                pi = star + 1
                mark += 1
                si = mark // backtrack: let the star eat one more
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Whether a hashed entry matches `host:port`, recomputing the HMAC over the
    /// same canonical name OpenSSH would have hashed (`host` for port 22, else
    /// `[host]:port`).
    public static func matchesHashed(
        _ entry: KnownHostEntry, host: String, port: Int,
        hmacSHA1: HMACSHA1
    ) -> Bool {
        guard entry.isHashed, let salt = entry.hashSalt, let stored = entry.hashedHost else {
            return false
        }
        let needles = port == 22 ? [host] : ["[\(host)]:\(port)"]
        return needles.contains { needle in
            guard let message = needle.data(using: .utf8) else { return false }
            return hmacSHA1(salt, message) == stored
        }
    }
}
