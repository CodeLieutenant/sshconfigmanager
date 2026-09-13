import Adwaita
import SSHConfigCore

/// Paste one or more Host blocks. macOS reads the clipboard directly; GTK's
/// clipboard read is asynchronous, so the text lands in a field the user can
/// check before anything is written.
struct ImportHostsView: View {
    var onImport: (String) -> Void
    var onCancel: () -> Void

    @State private var text = ""

    var view: Body {
        VStack(spacing: 12) {
            Text("Paste Host blocks. They are appended to your main configuration file.")
                .dimLabel()
                .halign(.start)
            ScrollView {
                TextEditor(text: $text)
                    .monospace()
                    .vexpand()
            }
            .vexpand()
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                Button("Import") { onImport(text) }
                    .suggested()
            }
            .halign(.center)
        }
        .padding(18)
    }
}

/// `HostTemplate` is not `Identifiable` in the core, and ForEach needs that.
struct HostTemplateBox: Identifiable {
    let id: String
    let template: HostTemplate

    static let all: [HostTemplateBox] = HostTemplate.all.map {
        .init(id: $0.name, template: $0)
    }
}
