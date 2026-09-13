//
//  TunnelEditorView.swift
//  sshconfigmanager
//
//  Sheet for creating or editing a tunnel preset. Opened either for a specific
//  host (the host is fixed) or from the Tunnels management screen (the host is
//  chosen from a picker). Port fields are labelled per mode so local vs. remote
//  is unambiguous.
//

import SSHConfigCore
import SwiftUI

struct TunnelEditorView: View {
    @Environment(TunnelStore.self) private var tunnels
    @Environment(ConfigStore.self) private var config
    @Environment(\.dismiss) private var dismiss

    /// The preset being edited, or nil to create a new one.
    let existing: TunnelPreset?
    /// When true the host is fixed (opened from a host); otherwise it's pickable.
    private let lockedHost: Bool
    /// Fired after a genuine create (not an edit) commits, just before the sheet
    /// dismisses — lets the presenting screen show a confirmation toast.
    private let onAdded: (() -> Void)?
    /// Fired after an edit to an existing preset commits (mirrors `onAdded`).
    private let onUpdated: (() -> Void)?

    @State private var draft: TunnelPreset

    /// Editor bound to a specific host (host shown read-only).
    init(
        hostAlias: String, existing: TunnelPreset?,
        onAdded: (() -> Void)? = nil, onUpdated: (() -> Void)? = nil
    ) {
        self.existing = existing
        self.lockedHost = true
        self.onAdded = onAdded
        self.onUpdated = onUpdated
        _draft = State(initialValue: existing ?? TunnelPreset(hostAlias: hostAlias))
    }

    /// Editor opened from the management screen — the host is chosen from a picker.
    init(existing: TunnelPreset?, onAdded: (() -> Void)? = nil, onUpdated: (() -> Void)? = nil) {
        self.existing = existing
        self.lockedHost = existing != nil // editing keeps its host; creating picks one
        self.onAdded = onAdded
        self.onUpdated = onUpdated
        _draft = State(initialValue: existing ?? TunnelPreset(hostAlias: ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Tunnel") {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Postgres via bastion"))
                    if lockedHost {
                        LabeledContent("Through host") {
                            Text(draft.hostAlias).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Through host", selection: $draft.hostAlias) {
                            Text("Choose a host…").tag("")
                            ForEach(hostAliases, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Picker("Mode", selection: $draft.mode) {
                        ForEach(TunnelMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                Section {
                    ForEach($draft.mappings) { $mapping in
                        mappingRow($mapping)
                    }
                    Button {
                        draft.mappings.append(PortMapping())
                    } label: {
                        Label("Add Port Mapping", systemImage: "plus")
                    }
                } header: {
                    Text("Forwarding")
                } footer: {
                    Text(forwardingHelp).font(.caption)
                }

                Section("Options") {
                    Toggle("Start automatically on launch", isOn: $draft.autostart)
                    // Only -L has both a fixed target and a listen port reachable on
                    // this Mac, so only it can offer a working "Open Browser" shortcut.
                    if draft.mode == .local {
                        ForEach($draft.mappings) { $mapping in
                            Toggle(webUILabel(for: mapping), isOn: $mapping.hasWebUI)
                                .help("Adds an Open Browser button while this tunnel is running")
                        }
                    }
                }

                Section("Command") {
                    Text(TunnelCommandBuilder.commandString(for: draft))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(existing == nil ? "Add Tunnel" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
            .padding(12)
        }
        .frame(width: 540, height: 580)
    }

    // MARK: - Mapping row (mode-aware labels)

    @ViewBuilder
    private func mappingRow(_ mapping: Binding<PortMapping>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                labeledPort(listenPortLabel, mapping.listenPort)
                if draft.mode.hasTarget {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 6)
                    labeledField(targetHostLabel, prompt: "host", mapping.targetHost)
                    labeledPort("Port", mapping.targetPort)
                }
                if draft.mappings.count > 1 {
                    Button(role: .destructive) {
                        draft.mappings.removeAll { $0.id == mapping.wrappedValue.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .padding(.bottom, 6)
                }
            }
            Text(preview(for: mapping.wrappedValue))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func labeledPort(_ label: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
        }
    }

    private func labeledField(_ label: String, prompt: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(prompt, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 150)
        }
    }

    /// Label for the listen-port box. For `-R` the listener is on the *remote*
    /// host, not this Mac — so the label has to flip with the mode.
    private var listenPortLabel: String {
        switch draft.mode {
        case .local: return "Local port (this Mac)"
        case .remote: return "Remote port (on server)"
        case .dynamic: return "Local SOCKS port"
        }
    }

    /// For `-L` the target is reached from the server; for `-R` it's on this Mac.
    private var targetHostLabel: String {
        switch draft.mode {
        case .local: return "Forward to host (from server)"
        case .remote: return "Forward to host (this Mac)"
        case .dynamic: return ""
        }
    }

    private func preview(for mapping: PortMapping) -> String {
        "\(draft.mode.flag) \(mapping.forwardSpec(for: draft.mode))"
    }

    /// Distinguishes mappings by port once a preset has more than one.
    private func webUILabel(for mapping: PortMapping) -> String {
        draft.mappings.count > 1 ? "Has a web UI (port \(mapping.listenPort))" : "Has a web UI"
    }

    private var forwardingHelp: String {
        switch draft.mode {
        case .local:
            return
                "Listen on a port on this Mac and forward each connection to a host:port reachable from the server. e.g. localhost:5432 → the server's localhost:5432."
        case .remote:
            return
                "Ask the server to listen on a port and forward each connection back to a host:port on this Mac. e.g. the server's :8080 → this Mac's localhost:3000."
        case .dynamic:
            return
                "Open a SOCKS proxy on a local port; each app chooses its own destination through it. The target host/port aren't used."
        }
    }

    /// Non-wildcard host aliases to choose from when the host isn't fixed.
    private var hostAliases: [String] {
        config.allHostBlocks
            .filter { $0.kind == .host && !$0.isWildcard }
            .compactMap { $0.patterns.first }
            .filter { !$0.isEmpty }
    }

    private func commit() {
        if existing == nil {
            tunnels.add(draft)
            onAdded?()
        } else {
            tunnels.update(draft)
            onUpdated?()
        }
        dismiss()
    }
}
