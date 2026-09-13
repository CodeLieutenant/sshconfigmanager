//
//  StatusBadge.swift
//  sshconfigmanager
//
//  One status indicator for the whole app: a colour-tinted SF Symbol plus an optional
//  label. This generalises the former `TunnelStatusBadge` (which is now a thin adapter
//  over it) so the tunnel badge, the agent "Loaded/Not loaded" pill, the sidebar dot,
//  issue severities, and the menu-bar rows all render identically and read their colour
//  from `StatusKind` — the single status vocabulary in `Theme.swift`. Shape and colour
//  both convey state, so it never relies on colour alone.
//

import SSHConfigCore
import SwiftUI

struct StatusBadge: View {
    let kind: StatusKind
    /// Inline label; pass `nil` for a bare dot.
    var text: String?
    /// Optional SF Symbol override (e.g. a state-specific glyph). Defaults to the
    /// kind's canonical dot symbol.
    var symbol: String?
    /// Help text shown on hover; defaults to `text`.
    var help: String?

    var body: some View {
        Label {
            if let text {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol ?? kind.symbol).foregroundStyle(kind.color)
        }
        .labelStyle(.titleAndIcon)
        .help(help ?? text ?? "")
    }
}

// MARK: - Tunnel mapping

extension TunnelStatus {
    /// Collapse the rich tunnel state onto the shared status vocabulary.
    var kind: StatusKind {
        switch self {
        case .stopped: return .idle
        case .starting, .retrying: return .pending
        case .active: return .ok
        case .degraded: return .warn
        case .failed: return .error
        }
    }
}

/// Backwards-compatible adapter so existing call sites keep working while delegating to
/// the shared `StatusBadge`. Keeps the tunnel-specific uptime label and the state's own
/// SF Symbol.
struct TunnelStatusBadge: View {
    let status: TunnelStatus
    var showsLabel = true

    var body: some View {
        StatusBadge(
            kind: status.kind,
            text: showsLabel ? label : nil,
            symbol: status.symbol,
            help: status.label
        )
    }

    /// Shorter label for inline display; uptime for active tunnels.
    private var label: String {
        if case .active(let since) = status {
            return "Active · \(Self.uptime(since))"
        }
        return status.label
    }

    static func uptime(_ since: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(since))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}
