import Adwaita
import SSHManagerUI

/// The app id matches packaging/flatpak/app.sshmanager.SSHConfigManager.yml. Flathub
/// verifies the domain in the id, so it is sshmanager.app and not the macOS
/// bundle prefix.
@main
struct SSHManagerApp: App {
    var app = AdwaitaApp(id: "app.sshmanager.SSHConfigManager")

    var scene: Scene {
        Window(id: "main") { _ in
            RootView()
        }
        .defaultSize(width: 1180, height: 760)
        .title("SSH Config Manager")
    }

}
