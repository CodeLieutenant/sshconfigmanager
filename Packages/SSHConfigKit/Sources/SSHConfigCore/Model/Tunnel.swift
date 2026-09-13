//
//  Tunnel.swift
//  sshconfigmanager
//
//  The model for SSH port-forwarding tunnels: a saved `TunnelPreset` (persisted
//  app-side, referencing a Host by alias) and the runtime `TunnelStatus` the
//  monitor maintains. See docs/plans/tunneling/state-and-ui.md.
//

import Foundation

/// The three `ssh` forwarding modes.
public enum TunnelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case local // -L  reach a remote service as if it were local
    case remote // -R  expose a local service on the remote host
    case dynamic // -D  SOCKS proxy through the remote host

    public var id: String { rawValue }

    /// The `ssh` flag for this mode.
    public var flag: String {
        switch self {
        case .local: return "-L"
        case .remote: return "-R"
        case .dynamic: return "-D"
        }
    }

    public var label: String {
        switch self {
        case .local: return "Local forward (-L)"
        case .remote: return "Remote forward (-R)"
        case .dynamic: return "Dynamic SOCKS (-D)"
        }
    }

    public var symbol: String {
        switch self {
        case .local: return "arrow.down.left.circle"
        case .remote: return "arrow.up.right.circle"
        case .dynamic: return "globe"
        }
    }

    /// Whether this mode forwards to a target host:port (`-L`/`-R`) vs. just a
    /// listening port (`-D`).
    public var hasTarget: Bool { self != .dynamic }

    /// Whether the listening socket is on the local machine (so it can be probed
    /// for liveness). `-R` listens on the *remote* host, so it can't.
    public var listensLocally: Bool { self != .remote }
}

