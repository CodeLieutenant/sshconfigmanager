import CoreGraphics
import Foundation

// storeframes — turns raw window captures into finished Mac App Store frames
// (background, headline, sub-caption, optional spotlight and callouts).
//
//   storeframes --spec <frames.json> --raw <dir> --out <dir> [options]
//
//   --only <substring>   render just the shots whose source or output matches
//   --size WxH           override the canvas (must be an App Store size)
//   --probe              report the detected window box per source and stop
//   --list               print the shot table and stop

/// The only canvas sizes App Store Connect accepts for a Mac app.
let allowedSizes: Set<String> = ["1280x800", "1440x900", "2560x1600", "2880x1800"]

struct Options {
    var spec = URL(fileURLWithPath: "store-assets/frames.json")
    var raw = URL(fileURLWithPath: "store-assets/raw/en-US")
    var out = URL(fileURLWithPath: "fastlane/screenshots/en-US")
    var only: String?
    var size: (Int, Int)?
    var probe = false
    var list = false
}

func parseOptions() throws -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func next(_ flag: String) throws -> String {
        guard let v = it.next() else { throw Failure("\(flag) needs a value") }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--spec": o.spec = URL(fileURLWithPath: try next(arg))
        case "--raw": o.raw = URL(fileURLWithPath: try next(arg))
        case "--out": o.out = URL(fileURLWithPath: try next(arg))
        case "--only": o.only = try next(arg)
        case "--probe": o.probe = true
        case "--list": o.list = true
        case "--size":
            let v = try next(arg)
            let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { throw Failure("--size wants WxH, got \"\(v)\"") }
            o.size = (parts[0], parts[1])
        case "-h", "--help":
            print(
                """
                storeframes --spec <frames.json> --raw <dir> --out <dir>
                            [--only <substring>] [--size WxH] [--probe] [--list]
                """)
            exit(0)
        default: throw Failure("unknown argument \"\(arg)\"")
        }
    }
    return o
}

func run() throws {
    let o = try parseOptions()

    guard FileManager.default.fileExists(atPath: o.spec.path) else {
        throw Failure("no spec at \(o.spec.path)")
    }
    var spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: o.spec))
    if let size = o.size {
        spec.canvas = Spec.Canvas(width: size.0, height: size.1)
    }
    let key = "\(spec.canvas.width)x\(spec.canvas.height)"
    guard allowedSizes.contains(key) else {
        throw Failure(
            "canvas \(key) is not a Mac App Store size — use one of \(allowedSizes.sorted().joined(separator: ", "))")
    }

    var shots = try spec.resolve()
    if let only = o.only {
        shots = shots.filter { $0.source.contains(only) || $0.output.contains(only) }
        guard !shots.isEmpty else { throw Failure("--only \"\(only)\" matched no shot") }
    }

    if o.list {
        for (i, s) in shots.enumerated() {
            print("\(i + 1). \(s.output)  ← \(s.source)  [\(s.layout.rawValue), \(s.themeName)]")
            print("     \(s.headline) \(s.accent ?? "")")
        }
        return
    }

    if o.probe {
        print("Detected window box per source (x y w h, top-left origin):")
        for s in shots {
            let url = o.raw.appendingPathComponent(s.source)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("  \(s.source): MISSING")
                continue
            }
            let image = try loadImage(url)
            let box = try detectContentBox(image)
            let inset =
                box == CGRect(x: 0, y: 0, width: image.width, height: image.height)
                ? "no padding found" : "padded"
            print(
                "  \(s.source): \(image.width)x\(image.height) → "
                    + "[\(Int(box.minX)), \(Int(box.minY)), \(Int(box.width)), \(Int(box.height))]  (\(inset))")
        }
        return
    }

    let renderer = Renderer(width: spec.canvas.width, height: spec.canvas.height)
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)

    var failures: [String] = []
    for shot in shots {
        let src = o.raw.appendingPathComponent(shot.source)
        guard FileManager.default.fileExists(atPath: src.path) else {
            failures.append("\(shot.output): source \(shot.source) is missing from \(o.raw.path)")
            continue
        }
        let window = try crop(try loadImage(src), shot.crop)
        let framed = try renderer.render(shot, window: window)
        let dest = o.out.appendingPathComponent(shot.output)
        try writePNG(framed, to: dest)

        // Verify what actually landed on disk, not what we meant to write.
        let check = try loadImage(dest)
        let ok = check.width == spec.canvas.width && check.height == spec.canvas.height
        let opaque =
            check.alphaInfo == .none || check.alphaInfo == .noneSkipLast
            || check.alphaInfo == .noneSkipFirst
        if !ok { failures.append("\(shot.output): wrote \(check.width)x\(check.height), wanted \(key)") }
        if !opaque { failures.append("\(shot.output): has an alpha channel — App Store Connect rejects that") }
        print("  ✓ \(shot.output)  \(check.width)x\(check.height)  ← \(shot.source) (\(window.width)x\(window.height))")
    }

    // The output directory is what `fastlane deliver` uploads, so anything left
    // there that the spec did not produce would ship too. Sweep it — but only on a
    // full run, or `--only` would delete the other frames.
    if o.only == nil {
        let wanted = Set(shots.map(\.output))
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: o.out.path)) ?? []
        for file in existing.sorted() where file.lowercased().hasSuffix(".png") && !wanted.contains(file) {
            try FileManager.default.removeItem(at: o.out.appendingPathComponent(file))
            print("  – removed stale \(file)")
        }
    }

    guard failures.isEmpty else {
        for f in failures { FileHandle.standardError.write(Data("  ✗ \(f)\n".utf8)) }
        throw Failure("\(failures.count) shot(s) failed")
    }
    print("\n\(shots.count) frame(s) written to \(o.out.path) at \(key).")
}

do {
    try run()
} catch let error as Failure {
    FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
