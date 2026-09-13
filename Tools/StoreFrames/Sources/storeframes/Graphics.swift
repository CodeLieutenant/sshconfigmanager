import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Colours

extension CGColor {
    /// "#RGB", "#RRGGBB" or "#RRGGBBAA".
    static func hex(_ string: String, alpha overrideAlpha: Double? = nil) throws -> CGColor {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else {
            throw Failure("bad colour \"\(string)\" — use #RGB, #RRGGBB or #RRGGBBAA")
        }
        let hasAlpha = s.count == 8
        let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
        return CGColor(colorSpace: sRGB, components: [r, g, b, overrideAlpha ?? a])!
    }
}

// MARK: - Bitmaps

/// An opaque 32-bit sRGB canvas. Opaque matters: App Store Connect rejects a
/// screenshot that carries an alpha channel, and `noneSkipLast` guarantees the
/// encoder never writes one.
func makeCanvas(width: Int, height: Int) throws -> CGContext {
    guard
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else {
        throw Failure("could not allocate a \(width)x\(height) canvas")
    }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    return ctx
}

func loadImage(_ url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else {
        throw Failure("could not read an image from \(url.path)")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw Failure("could not create a PNG writer for \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw Failure("could not finalise \(url.path)")
    }
}

// MARK: - Window detection

/// Finds the app window inside a capture that has flat padding around it.
///
/// Trimming by colour distance does not work here: the pad colour the capture
/// script uses (#1C1C1E) is the same colour as the app's own chrome, so a
/// distance test eats into the window. Rows of padding are *flat* instead —
/// every pixel identical — while any row that crosses the window carries the
/// traffic lights, a divider or text. Detecting flatness separates them.
func detectContentBox(_ image: CGImage, tolerance: Int = 6) throws -> CGRect {
    let w = image.width
    let h = image.height
    guard
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let base = ctx.data
    else { throw Failure("could not rasterise the source for window detection") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)

    // Row 0 of the buffer is the BOTTOM of the image (CG bitmaps are bottom-up),
    // so the y values below are flipped back at the end.
    func spread(row y: Int) -> Int {
        var lo = (255, 255, 255)
        var hi = (0, 0, 0)
        for x in 0..<w {
            let i = (y * w + x) * 4
            let r = Int(px[i])
            let g = Int(px[i + 1])
            let b = Int(px[i + 2])
            lo = (min(lo.0, r), min(lo.1, g), min(lo.2, b))
            hi = (max(hi.0, r), max(hi.1, g), max(hi.2, b))
        }
        return max(hi.0 - lo.0, max(hi.1 - lo.1, hi.2 - lo.2))
    }

    func spread(column x: Int) -> Int {
        var lo = (255, 255, 255)
        var hi = (0, 0, 0)
        for y in 0..<h {
            let i = (y * w + x) * 4
            let r = Int(px[i])
            let g = Int(px[i + 1])
            let b = Int(px[i + 2])
            lo = (min(lo.0, r), min(lo.1, g), min(lo.2, b))
            hi = (max(hi.0, r), max(hi.1, g), max(hi.2, b))
        }
        return max(hi.0 - lo.0, max(hi.1 - lo.1, hi.2 - lo.2))
    }

    var bottom = 0
    while bottom < h - 1, spread(row: bottom) <= tolerance { bottom += 1 }
    var top = h - 1
    while top > bottom, spread(row: top) <= tolerance { top -= 1 }
    var left = 0
    while left < w - 1, spread(column: left) <= tolerance { left += 1 }
    var right = w - 1
    while right > left, spread(column: right) <= tolerance { right -= 1 }

    guard right > left, top > bottom else {
        throw Failure("window detection found nothing but flat padding")
    }
    // Back to a top-left origin, which is what a crop rect in the spec uses.
    return CGRect(
        x: CGFloat(left), y: CGFloat(h - 1 - top),
        width: CGFloat(right - left + 1), height: CGFloat(top - bottom + 1))
}

/// Applies a spec crop. Crop rects use a top-left origin because that is what
/// Preview's inspector shows when you drag a selection over the source.
func crop(_ image: CGImage, _ crop: Shot.Crop?) throws -> CGImage {
    guard let crop else { return image }
    let rect: CGRect
    switch crop {
    case .auto: rect = try detectContentBox(image)
    case .rect(let r): rect = r
    }
    let clamped = rect.intersection(
        CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ).integral
    guard !clamped.isEmpty, let out = image.cropping(to: clamped) else {
        throw Failure("crop \(rect) falls outside the \(image.width)x\(image.height) source")
    }
    return out
}
