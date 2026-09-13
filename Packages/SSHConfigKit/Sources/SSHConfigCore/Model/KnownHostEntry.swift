//
//  KnownHostEntry.swift
//  SSHConfigCore
//
//  One parsed line of a known_hosts file. Parsing/IO lives in the platform
//  KnownHostsService; this pure record + the verifier are shared.
//

import Foundation

// MARK: - Marker

/// The optional trust modifier on a known_hosts line: `@cert-authority` means the
/// key signs host certificates; `@revoked` means the key is explicitly distrusted.
/// `.none` (no marker) is the common case.
public enum KnownHostMarker: String, CaseIterable, Equatable, Sendable {
    case none = ""
    case certAuthority = "@cert-authority"
    case revoked = "@revoked"

    public var displayName: String {
        switch self {
        case .none: return "Normal"
        case .certAuthority: return "Certificate Authority"
        case .revoked: return "Revoked"
        }
    }

    public var helpText: String {
        switch self {
        case .none:
            return "This key is trusted as the host's own key."
        case .certAuthority:
            return
                "This CA key signs host certificates. ssh trusts hosts whose certificates are signed by this CA, for the given host pattern."
        case .revoked:
            return
                "This key is explicitly distrusted. ssh rejects any connection presenting it, even when another entry would otherwise allow it."
        }
    }
}

// MARK: - Entry

public struct KnownHostEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Zero-based index of the physical line in the file (used for deletion).
    public let lineIndex: Int
    /// The exact original line.
    public let raw: String
    /// `@cert-authority` / `@revoked` marker string, if present.
    public let marker: String?
    /// The host field as written, or "(hashed)" for hashed entries.
    public let hostsDisplay: String
    /// Whether the host field is hashed (`|1|...`) and cannot be reversed.
    public let isHashed: Bool
    /// For a hashed entry, the decoded salt (the `|1|<salt>|<hash>` middle field).
    /// `nil` for plain entries or if the base64 couldn't be decoded.
    public let hashSalt: Data?
    /// For a hashed entry, the decoded HMAC-SHA1 of the host name (the trailing
    /// field). Compared against `HMAC-SHA1(key: salt, message: host)` to match.
    public let hashedHost: Data?
    /// Key type, e.g. `ssh-ed25519`.
    public let keyType: String
    /// `SHA256:` fingerprint of the key, if it could be computed.
    public let fingerprint: String?

    /// The base64 key blob from the raw line, or nil when the line has no parsable key.
    ///
    /// The audit needs the blob, not just `keyType`, because an RSA key's modulus size
    /// only exists inside it. Stored, not computed: the audit reads it for every entry on
    /// every pass, and re-splitting `raw` each time put a string scan per known host on
    /// the path of a SwiftUI render.
    public let keyBlobBase64: String?

    /// Typed accessor for the marker string.
    ///
    /// Case-folded before matching, because OpenSSH's `load_host_keys` compares the
    /// marker with `strncasecmp` — `@Revoked` and `@REVOKED` are valid, honoured
    /// spellings. An exact `rawValue` lookup silently resolved those to `.none`,
    /// i.e. an ordinary host-key trust record: `KnownHostsVerifier.decide` then put
    /// the entry in `directCandidates`, matched its fingerprint, and returned
    /// `.match` — **trusting the very key the user had revoked**, where ssh refuses.
    public var resolvedMarker: KnownHostMarker {
        guard let m = marker, let v = KnownHostMarker(rawValue: m.lowercased()) else { return .none }
        return v
    }

    public init(
        id: UUID = UUID(), lineIndex: Int, raw: String, marker: String?,
        hostsDisplay: String, isHashed: Bool,
        hashSalt: Data? = nil, hashedHost: Data? = nil,
        keyType: String, fingerprint: String?
    ) {
        self.id = id
        self.lineIndex = lineIndex
        self.raw = raw
        self.marker = marker
        self.hostsDisplay = hostsDisplay
        self.isHashed = isHashed
        self.hashSalt = hashSalt
        self.hashedHost = hashedHost
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.keyBlobBase64 = Self.keyBlob(in: raw, keyType: keyType)
    }

    /// Finds the base64 blob by locating the key-type field rather than by a fixed column,
    /// since an optional `@marker` shifts every field along by one.
    private static func keyBlob(in raw: String, keyType: String) -> String? {
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let typeIndex = fields.firstIndex(where: { $0.caseInsensitiveCompare(keyType) == .orderedSame }),
            fields.index(after: typeIndex) < fields.endIndex
        else { return nil }
        return String(fields[fields.index(after: typeIndex)])
    }
}
