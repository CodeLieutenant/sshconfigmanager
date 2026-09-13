import Adwaita

/// L12 · Grant access. The first screen a new user sees, and the spike that
/// measures Adwaita-for-Swift against the design (linux-port.md §5).
///
/// The macOS build opens an NSOpenPanel and keeps a security-scoped bookmark.
/// Linux has neither, so this screen states what the app touches and confirms the
/// directory is usable — see SSHDirectory.
public struct GrantAccessView: View {
    @Binding var state: SSHDirectory.State
    var onContinue: () -> Void

    public init(state: Binding<SSHDirectory.State>, onContinue: @escaping () -> Void = {}) {
        self._state = state
        self.onContinue = onContinue
    }

    public var view: Body {
        screen
            .topToolbar {
                HeaderBar.empty()
                    .headerBarTitle {
                        WindowTitle(subtitle: "", title: "SSH Config Manager")
                    }
            }
    }

    @ViewBuilder private var screen: Body {
        switch state {
        case .ready(let path):
            StatusPage(
                "SSH configuration found",
                icon: .default(icon: .securityHigh),
                description: path
            ) {
                Button("Continue") { onContinue() }
                    .suggested()
                    .pill()
                    .halign(.center)
            }
        case .missing(let path):
            StatusPage(
                "No SSH configuration yet",
                icon: .default(icon: .folder),
                description: "There is no \(path.markupEscaped) directory. Create one to start."
            ) {
                Button("Create ~/.ssh") {
                    try? SSHDirectory.create(path: path)
                    state = SSHDirectory.inspect(path: path)
                }
                .suggested()
                .pill()
                .halign(.center)
            }
        case .unreadable(let path):
            StatusPage(
                "Access your SSH configuration",
                icon: .default(icon: .dialogPassword),
                description:
                    "SSH Config Manager edits the files in \(path). "
                    + "Give this user read and write access to that directory, then try again."
            ) {
                Button("Try again") { state = SSHDirectory.inspect(path: path) }
                    .suggested()
                    .pill()
                    .halign(.center)
            }
        }
    }
}
