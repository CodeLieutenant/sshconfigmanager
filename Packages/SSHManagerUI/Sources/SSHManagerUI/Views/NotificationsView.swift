import Adwaita
import Foundation

/// L11 · Notifications & background — the Linux replacement for the two macOS
/// menu-bar extras.
///
/// GNOME has no persistent menu-bar or supported tray, so the native answer is a
/// background application that reports through desktop notifications. This screen
/// is where that state is visible: what is running, what was reported, and the
/// switches that control both. See docs/design/linux-libadwaita.md §6.
struct NotificationsView: View {
    @Binding var settings: AppSettings
    var onStatus: (String) -> Void

    @State private var tunnels: [TunnelDraft] = TunnelStore.load()

    private var running: [TunnelDraft] {
        tunnels.filter { $0.status == .running }
    }

    var view: Body {
        content
            .topToolbar {
                HeaderBar.empty()
                    .headerBarTitle {
                        WindowTitle(subtitle: subtitle, title: "Notifications & Background")
                    }
            }
    }

    private var subtitle: String {
        settings.runInBackground ? "Running in the background" : "Foreground only"
    }

    @ViewBuilder private var headerPills: Body {
        statusPill(
            kind: settings.runInBackground ? .ok : .idle,
            text: settings.runInBackground ? "Background" : "Foreground only"
        )
        if !running.isEmpty {
            statusPill(kind: .ok, text: "\(running.count) running")
        }
        if settings.launchAtLogin {
            tagPill(text: "Starts at login", icon: .default(icon: .contentLoading))
        }
    }

    private var content: AnyView {
        VStack {
            screenHeader(
                icon: .default(icon: .preferencesSystemNotifications),
                tile: "tile-background",
                title: "Notifications & Background",
                subtitle: subtitle,
                pills: { headerPills }
            )
            page
                .vexpand()
        }
    }

    private var page: AnyView {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                cardSection("Background") {
                    SwitchRow(
                        "Keep running in the background",
                        isOn: setting(\.runInBackground)
                    )
                    .subtitle(
                        "The window can close while tunnels stay up. GNOME shows a background "
                            + "application entry in the system menu."
                    )
                    .subtitleLines(0)
                    SwitchRow("Start at login", isOn: setting(\.launchAtLogin))
                        .subtitle("Adds an entry under ~/.config/autostart.")
                        .subtitleLines(0)
                }
                cardSection(
                    "Notifications",
                    describedBy:
                        "Notifications go to the desktop through the standard portal, so GNOME's own "
                        + "Do Not Disturb and per-application settings apply."
                ) {
                    SwitchRow(
                        "Notify when a tunnel fails or recovers",
                        isOn: setting(\.showTunnelNotifications)
                    )
                    SwitchRow(
                        "Notify me when a host key changes",
                        isOn: setting(\.notifyOnHostKeyChange)
                    )
                    SwitchRow(
                        "Notify me about external changes",
                        isOn: setting(\.notifyOnExternalChange)
                    )
                    ActionRow("Send a test notification")
                        .subtitle("Check that your desktop shows them.")
                        .activated { onStatus("Desktop notifications are not wired up yet") }
                }
                cardSection("Running Now") {
                    if running.isEmpty {
                        ActionRow("Nothing is running")
                            .subtitle("Start a tunnel to see it here.")
                    } else {
                        ForEach(running) { tunnel in
                            ActionRow(tunnel.name.isEmpty ? "Untitled tunnel" : tunnel.name)
                                .useMarkup(false)
                                .subtitle("through \(tunnel.hostAlias) · \(tunnel.summary)")
                                .prefix {
                                    Symbol(icon: .default(icon: .emblemOk))
                                        .style("success")
                                        .valign(.center)
                                }
                                .suffix {
                                    Button("Stop") {
                                        onStatus("The in-app engine is not available yet")
                                    }
                                    .valign(.center)
                                }
                        }
                    }
                }
                cardSection("Recent Reports") {
                    ActionRow("Nothing reported")
                        .subtitle("Failures and recoveries appear here as they happen.")
                }
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: 820)
        }
    }

    private func setting<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        .init {
            settings[keyPath: path]
        } set: { newValue in
            settings[keyPath: path] = newValue
            settings.save()
        }
    }
}
