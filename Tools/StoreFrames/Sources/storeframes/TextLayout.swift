import AppKit
import CoreGraphics
import CoreText
import Foundation

// Type is set with CoreText so the frames use the same San Francisco the app
// itself renders in — no bundled font files, no fallback to Helvetica.

enum TextAlign {
    case left, center

    var ctAlignment: CTTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        }
    }
}

struct TextRun {
    var text: String
    var color: CGColor
    var weight: NSFont.Weight
    var size: CGFloat
    /// Letter spacing as a fraction of the size. Large display type needs it
    /// negative or it reads loose.
    var tracking: CGFloat = -0.02
}

/// A wrapped, possibly multi-coloured paragraph that knows its own height.
struct Paragraph {
    private let attributed: NSAttributedString
    let align: TextAlign
    let lineHeightMultiple: CGFloat

    init(runs: [TextRun], align: TextAlign, lineHeightMultiple: CGFloat = 1.08) {
        self.align = align
        self.lineHeightMultiple = lineHeightMultiple
        let style = NSMutableParagraphStyle()
        style.alignment = align == .left ? .left : .center
        style.lineHeightMultiple = lineHeightMultiple
        style.lineBreakMode = .byWordWrapping

        let out = NSMutableAttributedString()
        for run in runs {
            out.append(
                NSAttributedString(
                    string: run.text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: run.size, weight: run.weight),
                        .foregroundColor: NSColor(cgColor: run.color) ?? .white,
                        .kern: run.size * run.tracking,
                        .paragraphStyle: style,
                    ]))
        }
        attributed = out
    }

    func height(fittingWidth width: CGFloat) -> CGFloat {
        size(fittingWidth: width).height
    }

    /// The space the wrapped text actually occupies — the width matters when the
    /// paragraph sits inside a card that has to shrink-wrap around it.
    func size(fittingWidth width: CGFloat) -> CGSize {
        guard attributed.length > 0 else { return .zero }
        let fs = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Draws inside `rect`, laying out downward from its top edge. `rect` is in
    /// native bottom-left canvas coordinates.
    func draw(in ctx: CGContext, rect: CGRect) {
        guard attributed.length > 0 else { return }
        let fs = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

/// A single line drawn at an exact point — used for pills and badges, where
/// wrapping would be wrong.
struct Label {
    let line: CTLine
    let size: CGSize
    let ascent: CGFloat

    init(
        _ text: String, size fontSize: CGFloat, weight: NSFont.Weight, monospaced: Bool = false,
        color: CGColor, tracking: CGFloat = 0
    ) {
        let font =
            monospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
            : NSFont.systemFont(ofSize: fontSize, weight: weight)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(cgColor: color) ?? .white,
                .kern: fontSize * tracking,
            ])
        line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var a: CGFloat = 0
        var d: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &a, &d, nil)
        size = CGSize(width: ceil(w), height: ceil(a + d))
        ascent = a
    }

    /// `origin` is the bottom-left of the text box (not the baseline).
    func draw(in ctx: CGContext, at origin: CGPoint) {
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: origin.x, y: origin.y + (size.height - ascent))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
