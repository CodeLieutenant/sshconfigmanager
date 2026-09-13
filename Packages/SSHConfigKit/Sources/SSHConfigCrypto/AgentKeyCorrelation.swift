//
//  AgentKeyCorrelation.swift
//  sshconfigmanager
//
//  Pure correlation between what the agent has loaded (`[AgentIdentity]`) and the
//  keys on disk (`[SSHPublicKey]`), matched by SHA256 fingerprint. This is the
//  "which of my keys is actually being offered?" answer — the most common source
//  of "works in my terminal but not here" confusion — so it's isolated here with
//  no I/O and unit-tested directly.
//

import Foundation
import SSHConfigCore

/// One row in the Agent view: an identity that may exist on disk, in the agent,
/// or both. The view renders a loaded/not-loaded badge from `isLoaded`.
public struct AgentKeyRow: Identifiable, Equatable {
    /// Stable identity for SwiftUI: the disk key's id when known, else a synthetic
    /// id derived from the fingerprint (agent-only keys have no disk record).
    public let id: String
    /// The matching on-disk key, if this identity corresponds to a file we found.
    public let diskKey: SSHPublicKey?
    /// The loaded agent identity, if the agent currently holds this key.
    public let agentIdentity: AgentIdentity?
    public let fingerprint: String
    public let comment: String
    /// Algorithm label (e.g. "ED25519"), preferring the disk key's richer parsing.
    public let typeLabel: String

    public var isLoaded: Bool { agentIdentity != nil }
    /// A key on disk that the agent isn't offering — the actionable "add me" case.
    public var isOnDiskOnly: Bool { diskKey != nil && agentIdentity == nil }

    /// A selection key that survives a refresh that rebuilds the row list. The
    /// fingerprint is stable across reloads where the disk key's UUID `id` is not;
    /// fingerprint-less rows fall back to the (still-unique) `id`.
    public var selectionID: String { fingerprint.isEmpty ? id : fingerprint }
}

public enum AgentKeyCorrelation {
    /// The canonical key used to decide whether a disk key and an agent identity
    /// are the same key: the SHA256 fingerprint of the wire blob. Both this screen
    /// (`merge`) and the tunnel engine (`NIOTunnelEngine.matchingAgentIdentities`)
    /// match through here, so they can never diverge on "is this key loaded?".
    public static func fingerprint(of identity: AgentIdentity) -> String? {
        KeyFingerprint.sha256(blob: identity.keyBlob)
    }

    /// Whether `identity` has the given (non-empty) `SHA256:` fingerprint.
    public static func matchesFingerprint(_ identity: AgentIdentity, _ fingerprint: String) -> Bool {
        !fingerprint.isEmpty && self.fingerprint(of: identity) == fingerprint
    }

    /// Merges disk keys and loaded agent identities into a single, stably-ordered
    /// list. Keys present in both are unified into one row; disk-only keys and
    /// agent-only identities each get their own. Matching is by fingerprint, so a
    /// disk key with an underivable fingerprint never spuriously matches an agent
    /// identity (and vice versa).
    ///
    /// Ordering: loaded keys first (most relevant to "am I offering it?"), then
    /// disk-only keys, each group alphabetised by display name for stability.
    public static func merge(
        diskKeys: [SSHPublicKey],
        agentIdentities: [AgentIdentity]
    ) -> [AgentKeyRow] {
        // Index agent identities by fingerprint so each disk key can find its match.
        var byFingerprint: [String: AgentIdentity] = [:]
        for identity in agentIdentities {
            guard let fp = fingerprint(of: identity) else { continue }
            byFingerprint[fp] = identity
        }

        var rows: [AgentKeyRow] = []
        var matchedFingerprints: Set<String> = []

        for key in diskKeys {
            let identity = key.fingerprint.isEmpty ? nil : byFingerprint[key.fingerprint]
            if identity != nil { matchedFingerprints.insert(key.fingerprint) }
            rows.append(
                AgentKeyRow(
                    id: key.id.uuidString,
                    diskKey: key,
                    agentIdentity: identity,
                    fingerprint: key.fingerprint,
                    comment: identity?.comment.isEmpty == false ? identity!.comment : key.comment,
                    typeLabel: key.typeLabel
                ))
        }

        // Agent identities with no on-disk counterpart (e.g. keys loaded from a
        // path outside the granted folder, or a hardware/1Password identity).
        for identity in agentIdentities {
            guard let fp = fingerprint(of: identity),
                !matchedFingerprints.contains(fp)
            else { continue }
            matchedFingerprints.insert(fp)
            rows.append(
                AgentKeyRow(
                    id: "agent:" + fp,
                    diskKey: nil,
                    agentIdentity: identity,
                    fingerprint: fp,
                    comment: identity.comment,
                    typeLabel: typeLabel(forKeyType: identity.keyType)
                ))
        }

        return rows.sorted { lhs, rhs in
            if lhs.isLoaded != rhs.isLoaded { return lhs.isLoaded }
            return displayName(lhs).localizedCaseInsensitiveCompare(displayName(rhs)) == .orderedAscending
        }
    }

    /// The label shown for a row — the disk file name when known, else the comment
    /// or fingerprint for agent-only identities.
    public static func displayName(_ row: AgentKeyRow) -> String {
        if let diskKey = row.diskKey { return diskKey.name }
        if !row.comment.isEmpty { return row.comment }
        return row.fingerprint
    }

    /// Maps an SSH wire key type (e.g. "ssh-ed25519") to the same human label
    /// `SSHPublicKey.typeLabel` produces, for agent-only rows that have no disk key.
    public static func typeLabel(forKeyType keyType: String) -> String {
        switch keyType {
        case "ssh-ed25519": return "Ed25519"
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": return "RSA"
        case let t where t.hasPrefix("ecdsa-sha2-"): return "ECDSA"
        case let t where t.hasPrefix("sk-"): return "Security Key"
        case "": return "Unknown"
        default: return keyType
        }
    }
}
