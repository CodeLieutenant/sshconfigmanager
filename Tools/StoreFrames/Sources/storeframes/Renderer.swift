import AppKit
import CoreGraphics
import Foundation

struct Renderer {
    let canvas: CGSize

    // Layout constants. They are tuned for a 2880x1800 canvas and scale with it,
    // so rendering at 1440x900 gives the same composition.
    private var unit: CGFloat { canvas.width / 2880 }
    private var sideMargin: CGFloat { 160 * unit }
    private var textInsetCentered: CGFloat { 300 * unit }

    init(width: Int, height: Int) {
        canvas = CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// Converts a top-left-origin rect into the native bottom-left canvas space.
    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: canvas.height - r.minY - r.height, width: r.width, height: r.height)
    }

    func render(_ shot: ResolvedShot, window source: CGImage) throws -> CGImage {
        let ctx = try makeCanvas(width: Int(canvas.width), height: Int(canvas.height))
        try drawBackground(ctx, theme: shot.theme)

        let aspect = CGFloat(source.width) / CGFloat(source.height)
        let text = try makeText(shot)

        switch shot.layout {
        case .headlineTop:
            let w = canvas.width * shot.windowScale
            let h = w / aspect
            let windowTop = canvas.height * shot.windowTop + shot.windowBleed * h
            try drawWindow(
                ctx, source, shot: shot,
                frame: CGRect(x: (canvas.width - w) / 2, y: windowTop, width: w, height: h))
            // Centre the text in the band above the window rather than flowing the
            // window down from it, so every frame in the gallery lines up.
            let blockWidth = canvas.width - textInsetCentered * 2
            let band = canvas.height * shot.windowTop - 100 * unit
            let height = textHeight(text, shot: shot, width: blockWidth)
            _ = try drawTextBlock(
                ctx, text, shot: shot, align: .center,
                topLeft: CGPoint(x: textInsetCentered, y: max(72 * unit, (band - height) / 2)),
                width: blockWidth)

        case .captionBottom:
            let blockWidth = canvas.width - textInsetCentered * 2
            let height = textHeight(text, shot: shot, width: blockWidth)
            let blockTop = canvas.height - 128 * unit - height
            let w = canvas.width * shot.windowScale
            let h = w / aspect
            let y = blockTop - 104 * unit - h - shot.windowBleed * h
            try drawWindow(
                ctx, source, shot: shot,
                frame: CGRect(x: (canvas.width - w) / 2, y: y, width: w, height: h))
            _ = try drawTextBlock(
                ctx, text, shot: shot, align: .center,
                topLeft: CGPoint(x: textInsetCentered, y: blockTop), width: blockWidth)

        case .sideLeft, .sideRight:
            let columnWidth = canvas.width * 0.40
            let height = textHeight(text, shot: shot, width: columnWidth)
            let blockTop = (canvas.height - height) / 2
            let w = canvas.width * shot.windowScale
            let h = w / aspect
            let y = (canvas.height - h) / 2
            let textX: CGFloat
            let windowX: CGFloat
            if shot.layout == .sideLeft {
                textX = sideMargin
                windowX = sideMargin + columnWidth + 120 * unit
            } else {
                textX = canvas.width - sideMargin - columnWidth
                windowX = textX - 120 * unit - w
            }
            try drawWindow(
                ctx, source, shot: shot, frame: CGRect(x: windowX, y: y, width: w, height: h))
            _ = try drawTextBlock(
                ctx, text, shot: shot, align: .left,
                topLeft: CGPoint(x: textX, y: blockTop), width: columnWidth)
        }

        guard let image = ctx.makeImage() else { throw Failure("could not snapshot the canvas") }
        return image
    }

    // MARK: - Background

    private func drawBackground(_ ctx: CGContext, theme: Theme) throws {
        let colors = try theme.gradient.map { try CGColor.hex($0) }
        guard colors.count >= 2 else { throw Failure("a theme gradient needs at least two stops") }
        let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
        guard let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)
        else { throw Failure("could not build the background gradient") }

        let angle = (theme.gradientAngle ?? 115) * .pi / 180
        let radius = max(canvas.width, canvas.height)
        let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let start = CGPoint(x: mid.x - cos(angle) * radius / 2, y: mid.y - sin(angle) * radius / 2)
        let end = CGPoint(x: mid.x + cos(angle) * radius / 2, y: mid.y + sin(angle) * radius / 2)
        ctx.drawLinearGradient(
            gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        for blob in theme.blobs ?? [] {
            guard blob.at.count == 2 else { throw Failure("a blob's \"at\" needs two numbers") }
            let center = CGPoint(x: blob.at[0] * canvas.width, y: (1 - blob.at[1]) * canvas.height)
            let r = blob.radius * canvas.width
            let inner = try CGColor.hex(blob.color, alpha: blob.opacity)
            let outer = try CGColor.hex(blob.color, alpha: 0)
            guard let g = CGGradient(colorsSpace: sRGB, colors: [inner, outer] as CFArray, locations: [0, 1])
            else { throw Failure("could not build a blob gradient") }
            ctx.drawRadialGradient(
                g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
        }

        if let grid = theme.grid {
            ctx.saveGState()
            ctx.setStrokeColor(try CGColor.hex(grid.color, alpha: grid.opacity))
            ctx.setLineWidth((grid.lineWidth ?? 2) * unit)
            let step = grid.spacing * unit
            var x = step
            while x < canvas.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: canvas.height))
                x += step
            }
            var y = step
            while y < canvas.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: canvas.width, y: y))
                y += step
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - Text

    private struct TextBlock {
        var badge: (text: String, fill: CGColor, color: CGColor)?
        var headline: [TextRun]
        var sub: (text: String, color: CGColor)?
        var headlineSize: CGFloat
        var subSize: CGFloat
        var subWidthFactor: CGFloat
    }

    private func makeText(_ shot: ResolvedShot) throws -> TextBlock {
        let head = try CGColor.hex(shot.theme.headlineColor)
        let accent = try CGColor.hex(shot.theme.accentColor)
        let size = shot.headlineSize * unit

        var runs: [TextRun] = [
            TextRun(text: shot.headline, color: head, weight: .bold, size: size)
        ]
        if let a = shot.accent, !a.isEmpty {
            runs.append(TextRun(text: shot.accentInline ? " " : "\n", color: head, weight: .bold, size: size))
            runs.append(TextRun(text: a, color: accent, weight: .bold, size: size))
        }

        let subColor = try CGColor.hex(shot.theme.subColor)
        var badge: (String, CGColor, CGColor)?
        if let b = shot.badge {
            badge = (
                b,
                try CGColor.hex(shot.theme.badgeFill ?? shot.theme.accentColor, alpha: 0.16),
                try CGColor.hex(shot.theme.badgeText ?? shot.theme.accentColor)
            )
        }

        return TextBlock(
            badge: badge,
            headline: runs,
            sub: shot.sub.map { ($0, subColor) },
            headlineSize: size,
            subSize: shot.subSize * unit,
            // A side column is already a narrow measure; narrowing it again leaves a
            // ragged four-word ribbon.
            subWidthFactor: shot.layout == .headlineTop || shot.layout == .captionBottom
                ? shot.subWidthFactor : 1)
    }

    private var badgeHeight: CGFloat { 62 * unit }
    private var badgeGap: CGFloat { 34 * unit }
    private var subGap: CGFloat { 36 * unit }

    private func textHeight(_ text: TextBlock, shot: ResolvedShot, width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        if text.badge != nil { h += badgeHeight + badgeGap }
        h += Paragraph(runs: text.headline, align: .center).height(fittingWidth: width)
        if let sub = text.sub {
            h += subGap
            h += Paragraph(
                runs: [TextRun(text: sub.text, color: sub.color, weight: .regular, size: text.subSize, tracking: 0)],
                align: .center, lineHeightMultiple: 1.28
            ).height(fittingWidth: width * text.subWidthFactor)
        }
        return h
    }

    /// Draws the badge + headline + sub starting at `topLeft`. Returns the y of the
    /// block's bottom edge, in top-left coordinates.
    @discardableResult
    private func drawTextBlock(
        _ ctx: CGContext, _ text: TextBlock, shot: ResolvedShot, align: TextAlign,
        topLeft: CGPoint, width: CGFloat
    ) throws -> CGFloat {
        var y = topLeft.y

        if let badge = text.badge {
            let label = Label(
                badge.text.uppercased(), size: 30 * unit, weight: .semibold, color: badge.color,
                tracking: 0.08)
            let pillWidth = label.size.width + 44 * unit
            let x = align == .center ? topLeft.x + (width - pillWidth) / 2 : topLeft.x
            let rect = flip(CGRect(x: x, y: y, width: pillWidth, height: badgeHeight))
            ctx.setFillColor(badge.fill)
            ctx.addPath(
                CGPath(roundedRect: rect, cornerWidth: badgeHeight / 2, cornerHeight: badgeHeight / 2, transform: nil))
            ctx.fillPath()
            label.draw(
                in: ctx,
                at: CGPoint(x: rect.minX + (pillWidth - label.size.width) / 2, y: rect.midY - label.size.height / 2))
            y += badgeHeight + badgeGap
        }

        let headline = Paragraph(runs: text.headline, align: align)
        let hHeight = headline.height(fittingWidth: width)
        headline.draw(in: ctx, rect: flip(CGRect(x: topLeft.x, y: y, width: width, height: hHeight)))
        y += hHeight

        if let sub = text.sub {
            y += subGap
            let paragraph = Paragraph(
                runs: [TextRun(text: sub.text, color: sub.color, weight: .regular, size: text.subSize, tracking: 0)],
                align: align, lineHeightMultiple: 1.28)
            let subWidth = width * text.subWidthFactor
            let subX = align == .center ? topLeft.x + (width - subWidth) / 2 : topLeft.x
            let sHeight = paragraph.height(fittingWidth: subWidth)
            paragraph.draw(in: ctx, rect: flip(CGRect(x: subX, y: y, width: subWidth, height: sHeight)))
            y += sHeight
        }
        return y
    }

    // MARK: - Window

    /// `frame` is in top-left coordinates and may extend past the canvas — that is
    /// how a shot gets the "window runs off the edge" look.
    private func drawWindow(
        _ ctx: CGContext, _ image: CGImage, shot: ResolvedShot, frame topLeftFrame: CGRect
    ) throws {
        let frame = flip(topLeftFrame)
        let radius = shot.cornerRadius * unit
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -shot.shadow.dy * unit),
            blur: shot.shadow.blur * unit,
            color: CGColor(colorSpace: sRGB, components: [0, 0, 0, shot.shadow.opacity])!)
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 0, 1])!)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: frame)

        if let spot = shot.spotlight {
            // Spotlight is expressed in post-crop source pixels with a top-left
            // origin, so it maps straight off a measurement taken in Preview.
            let scale = frame.width / CGFloat(image.width)
            let r = CGRect(
                x: frame.minX + spot.minX * scale,
                y: frame.maxY - (spot.minY + spot.height) * scale,
                width: spot.width * scale,
                height: spot.height * scale)
            let inset = 14 * unit
            let hole = CGPath(
                roundedRect: r.insetBy(dx: -inset, dy: -inset), cornerWidth: 20 * unit,
                cornerHeight: 20 * unit, transform: nil)
            let dim = CGMutablePath()
            dim.addPath(path)
            dim.addPath(hole)
            ctx.saveGState()
            ctx.addPath(dim)
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.62])!)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()

            ctx.setStrokeColor(try CGColor.hex(shot.theme.accentColor, alpha: 0.95))
            ctx.setLineWidth(4 * unit)
            ctx.addPath(hole)
            ctx.strokePath()
        }
        ctx.restoreGState()

        if let border = shot.theme.windowBorder {
            ctx.setStrokeColor(try CGColor.hex(border))
            ctx.setLineWidth(2 * unit)
            ctx.addPath(path)
            ctx.strokePath()
        }

        for callout in shot.callouts {
            try draw(callout: callout, ctx, shot: shot, windowFrame: frame)
        }
        for inset in shot.insets {
            try draw(inset: inset, ctx, shot: shot, source: image, windowFrame: frame)
        }
    }

    // MARK: - Magnified detail cards

    /// Enlarges one region of the window into a titled card floating over the frame.
    /// This is the part that names a feature: the card says what it is, the leader
    /// line says where it lives, and the magnified pixels prove it is really there.
    private func draw(
        inset: Shot.Inset, _ ctx: CGContext, shot: ResolvedShot, source: CGImage,
        windowFrame frame: CGRect
    ) throws {
        guard inset.from.count == 4 else { throw Failure("an inset's \"from\" needs four numbers") }
        guard inset.at.count == 2 else { throw Failure("an inset's \"at\" needs two numbers") }

        let from = CGRect(
            x: inset.from[0], y: inset.from[1], width: inset.from[2], height: inset.from[3]
        ).integral
        guard let magnified = source.cropping(to: from) else {
            throw Failure("inset \"\(inset.label)\" crops outside the \(source.width)x\(source.height) window")
        }

        // How big that region renders inside the window, times the magnification.
        let windowScale = frame.width / CGFloat(source.width)
        let magnification = CGFloat(inset.scale ?? 1.6)
        let cardBody = CGSize(
            width: from.width * windowScale * magnification,
            height: from.height * windowScale * magnification)

        let titleSize = 34 * unit
        let detailSize = 27 * unit
        let padding = 26 * unit
        let title = Label(
            inset.label, size: titleSize, weight: .semibold, color: try CGColor.hex(shot.theme.headlineColor))
        let detail = inset.detail.map {
            Label($0, size: detailSize, weight: .regular, color: try! CGColor.hex(shot.theme.subColor))
        }
        let headerHeight = padding + title.size.height + (detail.map { $0.size.height + 8 * unit } ?? 0) + padding
        let card = CGRect(
            x: inset.at[0] * canvas.width - cardBody.width / 2,
            y: canvas.height - inset.at[1] * canvas.height - (cardBody.height + headerHeight) / 2,
            width: cardBody.width,
            height: cardBody.height + headerHeight)
        let radius = 22 * unit
        let cardPath = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // The region on the window this card came from, outlined and connected.
        let origin = CGRect(
            x: frame.minX + from.minX * windowScale,
            y: frame.maxY - (from.minY + from.height) * windowScale,
            width: from.width * windowScale,
            height: from.height * windowScale)
        let accent = try CGColor.hex(shot.theme.accentColor)

        if inset.connect ?? true {
            ctx.saveGState()
            ctx.setStrokeColor(try CGColor.hex(shot.theme.accentColor, alpha: 0.85))
            ctx.setLineWidth(3 * unit)
            ctx.setLineDash(phase: 0, lengths: [12 * unit, 10 * unit])
            ctx.move(to: CGPoint(x: origin.midX, y: origin.midY))
            ctx.addLine(to: CGPoint(x: card.midX, y: card.midY))
            ctx.strokePath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(4 * unit)
            ctx.addPath(
                CGPath(
                    roundedRect: origin.insetBy(dx: -8 * unit, dy: -8 * unit), cornerWidth: 12 * unit,
                    cornerHeight: 12 * unit, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // The card itself, dropped over everything with a heavier shadow than the
        // window's so it reads as a separate layer rather than part of the UI.
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -26 * unit), blur: 90 * unit,
            color: CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.7])!)
        ctx.setFillColor(try CGColor.hex("#0D1524"))
        ctx.addPath(cardPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        ctx.draw(
            magnified,
            in: CGRect(x: card.minX, y: card.minY, width: cardBody.width, height: cardBody.height))
        ctx.restoreGState()

        title.draw(
            in: ctx,
            at: CGPoint(x: card.minX + padding, y: card.maxY - padding - title.size.height))
        detail?.draw(
            in: ctx,
            at: CGPoint(
                x: card.minX + padding,
                y: card.maxY - padding - title.size.height - 8 * unit - (detail?.size.height ?? 0)))

        ctx.setStrokeColor(try CGColor.hex(shot.theme.accentColor, alpha: 0.55))
        ctx.setLineWidth(3 * unit)
        ctx.addPath(cardPath)
        ctx.strokePath()
    }

    private func draw(
        callout: Shot.Callout, _ ctx: CGContext, shot: ResolvedShot, windowFrame frame: CGRect
    ) throws {
        guard callout.at.count == 2 else { throw Failure("a callout's \"at\" needs two numbers") }
        let target = CGPoint(
            x: frame.minX + callout.at[0] * frame.width,
            y: frame.maxY - callout.at[1] * frame.height)

        let accent = try CGColor.hex(shot.theme.accentColor)

        // The card must shrink-wrap inside the margin beside the window. Anything
        // wider would be clamped back over the UI it is naming, which defeats it.
        let edgeInset = 56 * unit
        let windowGap = 44 * unit
        let padX = 34 * unit
        let padY = 26 * unit
        let gap = 12 * unit
        let barWidth = 7 * unit
        let maxCard =
            callout.side == .left
            ? frame.minX - windowGap - edgeInset
            : canvas.width - edgeInset - frame.maxX - windowGap
        let textWidth = max(160 * unit, maxCard - padX * 2 - barWidth)

        let namePara = Paragraph(
            runs: [
                TextRun(
                    text: callout.text, color: try CGColor.hex(shot.theme.headlineColor),
                    weight: .bold, size: 40 * unit)
            ], align: .left, lineHeightMultiple: 1.04)
        let nameSize = namePara.size(fittingWidth: textWidth)

        let shortcutLabel = try callout.shortcut.map {
            Label(
                $0, size: 27 * unit, weight: .medium, monospaced: true,
                color: try CGColor.hex(shot.theme.headlineColor))
        }
        let shortcutSize = shortcutLabel.map {
            CGSize(width: $0.size.width + 24 * unit, height: $0.size.height + 12 * unit)
        }

        let detailPara = try callout.detail.map { text in
            Paragraph(
                runs: [
                    TextRun(
                        text: text, color: try CGColor.hex(shot.theme.subColor), weight: .regular,
                        size: 29 * unit, tracking: 0)
                ], align: .left, lineHeightMultiple: 1.2)
        }
        let detailWidth = textWidth - (shortcutSize.map { $0.width + gap } ?? 0)
        let detailSize = detailPara?.size(fittingWidth: detailWidth) ?? .zero
        let row2Height = max(detailSize.height, shortcutSize?.height ?? 0)

        let contentWidth = max(
            nameSize.width,
            (shortcutSize.map { $0.width + gap } ?? 0) + detailSize.width)
        let card = CGSize(
            width: min(maxCard, contentWidth + padX * 2 + barWidth),
            height: nameSize.height
                + (row2Height > 0 ? row2Height + gap : 0) + padY * 2)

        let x: CGFloat =
            callout.side == .left
            ? max(edgeInset, frame.minX - windowGap - card.width)
            : min(canvas.width - edgeInset - card.width, frame.maxX + windowGap)
        let rect = CGRect(
            x: x,
            y: min(max(target.y - card.height / 2, edgeInset), canvas.height - edgeInset - card.height),
            width: card.width, height: card.height)
        let attach = CGPoint(x: callout.side == .left ? rect.maxX : rect.minX, y: rect.midY)

        // Leader: horizontally out of the card, then an elbow down to the target. A
        // straight diagonal across the UI reads as a scratch on the screenshot.
        ctx.saveGState()
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(4 * unit)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let elbowX = callout.side == .left ? attach.x + 30 * unit : attach.x - 30 * unit
        ctx.move(to: attach)
        ctx.addLine(to: CGPoint(x: elbowX, y: attach.y))
        ctx.addLine(to: CGPoint(x: elbowX, y: target.y))
        ctx.addLine(to: target)
        ctx.strokePath()
        ctx.setFillColor(accent)
        ctx.addEllipse(
            in: CGRect(
                x: target.x - 11 * unit, y: target.y - 11 * unit, width: 22 * unit, height: 22 * unit))
        ctx.fillPath()
        ctx.restoreGState()

        let radius = 20 * unit
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -16 * unit), blur: 60 * unit,
            color: CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.55])!)
        ctx.setFillColor(try CGColor.hex(shot.theme.calloutFill ?? "#0D1524F7"))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        // Accent bar on the edge facing the window, so the card points at its target.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(accent)
        ctx.fill(
            CGRect(
                x: callout.side == .left ? rect.maxX - barWidth : rect.minX,
                y: rect.minY, width: barWidth, height: rect.height))
        ctx.restoreGState()

        let textX = rect.minX + padX + (callout.side == .right ? barWidth : 0)
        var y = rect.maxY - padY

        namePara.draw(
            in: ctx,
            rect: CGRect(x: textX, y: y - nameSize.height, width: textWidth, height: nameSize.height))
        y -= nameSize.height + gap

        var row2X = textX
        if let shortcutLabel, let shortcutSize {
            let chip = CGRect(
                x: row2X, y: y - row2Height + (row2Height - shortcutSize.height) / 2,
                width: shortcutSize.width, height: shortcutSize.height)
            let chipPath = CGPath(
                roundedRect: chip, cornerWidth: 9 * unit, cornerHeight: 9 * unit, transform: nil)
            ctx.setFillColor(try CGColor.hex("#FFFFFF", alpha: 0.10))
            ctx.addPath(chipPath)
            ctx.fillPath()
            ctx.setStrokeColor(try CGColor.hex("#FFFFFF", alpha: 0.22))
            ctx.setLineWidth(2 * unit)
            ctx.addPath(chipPath)
            ctx.strokePath()
            shortcutLabel.draw(
                in: ctx,
                at: CGPoint(
                    x: chip.midX - shortcutLabel.size.width / 2,
                    y: chip.midY - shortcutLabel.size.height / 2))
            row2X += shortcutSize.width + gap
        }
        detailPara?.draw(
            in: ctx,
            rect: CGRect(
                x: row2X, y: y - row2Height + (row2Height - detailSize.height) / 2,
                width: detailWidth, height: detailSize.height))
    }
}
