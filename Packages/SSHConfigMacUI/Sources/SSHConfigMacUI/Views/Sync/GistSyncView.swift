import SwiftUI

struct GistSyncView: View {
    @Environment(GistSyncStore.self) private var sync
    @State private var settings = AppSettings.shared
    @State private var showDeviceCodeSheet = false
    @State private var isSyncing = false

    @ViewBuilder
    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                tile: (icon: "arrow.triangle.2.circlepath", color: TilePalette.gistSync),
                title: "Sync", subtitle: subtitle
            ) {
                if case .connected = sync.connection {
                    ChromeButton(
                        title: isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath",
                        kind: .prominent
                    ) {
                        Task {
                            isSyncing = true
                            await sync.autoSyncIfNeeded()
                            isSyncing = false
                        }
                    }
                    .disabled(isSyncing)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    statusSection
                    if case .connected = sync.connection {
                        optionsSection
                        actionsSection
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(WindowWash())
        .sheet(isPresented: $showDeviceCodeSheet) { DeviceCodeSheet() }
        .sheet(
            isPresented: Binding(get: { sync.conflict != nil }, set: { if !$0 { sync.conflict?.resolve(.cancel) } })
        ) {
            if let conflict = sync.conflict { GistConflictSheet(conflict: conflict) }
        }
    }

    private var subtitle: String? {
        switch sync.connection {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected(let login): return "Connected as \(login)"
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        CardSection("Status") {
            switch sync.connection {
            case .disconnected:
                CardRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not connected").font(.system(size: 13, weight: .medium))
                        Text("Sign in with GitHub to start syncing your config.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect GitHub") { showDeviceCodeSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            case .connecting:
                CardRow {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to authorize on GitHub…").font(.system(size: 13))
                    Spacer()
                }
            case .connected(let login):
                CardRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connected as \(login)").font(.system(size: 13, weight: .medium))
                        Text(syncStatusLine).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let lastError = sync.lastError {
                    CardRow {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var syncStatusLine: String {
        if sync.pendingPush { return "Pending — will sync when online" }
        if let lastSyncedAt = sync.lastSyncedAt {
            let when = lastSyncedAt.formatted(.relative(presentation: .named))
            if sync.recreatedAfterRemoteDeletion {
                return "Last synced \(when) — the old gist was gone, so a new one holds your config"
            }
            return "Last synced \(when)"
        }
        return "Never synced"
    }

    private var optionsSection: some View {
        @Bindable var settings = settings
        return CardSection("Options") {
            CardRow {
                Toggle("Sync automatically", isOn: $settings.gistSyncEnabled)
            }
            CardRow {
                Toggle("Encrypt before uploading", isOn: $settings.gistEncryptionEnabled)
            }
        }
    }

    private var actionsSection: some View {
        CardSection("Actions") {
            CardRow {
                Button("Push") { Task { await sync.pushNow() } }
                Spacer()
                Button("Pull") { Task { await sync.pullNow() } }
            }
            CardRow {
                Button("Disconnect", role: .destructive) { sync.disconnect() }
            }
        }
    }
}
