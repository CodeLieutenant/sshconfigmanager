import Adwaita
import SSHConfigCore

/// The `Host *` block, which supplies a default for anything a specific host did
/// not set. It gets its own sidebar entry because it applies everywhere.
struct GlobalDefaultsView: View {
    @Binding var store: ConfigStore
    @Binding var metadata: HostMetadata
    var onStatus: (String) -> Void

    private var wildcard: HostBlock? {
        store.blocks.first { $0.kind == .host && $0.isWildcard }
    }

    var view: Body {
        page
    }

    /// One view, not a `Body`: a `@ViewBuilder` branch here produces a wrapper
    /// whose storage carries no fields, and GTK then refuses the page.
    ///
    /// `HostDetailView` brings its own header bar and page header, so this view
    /// must not add a second one around it — two stacked header bars is what
    /// that produced.
    private var page: any AnyView {
        if let block = wildcard {
            HostDetailView(
                store: $store, metadata: $metadata, alias: block.sidebarKey, onStatus: onStatus)
        } else {
            empty
                .topToolbar {
                    HeaderBar.empty()
                        .headerBarTitle {
                            WindowTitle(subtitle: "", title: "Global Defaults")
                        }
                }
        }
    }

    private var empty: AnyView {
        StatusPage(
            "No Global Defaults Yet",
            icon: .default(icon: .emblemSystem),
            description:
                "A Host * block applies settings to every host that does not set them itself. "
                + "It is useful for things like User or IdentityFile you would otherwise repeat."
        ) {
            Button("Add Global Defaults") { add() }
                .suggested()
                .pill()
                .halign(.center)
        }
    }

    /// `Host *` only supplies what no later block set, so it belongs at the end of
    /// the file. Adding it anywhere else would silently shadow later hosts.
    private func add() {
        guard var document = store.document else { return }
        document.appendBlocks([
            HostBlock(
                kind: .host,
                header: .init(keyword: "Host", value: "*", isDirty: true),
                sourceURL: document.sourceURL
            )
        ])
        do {
            try store.save(document)
            onStatus("Added a Host * block")
        } catch {
            onStatus("Could not add: \(error.localizedDescription)")
        }
    }
}
