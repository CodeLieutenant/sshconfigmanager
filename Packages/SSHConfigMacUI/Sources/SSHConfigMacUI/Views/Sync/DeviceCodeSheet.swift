import AppKit
import SwiftUI

struct DeviceCodeSheet: View {
    @Environment(GistSyncStore.self) private var sync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.xl) {
            IconTile(systemImage: "arrow.triangle.2.circlepath", color: TilePalette.gistSync, size: 52)

            switch sync.connection {
            case .disconnected:
                Text("Connecting to GitHub…").font(.title3.weight(.semibold))
                ProgressView().controlSize(.small)
            case .connecting(let userCode, let uri):
                VStack(spacing: Spacing.md) {
                    Text("Connect GitHub").font(.title3.weight(.semibold))
                    Text("Enter this code to authorize SSH Config Manager at")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(Self.displayHost(uri))
                        .font(.subheadline.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(userCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .kerning(2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                    .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.md)
                    .frame(maxWidth: .infinity)
                    .background(Color.appContent, in: RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.cardBorder, lineWidth: 1)
                    )
                    .accessibilityLabel(Text("Device code \(Self.spelledOut(userCode))"))
                HStack(spacing: Spacing.md) {
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(userCode, forType: .string)
                    }
                    Button("Open GitHub") {
                        if let url = URL(string: uri) { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                ProgressView().controlSize(.small)
                Text("Waiting for authorization…").font(.caption).foregroundStyle(.secondary)
            case .connected:
                Text("Connected").font(.title3.weight(.semibold))
                Image(systemName: "checkmark.circle.fill").font(.system(size: 32)).foregroundStyle(.green)
            }

            if let lastError = sync.lastError, case .disconnected = sync.connection {
                Text(lastError).font(.caption).foregroundStyle(.red)
            }

            Button("Cancel") { dismiss() }
                .buttonStyle(.borderless)
        }
        .padding(Spacing.xxxxl)
        .frame(width: 380)
        .task {
            await sync.connect()
            if case .connected = sync.connection { dismiss() }
        }
        .onChange(of: sync.connection) { _, newValue in
            if case .connected = newValue { dismiss() }
        }
    }

    static func displayHost(_ uri: String) -> String {
        guard let components = URLComponents(string: uri), let host = components.host else { return uri }
        return host + components.path
    }

    static func spelledOut(_ userCode: String) -> String {
        userCode.map { $0 == "-" ? "dash" : String($0) }.joined(separator: " ")
    }
}