/// A single port mapping within a tunnel. One preset can carry several.
///
/// For `-L`/`-R` the spec is `[bind:]listenPort:targetHost:targetPort`; for `-D`
/// only `[bind:]listenPort` is used.
public struct PortMapping: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Optional bind address (e.g. `127.0.0.1` or `*`). Empty → ssh's default.
    public var bindAddress: String
    /// The port to listen on (local for `-L`/`-D`, remote for `-R`).
    public var listenPort: Int
    /// The forward target host (`-L`/`-R` only).
    public var targetHost: String
    /// The forward target port (`-L`/`-R` only).
    public var targetPort: Int
    /// Whether the forwarded service serves a web UI reachable at this mapping's
    /// local address — lets the UI offer an "Open Browser" shortcut. Only
    /// meaningful for `-L` (a local, reachable listen port with a fixed target).
    public var hasWebUI: Bool = false

    public init(
        id: UUID = UUID(),
        bindAddress: String = "",
        listenPort: Int = 0,
        targetHost: String = "127.0.0.1",
        targetPort: Int = 0,
        hasWebUI: Bool = false
    ) {
        self.id = id
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.hasWebUI = hasWebUI
    }

    /// The `[bind_address:]port` listen field, as both the `ssh -L/-R/-D` spec and
    /// the `LocalForward`-style directive spell it. IPv6-safe.
    public var listenField: String {
        let prefix = Self.bracketedIfIPv6(bindAddress).map { "\($0):" } ?? ""
        return "\(prefix)\(listenPort)"
    }

    /// The `host:port` target field (`-L`/`-R` only). IPv6-safe.
    public var targetField: String {
        "\(Self.bracketedIfIPv6(targetHost) ?? targetHost):\(targetPort)"
    }

    /// The `ssh` forward-spec string for this mapping under the given mode.
    public func forwardSpec(for mode: TunnelMode) -> String {
        mode.hasTarget ? "\(listenField):\(targetField)" : listenField
    }

    /// A host/bind value ready to sit in a colon-delimited forward field: an IPv6
    /// literal wrapped in `[...]`, anything else unchanged. `nil` when the value is
    /// blank, so the caller can omit the field entirely.
    ///
    /// Without the brackets an IPv6 target rendered as `8080:::1:5432` — ambiguous
    /// garbage that ssh rejects, that the tunnel console displayed, that
    /// "write forwards into ssh config" wrote into `~/.ssh/config`, and that did not
    /// round-trip back through `parsing` (which has always read brackets correctly).
    public static func bracketedIfIPv6(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Already bracketed, or not an IPv6 literal — a bare `:` is the only marker
        // needing escapes, since host names and IPv4 addresses never contain one.
        guard !trimmed.hasPrefix("["), trimmed.contains(":") else { return trimmed }
        return "[\(trimmed)]"
    }

    /// Whether this mapping is complete enough to launch under the given mode.
    public func isValid(for mode: TunnelMode) -> Bool {
        guard (1...65535).contains(listenPort) else { return false }
        guard mode.hasTarget else { return true }
        guard (1...65535).contains(targetPort) else { return false }
        return !targetHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Parses a resolved `LocalForward`/`RemoteForward`/`DynamicForward` directive
    /// value (as `EffectiveConfigResolver` returns it — e.g. `"5432 db.internal:5432"`
    /// or `"127.0.0.1:5432 db.internal:5432"` for local/remote, `"1080"` or
    /// `"127.0.0.1:1080"` for dynamic) into a `PortMapping`. Mirrors `forwardSpec`
    /// in reverse — used by the "Import Forwards from Config" action so a preset
    /// can pick up forwards the user already wrote by hand in `~/.ssh/config`.
    /// Returns `nil` for anything that doesn't parse cleanly rather than guessing.
    public static func parsing(_ value: String, mode: TunnelMode) -> PortMapping? {
        let tokens = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = tokens.first, let (bind, port) = parseBindPort(first) else { return nil }
        if mode.hasTarget {
            guard tokens.count == 2, let (host, targetPort) = parseHostPort(tokens[1]) else { return nil }
            return PortMapping(bindAddress: bind ?? "", listenPort: port, targetHost: host, targetPort: targetPort)
        } else {
            guard tokens.count == 1 else { return nil }
            return PortMapping(bindAddress: bind ?? "", listenPort: port)
        }
    }

    /// Parses `[bind_address:]port`, honoring `[...]`-bracketed IPv6 bind addresses.
    private static func parseBindPort(_ token: String) -> (bind: String?, port: Int)? {
        if token.hasPrefix("[") {
            guard let closeIndex = token.firstIndex(of: "]") else { return nil }
            let bind = String(token[token.index(after: token.startIndex)..<closeIndex])
            let rest = token[token.index(after: closeIndex)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (bind, port)
        }
        if let colonIndex = token.lastIndex(of: ":") {
            guard let port = Int(token[token.index(after: colonIndex)...]) else { return nil }
            return (String(token[token.startIndex..<colonIndex]), port)
        }
        guard let port = Int(token) else { return nil }
        return (nil, port)
    }

    /// Parses `host:port`, honoring `[...]`-bracketed IPv6 target hosts.
    private static func parseHostPort(_ token: String) -> (host: String, port: Int)? {
        if token.hasPrefix("[") {
            guard let closeIndex = token.firstIndex(of: "]") else { return nil }
            let host = String(token[token.index(after: token.startIndex)..<closeIndex])
            let rest = token[token.index(after: closeIndex)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colonIndex = token.lastIndex(of: ":"),
            let port = Int(token[token.index(after: colonIndex)...])
        else { return nil }
        let host = String(token[token.startIndex..<colonIndex])
        guard !host.isEmpty else { return nil }
        return (host, port)
    }
}

/// A saved tunnel definition. Persisted app-side (not in `ssh_config`), keyed to
/// a Host block by its first alias. Connection parameters (compression,
/// keep-alive, exit-on-forward-failure) are governed by the SSH config's own
/// directives (`Compression`, `ServerAliveInterval`, `ExitOnForwardFailure`) and
/// are not duplicated here.
public struct TunnelPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// User-facing name, e.g. "Postgres via bastion".
    public var name: String
    /// The Host alias this tunnel connects through (a block's first pattern).
    public var hostAlias: String
    public var mode: TunnelMode
    public var mappings: [PortMapping]
    /// Start this tunnel automatically when the app launches.
    public var autostart: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        hostAlias: String,
        mode: TunnelMode = .local,
        mappings: [PortMapping] = [PortMapping()],
        autostart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hostAlias = hostAlias
        self.mode = mode
        self.mappings = mappings
        self.autostart = autostart
    }

    /// A display name, falling back to a summary of the first mapping.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if let first = mappings.first { return "\(mode.flag) \(first.forwardSpec(for: mode))" }
        return hostAlias
    }

    /// The local port to probe for liveness, if this mode listens locally.
    public var localProbePort: Int? {
        guard mode.listensLocally, let first = mappings.first else { return nil }
        return (1...65535).contains(first.listenPort) ? first.listenPort : nil
    }

    public var isValid: Bool {
        !hostAlias.trimmingCharacters(in: .whitespaces).isEmpty
            && !mappings.isEmpty
            && mappings.allSatisfy { $0.isValid(for: mode) }
    }

    /// The `ssh_config` forwarding directives equivalent to this preset's
    /// mappings — for the optional "write into ssh config" action.
    /// e.g. `LocalForward 5432 localhost:5432`, `DynamicForward 1080`.
    public var forwardDirectives: [(keyword: String, value: String)] {
        let keyword: String
        switch mode {
        case .local: keyword = "LocalForward"
        case .remote: keyword = "RemoteForward"
        case .dynamic: keyword = "DynamicForward"
        }
        // Composed from the same IPv6-safe fields as `forwardSpec`, so what gets
        // written into `~/.ssh/config` and what the console shows can't diverge.
        return mappings.map { mapping in
            let value =
                mode.hasTarget
                ? "\(mapping.listenField) \(mapping.targetField)"
                : mapping.listenField
            return (keyword, value)
        }
    }
}

