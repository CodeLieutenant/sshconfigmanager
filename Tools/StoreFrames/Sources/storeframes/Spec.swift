import CoreGraphics
import Foundation

// The JSON spec. Every visual decision lives in frames.json so a copy change or a
// re-crop is an edit plus a re-run, never a redraw by hand.

struct Spec: Decodable {
    var canvas: Canvas
    var themes: [String: Theme]
    var defaults: ShotDefaults
    var shots: [Shot]

    struct Canvas: Decodable {
        var width: Int
        var height: Int
    }

    struct ShotDefaults: Decodable {
        var theme: String
        var layout: Layout
        /// Fraction of the canvas width the window occupies.
        var windowScale: Double
        /// Fraction of the canvas height at which the window's top edge sits. Fixed
        /// rather than flowing from the text, so the window lines up across the whole
        /// gallery even when one shot's headline wraps to two lines and another's
        /// does not.
        var windowTop: Double
        /// Extra downward shift as a fraction of the window's own height, for a shot
        /// that wants more of itself cropped off the bottom.
        var windowBleed: Double
        var cornerRadius: Double
        var headlineSize: Double
        var subSize: Double
        /// The sub-caption's measure as a fraction of the headline's. A full-width
        /// line of 40pt text reads as a paragraph nobody will finish, so it is
        /// deliberately narrower than the headline above it.
        var subWidthFactor: Double
        var shadow: Shadow
    }

    struct Shadow: Decodable {
        var blur: Double
        var dy: Double
        var opacity: Double
    }
}

enum Layout: String, Decodable {
    /// Headline block at the top, window below and bleeding off the bottom.
    case headlineTop
    /// Window at the top, caption underneath (the Core Tunnel pattern).
    case captionBottom
    /// Text column on the left, window pushed off the right edge.
    case sideLeft
    /// Text column on the right, window pushed off the left edge.
    case sideRight
}

struct Theme: Decodable {
    /// Two or more stops, bottom-left to top-right.
    var gradient: [String]
    var gradientAngle: Double?
    var headlineColor: String
    var accentColor: String
    var subColor: String
    var grid: Grid?
    var blobs: [Blob]?
    /// Hairline drawn around the window so a dark app does not melt into a dark
    /// background.
    var windowBorder: String?
    var badgeFill: String?
    var badgeText: String?
    var calloutFill: String?
    var calloutText: String?

    struct Grid: Decodable {
        var spacing: Double
        var color: String
        var opacity: Double
        var lineWidth: Double?
    }

    struct Blob: Decodable {
        /// Centre in canvas fractions.
        var at: [Double]
        /// Radius as a fraction of canvas width.
        var radius: Double
        var color: String
        var opacity: Double
    }
}

struct Shot: Decodable {
    var source: String
    var output: String
    var headline: String
    var accent: String?
    /// Put the accent on the same wrapped paragraph instead of its own line.
    var accentInline: Bool?
    var sub: String?
    var theme: String?
    var layout: Layout?
    var windowScale: Double?
    var windowTop: Double?
    var windowBleed: Double?
    /// Crop applied to the source before framing. `null`/absent uses the whole
    /// image, "auto" detects the window, or an explicit [x, y, w, h] in source
    /// pixels with a TOP-LEFT origin (what Preview's inspector reports).
    var crop: Crop?
    /// Rect in POST-CROP source pixels to keep bright while the rest dims.
    var spotlight: [Double]?
    var callouts: [Callout]?
    /// Magnified detail cards. These are what put a NAME on a feature: each one
    /// enlarges a real region of the window and titles it, so a shopper reading the
    /// gallery at thumbnail size still learns what they are looking at.
    var insets: [Inset]?
    var badge: String?

    struct Inset: Decodable {
        /// The region to magnify, in post-crop source pixels, top-left origin.
        var from: [Double]
        /// Where the card sits, as a fraction of the canvas (its centre).
        var at: [Double]
        /// Magnification relative to how big that region renders in the window.
        var scale: Double?
        /// The feature name shown on the card's title bar.
        var label: String
        /// Optional second line, for the detail the name alone does not carry.
        var detail: String?
        /// Draw the leader line back to the region this card came from.
        var connect: Bool?
    }

    /// A name pinned to a part of the UI: a pill in the canvas margin, joined to the
    /// element by a leader line. Margin placement is the point — a pill dropped on top
    /// of the window hides the very thing it is naming.
    struct Callout: Decodable {
        /// The feature name. Keep it to two or three words.
        var text: String
        /// A second line for what the name alone does not carry. Optional.
        var detail: String?
        /// The real keyboard shortcut, e.g. "⌘K". Never invent one.
        var shortcut: String?
        /// The point being named, in fractions of the window's own size.
        var at: [Double]
        /// Which margin the pill sits in.
        var side: Side
        enum Side: String, Decodable { case left, right }
    }

    enum Crop: Decodable {
        case auto
        case rect(CGRect)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                guard s == "auto" else {
                    throw DecodingError.dataCorruptedError(
                        in: c, debugDescription: "crop must be \"auto\" or [x, y, w, h], got \"\(s)\"")
                }
                self = .auto
                return
            }
            let a = try c.decode([Double].self)
            guard a.count == 4 else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "crop rect needs exactly 4 numbers, got \(a.count)")
            }
            self = .rect(CGRect(x: a[0], y: a[1], width: a[2], height: a[3]))
        }
    }
}

// MARK: - Resolved values

/// A shot with every default folded in, so the renderer never reaches back into
/// the spec for a fallback.
struct ResolvedShot {
    var source: String
    var output: String
    var headline: String
    var accent: String?
    var accentInline: Bool
    var sub: String?
    var theme: Theme
    var themeName: String
    var layout: Layout
    var windowScale: Double
    var windowTop: Double
    var windowBleed: Double
    var cornerRadius: Double
    var headlineSize: Double
    var subSize: Double
    var subWidthFactor: Double
    var shadow: Spec.Shadow
    var crop: Shot.Crop?
    var spotlight: CGRect?
    var callouts: [Shot.Callout]
    var insets: [Shot.Inset]
    var badge: String?
}

extension Spec {
    func resolve() throws -> [ResolvedShot] {
        try shots.map { shot in
            let name = shot.theme ?? defaults.theme
            guard let theme = themes[name] else {
                throw Failure("shot \(shot.output): unknown theme \"\(name)\"")
            }
            var spotlight: CGRect?
            if let s = shot.spotlight {
                guard s.count == 4 else { throw Failure("shot \(shot.output): spotlight needs 4 numbers") }
                spotlight = CGRect(x: s[0], y: s[1], width: s[2], height: s[3])
            }
            return ResolvedShot(
                source: shot.source,
                output: shot.output,
                headline: shot.headline,
                accent: shot.accent,
                accentInline: shot.accentInline ?? false,
                sub: shot.sub,
                theme: theme,
                themeName: name,
                layout: shot.layout ?? defaults.layout,
                windowScale: shot.windowScale ?? defaults.windowScale,
                windowTop: shot.windowTop ?? defaults.windowTop,
                windowBleed: shot.windowBleed ?? defaults.windowBleed,
                cornerRadius: defaults.cornerRadius,
                headlineSize: defaults.headlineSize,
                subSize: defaults.subSize,
                subWidthFactor: defaults.subWidthFactor,
                shadow: defaults.shadow,
                crop: shot.crop,
                spotlight: spotlight,
                callouts: shot.callouts ?? [],
                insets: shot.insets ?? [],
                badge: shot.badge
            )
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
