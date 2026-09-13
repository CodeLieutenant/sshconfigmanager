//
//  EffectiveConfigView.swift
//  sshconfigmanager
//
//  Shows the settings ssh will actually use for a host, with their origin.
//

import SSHConfigCore
import SwiftUI

struct EffectiveConfigView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: String

    private var settings: [ResolvedSetting] {
        EffectiveConfigResolver.resolve(target: target, in: store.configGraph)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Effective Configuration").font(.headline)
                    Text("ssh \(target)").font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if settings.isEmpty {
                ContentUnavailableView(
                    "No settings apply", systemImage: "questionmark",
                    description: Text("No Host or Match block matches “\(target)”."))
            } else {
                Table(settings) {
                    TableColumn("Keyword") { Text($0.keyword).font(.callout.monospaced()) }
                        .width(min: 150)
                    TableColumn("Value") { Text($0.value).textSelection(.enabled) }
                    TableColumn("From") { Text($0.source).foregroundStyle(.secondary) }
                        .width(min: 130)
                }
            }
        }
        .frame(width: 580, height: 440)
    }
}
