import Adwaita
import SSHConfigCore

/// L09 · Tunnel editor. An `AdwDialog`, which is GNOME's answer to a macOS sheet.
struct TunnelEditorView: View {
    @Binding var draft: TunnelDraft
    var hosts: [String]
    var isNew: Bool
    var onCancel: () -> Void
    var onSave: () -> Void

    var view: Body {
        ScrollView {
            VStack(spacing: 18) {
                PreferencesGroup("Tunnel") {
                    EntryRow("Name", text: $draft.name)
                    ComboRow(
                        "Through host",
                        selection: .init {
                            draft.hostAlias
                        } set: {
                            draft.hostAlias = $0
                        },
                        values: hosts.isEmpty ? ["(no hosts)"] : hosts,
                        id: \.self,
                        description: \.self
                    )
                    ComboRow(
                        "Mode",
                        selection: .init {
                            draft.mode.label
                        } set: { label in
                            draft.mode =
                                TunnelDraft.Mode.allCases.first { $0.label == label } ?? .local
                        },
                        values: TunnelDraft.Mode.allCases.map(\.label),
                        id: \.self,
                        description: \.self
                    )
                }
                forwarding
                PreferencesGroup("Options") {
                    SwitchRow("Keep-alive (detect dropped connections)", isOn: $draft.keepAlive)
                    SwitchRow("Compression (-C)", isOn: $draft.compression)
                    SwitchRow("Fail if a port can't bind", isOn: $draft.failIfPortBusy)
                    SwitchRow("Start automatically on launch", isOn: $draft.startOnLaunch)
                }
                PreferencesGroup("Command") {
                    Text(draft.command)
                        .ellipsize()
                        .monospace()
                        .style("code-surface")
                        .halign(.start)
                }
            }
            .padding(18)
        }
        .topToolbar {
            HeaderBar {
                Button("Cancel") { onCancel() }
            } end: {
                Button(isNew ? "Add" : "Save") { onSave() }
                    .suggested()
            }
            .headerBarTitle {
                WindowTitle(subtitle: "", title: isNew ? "New Tunnel" : "Edit Tunnel")
            }
        }
    }

    private var forwarding: AnyView {
        PreferencesGroup("Forwarding") {
            ForEach(draft.mappings) { mapping in
                mappingRow(mapping)
            }
            ActionRow("Add Port Mapping")
                .prefix {
                    Symbol(icon: .default(icon: .listAdd))
                        .valign(.center)
                }
                .activated { draft.mappings.append(.init()) }
        }
        .description(
            draft.mode == .dynamic
                ? "A dynamic tunnel opens a SOCKS proxy on the local port."
                : ""
        )
    }

    private func mappingRow(_ mapping: TunnelDraft.PortMapping) -> AnyView {
        let index = draft.mappings.firstIndex { $0.id == mapping.id } ?? 0
        return HStack(spacing: 6) {
            Entry(
                "local port",
                text: .init {
                    draft.mappings[safe: index]?.localPort ?? ""
                } set: {
                    guard draft.mappings.indices.contains(index) else { return }
                    draft.mappings[index].localPort = $0
                }
            )
            if draft.mode != .dynamic {
                Text("→")
                    .dimLabel()
                    .valign(.center)
                Entry(
                    "host",
                    text: .init {
                        draft.mappings[safe: index]?.remoteHost ?? ""
                    } set: {
                        guard draft.mappings.indices.contains(index) else { return }
                        draft.mappings[index].remoteHost = $0
                    }
                )
                Text(":")
                    .dimLabel()
                    .valign(.center)
                Entry(
                    "port",
                    text: .init {
                        draft.mappings[safe: index]?.remotePort ?? ""
                    } set: {
                        guard draft.mappings.indices.contains(index) else { return }
                        draft.mappings[index].remotePort = $0
                    }
                )
            }
            Button(icon: .default(icon: .listRemove)) {
                guard draft.mappings.count > 1, draft.mappings.indices.contains(index) else {
                    return
                }
                draft.mappings.remove(at: index)
            }
            .flat()
            .tooltip("Remove this mapping")
            .valign(.center)
        }
        .padding(12)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
