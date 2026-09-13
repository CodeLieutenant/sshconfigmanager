//
//  JumpChain.swift
//  sshconfigmanager
//
//  Authoring-side model for a `ProxyJump` value: a mutable, ordered list of hops
//  that round-trips losslessly through the directive string. This is the wizard's
//  domain object — distinct from `TunnelJumpChain.JumpSpec`, which drives the
//  in-process engine and is intentionally immutable.
//

import Foundation

/// A single hop in a `ProxyJump` chain as typed by the user.
/// `id` is stable for the lifetime of an editing session (ForEach / reorder).
public struct JumpHop: Equatable, Identifiable {
    public var id: UUID
    public var user: String?
    /// An alias name or literal host/IP. IPv6 addresses are stored without brackets;
    /// `render()` re-brackets them when needed.
    public var host: String
    public var port: Int?

    public init(id: UUID = UUID(), user: String? = nil, host: String, port: Int? = nil) {
        self.id = id
        self.user = user
        self.host = host
        self.port = port
    }

    /// The display label used in the topology graph, matching what `ssh -J` emits.
    public var label: String {
        var s = ""
        if let user { s += "\(user)@" }
        if host.contains(":") && !host.hasPrefix("[") {
            s += "[\(host)]"
        } else {
            s += host
        }
        if let port { s += ":\(port)" }
        return s
    }
}

/// The authoring model for a `ProxyJump` directive: an ordered list of hops that
/// serialises back to the comma-separated directive value.
public struct JumpChain: Equatable {
    /// Ordered hops, first = closest to the client. Empty when the chain is `none`
    /// or unset.
    public var hops: [JumpHop]
    /// `true` when the directive should be `ProxyJump none` (explicitly disables
    /// jumping, useful to override a wildcard default).
    public var isNone: Bool

    public init(hops: [JumpHop] = [], isNone: Bool = false) {
        self.hops = hops
        self.isNone = isNone
    }

    /// Parses a raw `ProxyJump` value into a `JumpChain`. `"none"` (case-insensitive)
    /// returns `isNone: true`. Empty or blank strings return an empty chain.
    public static func parse(_ value: String) -> JumpChain {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return JumpChain() }
        if trimmed.lowercased() == "none" { return JumpChain(isNone: true) }
        let specs = TunnelJumpChain.parseProxyJump(trimmed)
        let hops = specs.map { JumpHop(user: $0.user, host: $0.host, port: $0.port) }
        return JumpChain(hops: hops)
    }

    /// Re-serialises to the directive value: `"none"`, the comma-joined hop labels,
    /// or `""` when empty (caller should pass `nil` to `setValue` in that case).
    public func render() -> String {
        if isNone { return "none" }
        return hops.map(\.label).joined(separator: ",")
    }
}
