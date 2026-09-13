//
//  HashedHostSearch.swift
//  SSHConfigMacUI
//
//  Finds known_hosts entries even when HashKnownHosts=yes scrambled their host
//  fields into |1|salt|hash| tokens, by recomputing HMAC-SHA1 for a typed
//  candidate string and comparing it against each stored hash.
//
//  This is the same HMAC path KnownHostsVerifier.matchesHashed uses during a
//  tunnel handshake; here we call it from the search box (query-driven reveal)
//  and from the bulk-reveal pass (config-names-driven reveal).
//

import Crypto
import Foundation
import SSHConfigCore

public enum HashedHostSearch {
    /// CryptoKit HMAC-SHA1 closure, injected so the pure logic in
    /// KnownHostsVerifier stays testable without a CryptoKit dependency.
    public static let platformHMAC: KnownHostsVerifier.HMACSHA1 = { salt, message in
        let key = SymmetricKey(data: salt)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key)
        return Data(mac)
    }

    /// Returns the IDs of hashed entries whose `|1|salt|hash|` host field matches
    /// `candidate`. The candidate is tried as a bare name and, for non-standard
    /// port form `[host]:port`, with the port extracted. Plain (non-hashed) entries
    /// are skipped — they surface through the normal string match in `KnownHostGroup.matches`.
    public static func matching(
        _ candidate: String,
        in entries: [KnownHostEntry],
        hmacSHA1: KnownHostsVerifier.HMACSHA1 = platformHMAC
    ) -> Set<KnownHostEntry.ID> {
        guard !candidate.isEmpty else { return [] }
        let (host, port) = KnownHostGroup.connectTarget(for: candidate)
        var matched = Set<KnownHostEntry.ID>()
        for entry in entries where entry.isHashed {
            if KnownHostsVerifier.matchesHashed(entry, host: host, port: port, hmacSHA1: hmacSHA1) {
                matched.insert(entry.id)
            }
        }
        return matched
    }

    /// Bulk-reveals hashed entries by testing each against a set of candidate names
    /// (e.g. every hostname + alias from the config). Returns a map of entry ID →
    /// the first candidate that matched it. Safe to run off the main actor for large
    /// files; the caller dispatches and merges the result.
    public static func bulkReveal(
        hashed: [KnownHostEntry],
        candidates: [String],
        hmacSHA1: KnownHostsVerifier.HMACSHA1 = platformHMAC
    ) -> [KnownHostEntry.ID: String] {
        var result: [KnownHostEntry.ID: String] = [:]
        for candidate in candidates where !candidate.isEmpty {
            let (host, port) = KnownHostGroup.connectTarget(for: candidate)
            for entry in hashed where result[entry.id] == nil {
                if KnownHostsVerifier.matchesHashed(entry, host: host, port: port, hmacSHA1: hmacSHA1) {
                    result[entry.id] = candidate
                }
            }
        }
        return result
    }
}
