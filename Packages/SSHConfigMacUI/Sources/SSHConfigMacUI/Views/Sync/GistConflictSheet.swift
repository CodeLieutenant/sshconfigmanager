import SwiftUI

struct GistConflictSheet: View {
    let conflict: GistSyncStore.PendingConflict
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.xl) {
            IconTile(systemImage: "exclamationmark.triangle.fill", color: .orange, size: 52)
            VStack(spacing: Spacing.md) {
                Text("Sync Conflict").font(.title3.weight(.semibold))
                Text("Your config and the gist have both changed since the last sync. Choose which one to keep.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            VStack(spacing: Spacing.md) {
                Button {
                    conflict.resolve(.keepLocal)
                    dismiss()
                } label: {
                    Text("Keep Local — overwrite the gist with this Mac's config")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    conflict.resolve(.takeRemote)
                    dismiss()
                } label: {
                    Text("Take Remote — overwrite this Mac's config with the gist")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button("Cancel") {
                    conflict.resolve(.cancel)
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: 340)
        }
        .padding(Spacing.xxxxl)
        .frame(width: 420)
    }
}