/// Bytes pushed through a running tunnel, relative to the SSH link. Counted by
/// the in-process NIO engine and surfaced live in the UI.
public struct TunnelThroughput: Equatable, Sendable {
    public var bytesIn: UInt64 = 0 // received over the SSH link
    public var bytesOut: UInt64 = 0 // sent over the SSH link

    public init(bytesIn: UInt64 = 0, bytesOut: UInt64 = 0) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }

    /// e.g. "↓ 1.2 MB  ↑ 340 KB".
    public var summary: String {
        "↓ \(bytesIn.formatted(.byteCount(style: .file)))  ↑ \(bytesOut.formatted(.byteCount(style: .file)))"
    }
}

/// Severity/kind of a tunnel log line, used to pick an icon and colour in the
/// console. Ordered from quietest to loudest.
public enum TunnelLogLevel: String, Codable, Sendable {
    case status // a status transition (Active, Reconnecting, Failed…)
    case info // a normal lifecycle milestone (connecting, listening…)
    case detail // fine-grained detail (inbound connection, host-key match…)
    case error // a failure or refusal
}

/// One line in a tunnel's log/console: a timestamped message at a level. The
/// console merges status transitions (`.status`) with engine lifecycle lines.
public struct TunnelLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: TunnelLogLevel
    public let message: String

    public init(date: Date, level: TunnelLogLevel, message: String) {
        self.id = UUID()
        self.date = date
        self.level = level
        self.message = message
    }
}

/// The live state of a tunnel, maintained by the TunnelStore supervisor. Runtime-only (not
/// persisted).
public enum TunnelStatus: Equatable, Sendable {
    case stopped
    case starting
    case active(since: Date)
    case degraded
    case retrying(attempt: Int)
    case failed(reason: String)

    /// Whether the tunnel is meant to be up (anything but stopped/failed).
    public var isRunning: Bool {
        switch self {
        case .stopped, .failed: return false
        case .starting, .active, .degraded, .retrying: return true
        }
    }

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .active: return "Active"
        case .degraded: return "Degraded"
        case .retrying(let attempt): return "Reconnecting (try \(attempt))"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    /// SF Symbol name for a status dot.
    public var symbol: String {
        switch self {
        case .stopped: return "circle"
        case .starting, .retrying: return "circle.dotted"
        case .active: return "circle.fill"
        case .degraded: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}
