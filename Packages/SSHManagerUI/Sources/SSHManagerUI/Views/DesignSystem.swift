import Adwaita

/// The visual vocabulary every screen composes from.
///
/// The macOS build has one: a colour tile for identity, a page header, lifted
/// cards under uppercase labels, capsule pills for state, and chips for "add
/// this". Without the same set here, every Linux screen is a stack of
/// `PreferencesGroup` and they all read alike. The parts below are the GNOME
/// spelling of that vocabulary — Adwaita style classes and named colours first,
/// custom CSS only where libadwaita has no equivalent, so the user's theme,
/// accent and contrast still drive the result.
///
/// **Every part here is a function returning one `AnyView`, never a `View` or
/// `SimpleView` type.** A composite view type returns a `Body`, which is an
/// array, so its storage nests one level deeper than a plain widget. `List`
/// resolves its selection by matching a row's storage pointer against the
/// `GtkListBox` children, and that match fails for a nested row: the row stops
/// mapping back to its element, `gtk_stack_add_named` asserts, and selecting a
/// row silently does nothing. Sidebar navigation broke exactly this way. A
/// function keeps the storage shape identical to the hand-written widget it
/// replaced.

/// The one spacing scale. Use these rather than a literal, so the whole app
/// keeps one rhythm.
public enum Spacing {
    public static let xs = 2
    public static let sm = 4
    public static let md = 6
    public static let lg = 12
    public static let xl = 16
    public static let xxl = 20
    public static let xxxl = 24
}

/// The five — and only five — states colour may express outside the accent.
/// Every indicator in the app maps onto one, so "what running looks like" is
/// decided once.
public enum StatusKind {
    case idle
    case pending
    case ok
    case warn
    case error

    /// The pill's CSS class. Colour comes from the Adwaita named colours, so a
    /// high-contrast or dark theme recolours it for free.
    var pillClass: String {
        switch self {
        case .idle: "pill-idle"
        case .pending: "pill-pending"
        case .ok: "pill-ok"
        case .warn: "pill-warn"
        case .error: "pill-error"
        }
    }

    /// Shape as well as colour carries the state, so the indicator survives
    /// greyscale and colour blindness.
    var icon: Icon {
        switch self {
        case .idle: .default(icon: .mediaPlaybackStop)
        case .pending: .default(icon: .contentLoading)
        case .ok: .default(icon: .emblemOk)
        case .warn: .default(icon: .dialogWarning)
        case .error: .default(icon: .dialogError)
        }
    }
}

/// The page header every screen wears: a large identity tile, the title, a dim
/// subtitle, an optional row of pills, and the screen's actions.
///
/// GTK puts a title in the header bar, but that bar is shared chrome and its
/// title is small and centred — which is why every screen looked the same. This
/// sits inside the page, the way the macOS screen header does.
func screenHeader(
    icon: Icon,
    tile: String,
    title: String,
    subtitle: String = "",
    @ViewBuilder pills: @escaping () -> Body = { [] },
    @ViewBuilder actions: @escaping () -> Body = { [] }
) -> AnyView {
    VStack {
        HStack(spacing: Spacing.lg) {
            Symbol(icon: icon)
                .style("area-tile")
                .style("area-tile-lg")
                .style(tile)
                .valign(.center)
            VStack(spacing: Spacing.xs) {
                Text(title)
                    .ellipsize()
                    .title2()
                    .halign(.start)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .ellipsize()
                        .caption()
                        .dimLabel()
                        .halign(.start)
                }
                HStack(spacing: Spacing.sm) {
                    pills()
                }
                .halign(.start)
            }
            .valign(.center)
            .hexpand()
            HStack(spacing: Spacing.md) {
                actions()
            }
            .valign(.center)
        }
        .padding(Spacing.xl)
        Separator()
    }
    .style("screen-header")
}

/// The uppercase, dim label that titles a card. `PreferencesGroup` renders its
/// own title in the body weight, which does not separate a section from its
/// content the way the macOS card label does.
func sectionLabel(_ text: String) -> AnyView {
    Text(text.uppercased())
        .captionHeading()
        .dimLabel()
        .halign(.start)
        .style("section-label")
}

/// A capsule carrying a state: a dot and a word on a faint tint of the state's
/// colour.
func statusPill(kind: StatusKind, text: String) -> AnyView {
    HStack(spacing: Spacing.sm) {
        Symbol(icon: kind.icon)
            .style("pill-dot")
            .valign(.center)
        Text(text)
            .caption()
            .valign(.center)
    }
    .padding(Spacing.sm, .vertical)
    .padding(Spacing.md, .horizontal)
    .style("pill")
    .style(kind.pillClass)
    .valign(.center)
}

/// A neutral metadata capsule — a tag, a file name, a group. `icon` is optional,
/// and `accented` tints it with the user's accent colour for a group.
func tagPill(text: String, icon: Icon? = nil, accented: Bool = false) -> AnyView {
    HStack(spacing: Spacing.sm) {
        if let icon {
            Symbol(icon: icon)
                .style("pill-dot")
                .valign(.center)
        }
        Text(text)
            .caption()
            .valign(.center)
    }
    .padding(Spacing.sm, .vertical)
    .padding(Spacing.md, .horizontal)
    .style("pill")
    .style(accented ? "pill-accent" : "pill-neutral")
    .valign(.center)
}

