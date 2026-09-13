import AppKit
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import SwiftUI

struct HostKeyHistorySheet: View {
    let groupName: String
    let records: [AppDatabase.HostKeyCheckRecord]
    var isLoading: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                ContentUnavailableView(
                    "No history",
                    systemImage: "clock",
                    description: Text("No check records found for this host.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                            historyRow(record)
                            if index < records.count - 1 {
                                Divider().padding(.leading, 50)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            Divider()
            HStack {
                Text("\(records.count) checks")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 520)
        .frame(minHeight: 320)
    }

    private var sheetHeader: some View {
        HStack(spacing: Spacing.md) {
            IconTile(systemImage: "clock.arrow.circlepath", color: TilePalette.knownHosts, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Check History")
                    .font(.headline)
                Text(groupName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private func historyRow(_ record: AppDatabase.HostKeyCheckRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: hostCheckOutcomeSymbol(record.outcome))
                .font(.system(size: 14))
                .foregroundStyle(hostCheckOutcomeColor(record.outcome))
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(hostCheckOutcomeName(record.outcome))
                        .font(.system(size: 12.5, weight: .medium))
                    if !record.keyType.isEmpty {
                        Text(record.keyType)
                            .font(.system(size: 11, weight: .medium).monospaced())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.1), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if !record.fingerprint.isEmpty {
                    Text(record.fingerprint)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Spacing.sm)
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.checkedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(record.checkedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}
