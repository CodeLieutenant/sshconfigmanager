//
//  EffectiveConfigResolver+JumpChain.swift
//  sshconfigmanager
//
//  Resolves the full hop sequence for a target host, following every `ProxyJump`
//  alias recursively. The result drives the topology graph in the Jump-Host Wizard
//  and the "What ssh will do" preview. Cycle detection prevents infinite recursion.
//

import Foundation

/// One node in the resolved topology: a jump hop or the final target.
public struct ResolvedHop: Identifiable {
    public let id: UUID
    /// The hop specifier as written in `ProxyJump`, e.g. `"jane@edge:2222"`.
    public let label: String
    /// The resolved `HostName` directive for this hop alias, if it is one.
    public let hostName: String?
    /// The effective user: explicit on the hop spec, else resolved `User`.
    public let user: String?
    /// The effective port: explicit on the hop spec, else resolved `Port`, else 22.
    public let port: Int
    /// Whether this hop matched a `Host` block (alias vs literal address).
    public let isAlias: Bool
    /// The hop's own resolved ProxyJump chain (for nested-badge display).
    public let nested: [ResolvedHop]

    public init(
        id: UUID = UUID(), label: String, hostName: String?,
        user: String?, port: Int, isAlias: Bool, nested: [ResolvedHop]
    ) {
        self.id = id
        self.label = label
        self.hostName = hostName
        self.user = user
        self.port = port
        self.isAlias = isAlias
        self.nested = nested
    }
}

extension EffectiveConfigResolver {
    /// Resolves the fully-expanded hop sequence for `target` by recursively
    /// following each hop's own `ProxyJump`. Returns hops in order
    /// (first = closest to client); the final target is **not** included — callers
    /// append the target node themselves for the topology display.
    ///
    /// Cycles are detected by a visited-set and surfaced as a `ResolvedHop` with
    /// `label == "(cycle detected)"` rather than recursing forever.
    public static func resolveJumpChain(
        target: String,
        in documents: [SSHConfigDocument]
    ) -> [ResolvedHop] {
        var visited: Set<String> = [target.lowercased()]
        return resolveChain(
            for: target, overrideUser: nil, overridePort: nil,
            documents: documents, visited: &visited)
    }

    /// Resolves the hop that corresponds to a jump entry in a `ProxyJump` directive.
    /// Separate from the chain accumulator so it is also usable for nested badges.
    public static func resolveHop(
        spec: JumpHop,
        in documents: [SSHConfigDocument],
        visited: inout Set<String>
    ) -> ResolvedHop {
        let key = spec.host.lowercased()
        let isCycle = !visited.insert(key).inserted
        if isCycle {
            return ResolvedHop(
                label: spec.label, hostName: nil, user: spec.user,
                port: spec.port ?? 22, isAlias: false, nested: [])
        }

        let settings = resolve(target: spec.host, in: documents)
        let isAlias =
            documents
            .flatMap(\.blocks)
            .contains { EffectiveConfigResolver.matches($0, target: spec.host) && $0.kind == .host }

        let resolvedUser = spec.user ?? settings.firstValue(of: "user")
        let resolvedPort = spec.port ?? settings.firstValue(of: "port").flatMap(Int.init) ?? 22
        let resolvedHostName = settings.firstValue(of: "hostname")

        var nested: [ResolvedHop] = []
        if let proxyJump = settings.firstValue(of: "proxyjump") {
            nested = resolveChain(
                for: spec.host, overrideUser: nil, overridePort: nil,
                documents: documents, visited: &visited)
            _ = proxyJump // value read above to trigger resolution
        }

        return ResolvedHop(
            label: spec.label, hostName: resolvedHostName,
            user: resolvedUser, port: resolvedPort,
            isAlias: isAlias, nested: nested)
    }

    private static func resolveChain(
        for alias: String,
        overrideUser: String?, overridePort: Int?,
        documents: [SSHConfigDocument],
        visited: inout Set<String>
    ) -> [ResolvedHop] {
        let settings = resolve(target: alias, in: documents)
        guard let proxyJump = settings.firstValue(of: "proxyjump"),
            proxyJump.lowercased() != "none"
        else { return [] }

        let specs = TunnelJumpChain.parseProxyJump(proxyJump)
        return specs.map { spec in
            let hop = JumpHop(user: spec.user, host: spec.host, port: spec.port)
            return resolveHop(spec: hop, in: documents, visited: &visited)
        }
    }
}
