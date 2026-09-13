//
//  TunnelActivityView.swift
//  sshconfigmanager
//
//  The per-tunnel console: a live, scrolling log of status transitions and
//  engine lifecycle lines (connecting, host-key, listening, drops…). The
//  reusable `TunnelConsoleView` is embedded in the Tunnels management screen;
//  `TunnelActivityView` wraps it as a sheet for the per-host "Activity…" action.
//

import SSHConfigCore
import SwiftUI

/// A live, auto-scrolling log for one tunnel. Oldest line on top, newest at the
/// bottom (console order), with a level icon and timestamp per line.
struct TunnelConsoleView: View {
    @Environment(TunnelStore.self) private var tunnels
    @State private var settings = AppSettings.shared
    let preset: TunnelPreset

    private var entries: [TunnelLogEntry] { tunnels.logEntries(for: preset.id) }
    private let bottomID = "tunnel-console-bottom"

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No activity yet", systemImage: "text.alignleft",
                    description: Text("Start the tunnel to see its connection log."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(entries) { entry in
                                row(entry).id(entry.id)
                            }
                            Color.clear.frame(height: 1).id(bottomID)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                    }
                    .onChange(of: entries.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ entry: TunnelLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Image(systemName: entry.level.symbol)
                .font(.caption2)
                .foregroundStyle(entry.level.tint)
                .frame(width: 12)
            Text(entry.message)
                .font(settings.editorFont)
                .foregroundStyle(entry.level == .error ? Color.red : Color.primary)
            Spacer(minLength: 0)
        }
    }
}

/// Sheet wrapper around `TunnelConsoleView` for the per-host "Activity…" action.
struct TunnelActivityView: View {
    @Environment(TunnelStore.self) private var tunnels
    @Environment(\.dismiss) private var dismiss
    let preset: TunnelPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console — \(preset.displayName)").font(.headline)
                Spacer()
                if let bytes = tunnels.throughput[preset.id] {
                    Text(bytes.summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            TunnelConsoleView(preset: preset)
        }
        .frame(width: 540, height: 380)
    }
}

extension TunnelLogLevel {
    fileprivate var symbol: String {
        switch self {
        case .status: return "circle.fill"
        case .info: return "arrow.forward.circle"
        case .detail: return "smallcircle.filled.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .status: return .accentColor
        case .info: return Color(nsColor: .secondaryLabelColor)
        case .detail: return Color(nsColor: .tertiaryLabelColor)
        case .error: return .red
        }
    }
}
