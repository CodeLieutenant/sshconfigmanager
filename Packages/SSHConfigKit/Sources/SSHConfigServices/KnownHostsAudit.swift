//
//  KnownHostsAudit.swift
//  SSHConfigMacUI
//
//  Pure static analysis of known_hosts content: malformed lines, duplicate
//  entries, and orphaned entries whose host names don't appear in the config or a
//  supplied name set. Network-free — dynamic "key changed" findings come from
//  HostKeyScanner + VerifyOutcome, not this module.
//

import Foundation
import SSHConfigCore

public enum KnownHostsAudit {

    public enum Finding: Equatable {
        /// Line text can't be parsed as a valid known_hosts entry.
        case malformed
        /// An earlier entry already covers the same primary host + key type.
        /// The associated ID is the entry to keep (the first seen).
        case duplicate(of: KnownHostEntry.ID)
        /// No name in `knownNames` matches any host token of this entry.
        /// Advisory — the host may be legitimate but unreferenced in the config.
        case orphan
    }

    /// Static findings for each entry, keyed by entry ID. No I/O.
    ///
    /// Rules:
    /// - **Malformed**: `KnownHostsService.isValidLine` returns false.
    /// - **Duplicate**: same primary host token + key type as an earlier entry
    ///   (case-insensitive). Hashed entries are excluded — their names can't be compared.
    /// - **Orphan**: none of the entry's host tokens (lowercased) appear in
    ///   `knownNames`. `@revoked` entries are excluded — intentionally distrusted
    ///   entries don't need a config block to be valid. Hashed excluded for same
    ///   reason as duplicates.
    public static func staticFindings(
        _ entries: [KnownHostEntry],
        knownNames: Set<String>
    ) -> [KnownHostEntry.ID: Finding] {
        var findings: [KnownHostEntry.ID: Finding] = [:]

        // Malformed
        for entry in entries where !KnownHostsService.isValidLine(entry.raw) {
            findings[entry.id] = .malformed
        }

        // Duplicates — first occurrence wins; later ones are duplicates
        var seen: [String: KnownHostEntry.ID] = [:]
        for entry in entries where !entry.isHashed && findings[entry.id] == nil {
            let names = entry.hostsDisplay
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let primary = (names.first ?? entry.hostsDisplay).lowercased()
            let key = "\(primary):\(entry.keyType.lowercased())"
            if let first = seen[key] {
                findings[entry.id] = .duplicate(of: first)
            } else {
                seen[key] = entry.id
            }
        }

        // Orphans — plain entries whose names don't appear in the config
        let lowercasedNames = Set(knownNames.map { $0.lowercased() })
        for entry in entries
        where !entry.isHashed
            && entry.resolvedMarker != .revoked
            && findings[entry.id] == nil
        {
            let names = entry.hostsDisplay
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if !names.contains(where: { lowercasedNames.contains($0) }) {
                findings[entry.id] = .orphan
            }
        }

        return findings
    }
}
