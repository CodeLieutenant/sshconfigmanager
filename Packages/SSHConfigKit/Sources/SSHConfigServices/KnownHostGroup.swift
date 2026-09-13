//
//  KnownHostGroup.swift
//  SSHConfigServices
//
//  One host's worth of known_hosts records, grouped for display. Pure model +
//  grouping logic, lifted out of KnownHostsView so a non-GUI front end (the Linux
//  CLI) can present the same grouping the Mac app does.
//

import Foundation
import SSHConfigCore

// MARK: - Host group model

/// One host's worth of known_hosts records, grouped for display. A non-hashed group
/// merges every line that shares the same host field; all hashed lines collapse into a
/// single synthetic group unless they've been revealed (by search or bulk-reveal).
public struct KnownHostGroup: Identifiable {
    public enum Kind { case hostname, ipAddress, hashed }

    public let id: String
    public let title: String
    public let aliases: [String]
    public let kind: Kind
    /// Host + port to probe for verification; nil for hashed groups (no recoverable name).
    public let connectHost: String?
    public let connectPort: Int
    public let entries: [KnownHostEntry]
    /// `Host` aliases from ssh_config that resolve to this entry.
    public let configAliases: [String]
    /// Non-nil when this group was produced by HMAC-matching a typed or bulk-revealed
    /// candidate; used to show a "hash match" badge.
    public let revealedCandidate: String?

    public init(
        id: String, title: String, aliases: [String], kind: Kind,
        connectHost: String?, connectPort: Int, entries: [KnownHostEntry],
        configAliases: [String], revealedCandidate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.kind = kind
        self.connectHost = connectHost
        self.connectPort = connectPort
        self.entries = entries
        self.configAliases = configAliases
        self.revealedCandidate = revealedCandidate
    }

    public var displayName: String { configAliases.first ?? title }

    public var hostToken: String { ([title] + aliases).joined(separator: ",") }

    public var rowDetail: String {
        var parts: [String] = []
        if displayName != title { parts.append(title) }
        parts.append(entries.count == 1 ? "1 key" : "\(entries.count) keys")
        return parts.joined(separator: " · ")
    }

    /// A group is connectable when it names a concrete host and isn't a pure CA-pattern
    /// group (a CA entry over a wildcard is a signer, not a host to `ssh` into).
    public var isConnectable: Bool {
        guard kind != .hashed else { return false }
        if entries.allSatisfy({ $0.resolvedMarker == .certAuthority })
            && (title.contains("*") || title.contains("?"))
        {
            return false
        }
        return true
    }

    /// `q` must already be lowercased and trimmed.
    public func matches(_ q: String) -> Bool {
        if title.lowercased().contains(q) { return true }
        if aliases.contains(where: { $0.lowercased().contains(q) }) { return true }
        if configAliases.contains(where: { $0.lowercased().contains(q) }) { return true }
        return entries.contains { e in
            e.keyType.lowercased().contains(q) || (e.fingerprint?.lowercased().contains(q) ?? false)
        }
    }

    /// Builds the grouped, ordered model from the store's flat entry list.
    /// `revealedNames` maps entry IDs to candidate names discovered in a previous HMAC
    /// pass; those entries become individual named groups instead of collapsing into
    /// the `__hashed__` catch-all.
    public static func build(
        from entries: [KnownHostEntry],
        configAliasesByHost: [String: [String]] = [:],
        revealedNames: [KnownHostEntry.ID: String] = [:]
    ) -> [KnownHostGroup] {
        var hashedUnrevealed: [KnownHostEntry] = []
        var hashedRevealed: [String: [KnownHostEntry]] = [:]
        var byField: [String: [KnownHostEntry]] = [:]
        var order: [String] = []

        for entry in entries {
            if entry.isHashed {
                if let candidate = revealedNames[entry.id] {
                    hashedRevealed[candidate, default: []].append(entry)
                } else {
                    hashedUnrevealed.append(entry)
                }
                continue
            }
            if byField[entry.hostsDisplay] == nil { order.append(entry.hostsDisplay) }
            byField[entry.hostsDisplay, default: []].append(entry)
        }

        var groups: [KnownHostGroup] = order.map { field in
            let names = field.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let primary = names.first ?? field
            let (host, port) = connectTarget(for: primary)
            let keys = Set(([primary, host] + names).map { $0.lowercased() })
            var seen = Set<String>()
            let configAliases = keys.sorted()
                .flatMap { configAliasesByHost[$0] ?? [] }
                .filter { alias in
                    let lower = alias.lowercased()
                    guard !names.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame })
                    else { return false }
                    return seen.insert(lower).inserted
                }
            return KnownHostGroup(
                id: "host:\(field)",
                title: primary,
                aliases: Array(names.dropFirst()),
                kind: isIPLiteral(primary) ? .ipAddress : .hostname,
                connectHost: host,
                connectPort: port,
                entries: byField[field] ?? [],
                configAliases: configAliases)
        }

        // Revealed hashed entries become individual named groups.
        for candidate in hashedRevealed.keys.sorted() {
            let (host, port) = connectTarget(for: candidate)
            let configAliases = configAliasesByHost[candidate.lowercased()] ?? []
            groups.append(
                KnownHostGroup(
                    id: "revealed:\(candidate)",
                    title: candidate,
                    aliases: [],
                    kind: isIPLiteral(candidate) ? .ipAddress : .hostname,
                    connectHost: host,
                    connectPort: port,
                    entries: hashedRevealed[candidate] ?? [],
                    configAliases: configAliases,
                    revealedCandidate: candidate))
        }

        // Remaining unrevealed hashed entries collapse into one group.
        if !hashedUnrevealed.isEmpty {
            groups.append(
                KnownHostGroup(
                    id: "__hashed__",
                    title: "Hashed entries",
                    aliases: [],
                    kind: .hashed,
                    connectHost: nil,
                    connectPort: 22,
                    entries: hashedUnrevealed,
                    configAliases: []))
        }
        return groups
    }

    public static func connectTarget(for name: String) -> (host: String, port: Int) {
        if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            let host = String(name[name.index(after: name.startIndex)..<close])
            let rest = name[name.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) { return (host, port) }
            return (host, 22)
        }
        return (name, 22)
    }

    public static func isIPLiteral(_ name: String) -> Bool {
        var host = name
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<close])
        }
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { p in (Int(p).map { (0...255).contains($0) }) ?? false }
    }
}