/// The small count a sidebar destination carries.
func countBadge(count: Int) -> AnyView {
    Text("\(count)")
        .caption()
        .numeric()
        .style("count-badge")
        .valign(.center)
}

/// The compact "add this setting" affordance. `prominent` drops the fill and
/// tints the label, for the trailing "More…" entry.
func chip(title: String, prominent: Bool = false, action: @escaping () -> Void) -> AnyView {
    Button(title) {
        action()
    }
    .style("chip")
    .style(prominent ? "chip-prominent" : "chip-plain")
    .tooltip("Add \(title.markupEscaped)")
}

/// A lifted card with an uppercase label above it. The label/card pair is the
/// macOS `CardSection`; `PreferencesGroup` supplies the card itself, so the
/// rows keep libadwaita's own list behaviour.
func cardSection(
    _ title: String,
    describedBy: String = "",
    @ViewBuilder content: @escaping () -> Body
) -> AnyView {
    VStack(spacing: Spacing.md) {
        sectionLabel(title)
        PreferencesGroup("") {
            content()
        }
        .description(describedBy.markupEscaped)
    }
}

/// The app's own CSS. Everything that libadwaita already names — colours,
/// text styles, the boxed list — is left to libadwaita. What is here is the
/// handful of shapes it has no class for: the identity tile, the capsules, the
/// chips and the code surface. Every colour is an Adwaita named colour or an
/// alpha of the current foreground, so dark mode, the accent and the contrast
/// setting all keep working.
public enum AppStyle {
    public static let css = """
        .area-tile {
          border-radius: 8px;
          min-width: 28px;
          min-height: 28px;
          color: #ffffff;
        }
        .area-tile-lg {
          border-radius: 11px;
          min-width: 40px;
          min-height: 40px;
          -gtk-icon-size: 22px;
        }
        .tile-keys { background: #3584e4; }
        .tile-agent { background: #9141ac; }
        .tile-known-hosts { background: #2ec27e; }
        .tile-tunnels { background: #1a9ba1; }
        .tile-issues { background: #e5a50a; }
        .tile-history { background: #6c5ce7; }
        .tile-defaults { background: #77767b; }
        .tile-background { background: #c061cb; }
        .tile-host { background: alpha(currentColor, 0.12); color: inherit; }
        .tile-accent { background: @accent_bg_color; color: @accent_fg_color; }
        .tile-error { background: @error_bg_color; color: @error_fg_color; }

        .screen-header {
          background: alpha(@window_fg_color, 0.03);
        }
        .section-label {
          margin-left: 6px;
          margin-bottom: 2px;
        }

        .pill {
          border-radius: 999px;
        }
        .pill label { font-size: 0.85em; }
        .pill-dot { -gtk-icon-size: 12px; }
        .pill-neutral {
          background: alpha(currentColor, 0.10);
        }
        .pill-accent {
          background: alpha(@accent_color, 0.15);
          color: @accent_color;
        }
        .pill-ok {
          background: alpha(@success_color, 0.15);
          color: @success_color;
        }
        .pill-pending {
          background: alpha(@warning_color, 0.15);
          color: @warning_color;
        }
        .pill-warn {
          background: alpha(@warning_color, 0.18);
          color: @warning_color;
        }
        .pill-error {
          background: alpha(@error_color, 0.15);
          color: @error_color;
        }
        .pill-idle {
          background: alpha(currentColor, 0.08);
        }

        .count-badge {
          background: alpha(currentColor, 0.10);
          border-radius: 8px;
          padding: 1px 7px;
          font-size: 0.85em;
        }

        .chip {
          border-radius: 8px;
          padding: 4px 11px;
          min-height: 0;
          font-size: 0.9em;
        }
        .chip-plain {
          background: alpha(currentColor, 0.07);
          border: 1px solid alpha(currentColor, 0.08);
        }
        .chip-prominent {
          background: none;
          border: 1px solid transparent;
          color: @accent_color;
        }

        .upgrade-strip {
          border-radius: 0;
          padding: 8px 12px;
          color: @accent_color;
          font-size: 0.9em;
        }
        .tag-line {
          font-size: 0.8em;
        }

        /* An inline value: plain text until you focus it, so a column of
           settings reads as a property list rather than a stack of boxes. */
        .value-entry {
          background: none;
          border: none;
          box-shadow: none;
          outline: none;
          min-height: 0;
          padding: 2px 4px;
        }
        .value-entry:focus-within {
          background: alpha(currentColor, 0.06);
          border-radius: 6px;
        }
        .value-entry text {
          background: none;
        }

        .randomart, .code-surface {
          font-family: monospace;
          padding: 12px;
          border-radius: 8px;
          background: @view_bg_color;
        }
        """
}
