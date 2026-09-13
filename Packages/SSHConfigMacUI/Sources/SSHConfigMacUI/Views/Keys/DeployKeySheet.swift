//
//  DeployKeySheet.swift
//  sshconfigmanager
//
//  The `ssh-copy-id` flow: pick a host, see the exact command that will append
//  this public key to its remote `authorized_keys`, then open it in the terminal
//  or copy it. We never run it silently — the user always sees the literal line
//  first, because deploying a key usually means a *first* password login and a
//  host-key prompt, both of which they handle in their own terminal.
//

import SSHConfigCore
import SwiftUI

struct DeployKeySheet: View {
    let keyName: String
    let publicKeyLine: String
    /// Whether the matching private half is on disk. Without it you can't later
    /// authenticate as this identity, so we warn — but still allow the deploy,
    /// since the public key alone is what lands in `authorized_keys`.
    let hasPrivateKey: Bool
    let hosts: [HostBlock]
    /// Open the deploy command in the user's terminal.
    let deploy: (HostBlock) -> Void
    /// Copy the deploy command to the clipboard.
    let copyCommand: (HostBlock) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: HostBlock.ID?

    private var filteredHosts: [HostBlock] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return hosts }
        return hosts.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.firstValue(for: "HostName")?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var selectedBlock: HostBlock? {
        hosts.first { $0.id == selectedID }
    }

    /// The literal command the user would run, or `nil` until a host with a
    /// concrete destination is selected.
    private var previewCommand: String? {
        selectedBlock.flatMap {
            SSHCommandBuilder.deployCommand(for: $0, publicKeyLine: publicKeyLine)?.shellString
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if hosts.isEmpty {
                ContentUnavailableView(
                    "No hosts to deploy to",
                    systemImage: "server.rack",
                    description: Text("Add a host in the config first, then deploy this key to it.")
                )
                .frame(maxHeight: .infinity)
            } else {
                hostList
                Divider()
                preview
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Deploy Public Key").font(.title3.weight(.semibold))
            Text("Append **\(keyName)** to a host's `~/.ssh/authorized_keys`.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !hasPrivateKey {
                Label(
                    "This key has no private half on disk — you won't be able to "
                        + "log in as this identity after deploying it.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var hostList: some View {
        VStack(spacing: 0) {
            TextField("Filter hosts", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List(filteredHosts, selection: $selectedID) { host in
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.title)
                    if let hostName = host.firstValue(for: "HostName") {
                        Text(hostName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(host.id)
            }
            .frame(minHeight: 160)
        }
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let previewCommand {
                Text(previewCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Select a host to preview the deploy command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Copy Command") {
                if let block = selectedBlock { copyCommand(block) }
            }
            .disabled(previewCommand == nil)
            Button("Open in Terminal") {
                if let block = selectedBlock {
                    deploy(block)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(previewCommand == nil)
        }
        .padding(16)
    }
}
