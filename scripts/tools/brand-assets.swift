// Builds the brand files in docs/brand (spec §5.42, docs/brand/README.md): the mark, the wordmark and the lockups, as
// SVG and PNG, from the brand mark's paths in docs/design/tokens.json (`customGlyphs[icon.brand]`, the front then the
// flap), the envelope's colours in `layout.appIcon`, the inks and lockup metrics in `layout.brand`, and the wordmark's
// master outlines in docs/brand/source/wordmark.svg. Nothing in docs/brand but the README and source/ is edited by hand.
//
// Usage: swift scripts/tools/brand-assets.swift [--check] [--root <repo>]
//   --check  writes nothing: renders into a temporary folder, compares every file byte for byte with docs/brand, and
//            exits 1 listing each one that is missing, stale or no longer made.
//
// Lockups are laid out in the wordmark's units (x-height 100, cap height `capHeight`), baseline y 0. Beside the word,
// the envelope is `lockupMark` tall and stands on the baseline, its sheared right side parallel to the word's 12° origin
// line and `lockupGap` before it; stacked, it is `stackedMark` tall, centred over the word's ink, `stackedGap` above the
// cap height's overshoot. Every file carries its clear space, a quarter of its envelope's height on every side, around
// the envelope's construction box (the √2 box before its corners are rounded) and the word's ink. SVGs are sized at
// 0.5 px per unit (the mark alone 10 px per glyph unit); PNGs at twice that. The one exception is the small one-colour
// mark (`layout.brand.monoSmall`), an icon for a sidebar or a menu bar: it sits on the glyph's square grid, as an icon
// is drawn, and its PNGs are the sizes it is for, 16, 20 and 32 px, each scaled so the envelope's top and bottom edges
// land on whole pixels.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("brand-assets: \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let check = arguments.contains("--check")
arguments.removeAll { $0 == "--check" }
var rootOption: String?
if let index = arguments.firstIndex(of: "--root") {
    guard index + 1 < arguments.count else { fail("--root needs a value") }
    rootOption = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}
if let unknown = arguments.first { fail("unknown argument \(unknown). Usage: swift scripts/tools/brand-assets.swift [--check] [--root <repo>]") }

func findRoot() -> URL {
    let fm = FileManager.default
    if let rootOption { return URL(fileURLWithPath: rootOption).standardizedFileURL }
    var dir = URL(fileURLWithPath: fm.currentDirectoryPath).standardizedFileURL
    while dir.path != "/" {
        if fm.fileExists(atPath: dir.appendingPathComponent("docs/design/tokens.json").path),
           fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
        dir = dir.deletingLastPathComponent()
    }
    fail("cannot find the repository (no docs/design/tokens.json next to a Package.swift); pass --root")
}
let root = findRoot()
let brandDir = root.appendingPathComponent("docs/brand")

// MARK: - Inputs

guard let tokenData = FileManager.default.contents(atPath: root.appendingPathComponent("docs/design/tokens.json").path),
      let tokens = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
      let icons = tokens["icon"] as? [String: Any], let brandName = icons["brand"] as? String,
      let glyphs = tokens["customGlyphs"] as? [String: Any], let glyph = glyphs[brandName] as? [String: Any],
      let partData = glyph["paths"] as? [String], partData.count == 2, let gridNumber = glyph["grid"] as? NSNumber,
      let layout = tokens["layout"] as? [String: Any], let brand = layout["brand"] as? [String: Any],
      let appIcon = layout["appIcon"] as? [String: Any] else {
    fail("tokens.json needs icon.brand, its two-path glyph, layout.appIcon and layout.brand")
}
let grid = CGFloat(gridNumber.doubleValue)

func hex(_ value: Any?, _ name: String) -> String {
    guard let value = value as? String, value.count == 7, value.hasPrefix("#") else { fail("\(name) must be #RRGGBB") }
    return value.uppercased()
}
func metric(_ key: String) -> CGFloat {
    guard let value = brand[key] as? NSNumber else { fail("layout.brand.\(key) must be a number") }
    return CGFloat(value.doubleValue)
}
func ramp(_ key: String) -> Paint {
    guard let pair = appIcon[key] as? [String], pair.count == 2 else { fail("layout.appIcon.\(key) must be two colours") }
    return .ramp(hex(pair[0], "layout.appIcon.\(key)"), hex(pair[1], "layout.appIcon.\(key)"))
}
let ink = hex(brand["ink"], "layout.brand.ink")
let white = "#FFFFFF"
guard let smallData = brand["monoSmall"] as? [String], smallData.count == 2 else { fail("layout.brand.monoSmall must be two paths") }

/// How a shape is filled: one colour, a top-to-bottom ramp over the shape's own bounds (as the app icon's parts are), or
/// the reader's text colour.
enum Paint {
    case solid(String)
    case ramp(String, String)
    case current
}

/// The wordmark master: its path data and its frame (x from 0 to the advance, y from the overshoot's top to the
/// descender, baseline 0).
let wordmarkSource = brandDir.appendingPathComponent("source/wordmark.svg")
guard let wordmarkText = try? String(contentsOf: wordmarkSource, encoding: .utf8) else { fail("cannot read \(wordmarkSource.path)") }
func attribute(_ name: String, in text: String) -> String {
    guard let start = text.range(of: " \(name)=\""), let end = text[start.upperBound...].firstIndex(of: "\"") else {
        fail("docs/brand/source/wordmark.svg has no \(name)")
    }
    return String(text[start.upperBound..<end])
}
let wordmarkPath = attribute("d", in: wordmarkText)
let frame = attribute("viewBox", in: wordmarkText).split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
guard frame.count == 4, frame[0] == 0, frame[1] < 0 else { fail("the wordmark's viewBox must be 0 <top> <advance> <height>") }
let wordTop = frame[1], wordBottom = frame[1] + frame[3]
let capHeight = metric("capHeight")

// MARK: - SVG path data (M L H V C A Z, absolute and relative), for the PNGs and the ink bounds


/// Parses path data in its own units (y down) into a CGPath.
func parsePath(_ data: String) -> CGPath {
    var scanner = PathScanner(Array(data.utf8))
    return scanner.run()
}

struct PathScanner {
    let bytes: [UInt8]
    var index = 0
    let path = CGMutablePath()
    var current = CGPoint.zero
    var start = CGPoint.zero

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func run() -> CGPath {
        var command: UInt8 = 0
        skip()
        while index < bytes.count {
            if isCommand(bytes[index]) {
                command = bytes[index]
                index += 1
                if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                    path.closeSubpath()
                    current = start
                    skip()
                    continue
                }
            } else if command == 0 {
                fail("path data must start with a command")
            }
            segment(command)
            // Coordinates after M repeat as L (after m as l).
            if command == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
            if command == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
            skip()
        }
        return path
    }

    mutating func segment(_ command: UInt8) {
        let relative = command >= UInt8(ascii: "a")
        let base = relative ? current : .zero
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }
        switch command | 0x20 {
        case UInt8(ascii: "m"):
            current = point(number(), number())
            start = current
            path.move(to: current)
        case UInt8(ascii: "l"):
            current = point(number(), number())
            path.addLine(to: current)
        case UInt8(ascii: "h"):
            current = CGPoint(x: (relative ? current.x : 0) + number(), y: current.y)
            path.addLine(to: current)
        case UInt8(ascii: "v"):
            current = CGPoint(x: current.x, y: (relative ? current.y : 0) + number())
            path.addLine(to: current)
        case UInt8(ascii: "c"):
            let c1 = point(number(), number()), c2 = point(number(), number()), end = point(number(), number())
            path.addCurve(to: end, control1: c1, control2: c2)
            current = end
        case UInt8(ascii: "a"):
            let rx = number(), ry = number(), rotation = number(), large = flag(), sweep = flag()
            let end = point(number(), number())
            addArc(from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
            current = end
        default:
            fail("path command \(Character(UnicodeScalar(command))) is not supported")
        }
    }

    /// SVG 1.1 §F.6.5: endpoint to centre parameterisation, radii scaled up when too small, one cubic per
    /// quarter turn or less.
    func addArc(from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let k = (large != sweep ? 1 : -1) * max(0, numerator / denominator).squareRoot()
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat { atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cosPhi * x - ry * sinPhi * y, y: cy + rx * sinPhi * x + ry * cosPhi * y)
        }
        for s in 0..<segments {
            let a0 = theta + CGFloat(s) * step, a1 = a0 + step
            let c1 = map(cos(a0) - t * sin(a0), sin(a0) + t * cos(a0))
            let c2 = map(cos(a1) + t * sin(a1), sin(a1) - t * cos(a1))
            path.addCurve(to: map(cos(a1), sin(a1)), control1: c1, control2: c2)
        }
    }

    func isCommand(_ c: UInt8) -> Bool { "MmLlHhVvCcAaZz".utf8.contains(c) }

    mutating func skip() {
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ",")
            || bytes[index] == 0x0A || bytes[index] == 0x09 || bytes[index] == 0x0D { index += 1 }
    }

    mutating func number() -> CGFloat {
        skip()
        let begin = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
        var seenDot = false
        while index < bytes.count {
            let c = bytes[index]
            if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") { index += 1; continue }
            if c == UInt8(ascii: "."), !seenDot { seenDot = true; index += 1; continue }
            break
        }
        guard index > begin, let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)) else {
            fail("number expected at offset \(begin) of the path data")
        }
        return CGFloat(value)
    }

    mutating func flag() -> Bool {
        skip()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else { fail("arc flag expected") }
        index += 1
        return bytes[index - 1] == UInt8(ascii: "1")
    }
}



// MARK: - Artwork

/// One filled shape: path data in its own units, placed by a scale and an offset, its paint, and its part ("front",
/// "flap" or "word"), which names its gradient.
struct Shape {
    let data: String
    let scale: CGFloat
    let x: CGFloat, y: CGFloat
    let paint: Paint
    let part: String
}

/// One PNG of a brand file: its name and pixel size, and where the file's frame lands in it (`scale` pixels per unit,
/// the frame's origin at (x, y) pixels).
struct Raster {
    let name: String
    let width: Int, height: Int
    let scale: CGFloat
    let x: CGFloat, y: CGFloat
}

/// A brand file: its frame in units, the shapes on it, how many pixels a unit is in the SVG, and its PNGs.
struct Artwork {
    let name: String
    let width: CGFloat, height: CGFloat
    let shapes: [Shape]
    let svgScale: CGFloat
    let rasters: [Raster]

    /// One PNG named after the file, `pngScale` pixels per unit.
    init(name: String, width: CGFloat, height: CGFloat, shapes: [Shape], svgScale: CGFloat, pngScale: CGFloat) {
        self.init(name: name, width: width, height: height, shapes: shapes, svgScale: svgScale,
                  rasters: [Raster(name: name, width: Int((width * pngScale).rounded()), height: Int((height * pngScale).rounded()),
                                   scale: pngScale, x: 0, y: 0)])
    }

    init(name: String, width: CGFloat, height: CGFloat, shapes: [Shape], svgScale: CGFloat, rasters: [Raster]) {
        self.name = name
        self.width = width
        self.height = height
        self.shapes = shapes
        self.svgScale = svgScale
        self.rasters = rasters
    }
}

/// A number written the same way on every run, so the files only change when their sources do.
func fixed(_ value: CGFloat, _ places: Int = 2) -> String {
    var text = String(format: "%.\(places)f", Double(value))
    while text.contains("."), text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

func svg(_ art: Artwork) -> String {
    var defs = ""
    var body = ""
    for shape in art.shapes {
        let transform = shape.scale == 1 && shape.x == 0 && shape.y == 0 ? ""
            : shape.scale == 1 ? " transform=\"translate(\(fixed(shape.x)) \(fixed(shape.y)))\""
            : " transform=\"matrix(\(fixed(shape.scale, 4)) 0 0 \(fixed(shape.scale, 4)) \(fixed(shape.x)) \(fixed(shape.y)))\""
        let fill: String
        switch shape.paint {
        case .solid(let colour): fill = colour
        case .current: fill = "currentColor"
        case .ramp(let top, let bottom):
            // Ids unique to the file: two files inlined in one page share one id space, where `url(#…)` takes the first
            // definition, so a shared id would paint the reversed file with the colour file's ramps.
            let id = "ssb-\(art.name)-\(shape.part)"
            defs += "<linearGradient id=\"\(id)\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(top)\"/>"
                + "<stop offset=\"1\" stop-color=\"\(bottom)\"/></linearGradient>"
            fill = "url(#\(id))"
        }
        body += "<path\(transform) fill=\"\(fill)\" d=\"\(shape.data)\"/>"
    }
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(fixed(art.width * art.svgScale))\" height=\"\(fixed(art.height * art.svgScale))\" "
        + "viewBox=\"0 0 \(fixed(art.width)) \(fixed(art.height))\" role=\"img\" aria-label=\"SuperSparrow\">"
        + (defs.isEmpty ? "" : "<defs>\(defs)</defs>") + body + "</svg>\n"
}

func cgColor(_ hex: String) -> CGColor {
    guard let value = UInt32(hex.dropFirst(), radix: 16) else { fail("colour \(hex) is not #RRGGBB") }
    return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

func png(_ art: Artwork, _ raster: Raster) -> CGImage {
    guard let context = CGContext(data: nil, width: raster.width, height: raster.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot make \(raster.name).png") }
    // y down, in units.
    context.translateBy(x: raster.x, y: CGFloat(raster.height) - raster.y)
    context.scaleBy(x: raster.scale, y: -raster.scale)
    for shape in art.shapes {
        var transform = CGAffineTransform(a: shape.scale, b: 0, c: 0, d: shape.scale, tx: shape.x, ty: shape.y)
        guard let placed = parsePath(shape.data).copy(using: &transform) else { fail("cannot place a shape in \(art.name)") }
        switch shape.paint {
        case .solid(let colour):
            context.addPath(placed)
            context.setFillColor(cgColor(colour))
            context.fillPath(using: .winding)
        case .current:
            // `currentColor` has no colour of its own; its PNG is drawn in ink, as the README says.
            context.addPath(placed)
            context.setFillColor(cgColor(ink))
            context.fillPath(using: .winding)
        case .ramp(let top, let bottom):
            let bounds = placed.boundingBoxOfPath
            context.saveGState()
            context.addPath(placed)
            context.clip()
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [cgColor(top), cgColor(bottom)] as CFArray,
                                      locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.minY), end: CGPoint(x: bounds.midX, y: bounds.maxY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }
    }
    guard let image = context.makeImage() else { fail("cannot finish \(raster.name).png") }
    return image
}

/// The envelope's construction box on the glyph grid: the √2 box sheared 12° before its corners are rounded, from the
/// bottom-left corner's x to the top-right corner's, top to bottom. Clear space is measured from it.
let slant = tan(12 * CGFloat.pi / 180)
let markBounds: CGRect = {
    let parts = partData.map { parsePath($0).boundingBoxOfPath }
    let top = parts.map(\.minY).min()!, bottom = parts.map(\.maxY).max()!
    let half = (bottom - top) * 2.0.squareRoot() / 2, centre = grid / 2, rise = (bottom - top) / 2 * slant
    return CGRect(x: centre - half - rise, y: top, width: 2 * (half + rise), height: bottom - top)
}()
/// The bottom-right corner of the construction box: the foot of the sheared right side.
let markFoot = CGPoint(x: markBounds.maxX - 2 * (markBounds.height / 2 * slant), y: markBounds.maxY)

struct Colours { let front: Paint, flap: Paint, word: Paint }
let variants: [(String, Colours)] = [
    ("colour", Colours(front: ramp("front"), flap: ramp("flap"), word: .solid(ink))),
    ("reversed", Colours(front: ramp("frontDark"), flap: ramp("flapDark"), word: .solid(white))),
    ("mono", Colours(front: .solid(ink), flap: .solid(ink), word: .solid(ink))),
    ("white", Colours(front: .solid(white), flap: .solid(white), word: .solid(white))),
]

/// The envelope `height` units tall (its construction box), the box's top-left at (x, y): the front, then the flap.
func mark(height: CGFloat, x: CGFloat, y: CGFloat, _ c: Colours, paths: [String] = partData) -> [Shape] {
    let scale = height / markBounds.height
    let ox = x - markBounds.minX * scale, oy = y - markBounds.minY * scale
    return [Shape(data: paths[0], scale: scale, x: ox, y: oy, paint: c.front, part: "front"),
            Shape(data: paths[1], scale: scale, x: ox, y: oy, paint: c.flap, part: "flap")]
}

/// The word's ink, which the italic carries past the advance on the right.
let wordInk = parsePath(wordmarkPath).boundingBoxOfPath

var artworks: [Artwork] = []

// The mark alone, in its construction box with a quarter of its height clear on every side.
do {
    let clear = markBounds.height / 4
    let width = markBounds.width + 2 * clear, height = markBounds.height + 2 * clear
    let marks: [(String, Colours)] = [
        ("symbol-colour", variants[0].1), ("symbol-reversed", variants[1].1),
        ("symbol-mono", Colours(front: .current, flap: .current, word: .current)),
    ]
    for (name, c) in marks {
        artworks.append(Artwork(name: name, width: width, height: height, shapes: mark(height: markBounds.height, x: clear, y: clear, c),
                                svgScale: 10, pngScale: 20))
    }
}

// The small one-colour mark: an icon on the glyph's square grid (the space around it is the sidebar's or the menu
// bar's), 0.5 px per unit in the SVG, 20 px. Each PNG takes the scale nearest to its size that makes the envelope a whole
// number of pixels tall, with its top edge on a whole pixel and the box centred across, so its long edges stay crisp.
do {
    let shapes = [Shape(data: smallData[0], scale: 1, x: 0, y: 0, paint: .current, part: "front"),
                  Shape(data: smallData[1], scale: 1, x: 0, y: 0, paint: .current, part: "flap")]
    let rasters = [16, 20, 32].map { size -> Raster in
        let side = CGFloat(size)
        let tall = (markBounds.height * side / grid).rounded()
        let scale = tall / markBounds.height
        let top = ((side - tall) / 2).rounded(.down)
        return Raster(name: "symbol-mono-small-\(size)", width: size, height: size, scale: scale,
                      x: side / 2 - markBounds.midX * scale, y: top - markBounds.minY * scale)
    }
    artworks.append(Artwork(name: "symbol-mono-small", width: grid, height: grid, shapes: shapes, svgScale: 0.5, rasters: rasters))
}

// The wordmark alone: its ink with the same clear space a lockup gives it.
for (name, colour) in [("wordmark", ink), ("wordmark-white", white)] {
    let clear = capHeight / 4
    artworks.append(Artwork(name: name, width: wordInk.width + 2 * clear, height: wordBottom - wordTop + 2 * clear,
                            shapes: [Shape(data: wordmarkPath, scale: 1, x: clear - wordInk.minX, y: clear - wordTop, paint: .solid(colour), part: "word")],
                            svgScale: 0.5, pngScale: 1))
}

// Horizontal: the envelope on the baseline, its sheared right side `lockupGap` before the word's 12° origin line.
do {
    let markHeight = metric("lockupMark"), gap = metric("lockupGap")
    let clear = markHeight / 4
    let scale = markHeight / markBounds.height
    // In word units with the word's origin at x 0: the envelope's foot sits `gap` left of it, on the baseline.
    let markLeft = -gap - (markFoot.x - markBounds.minX) * scale
    let left = markLeft, right = wordInk.maxX
    let top = min(-markHeight, wordTop), bottom = wordBottom
    let ox = clear - left, baseline = clear - top
    for (variant, c) in variants {
        let shapes = mark(height: markHeight, x: ox + markLeft, y: baseline - markHeight, c)
            + [Shape(data: wordmarkPath, scale: 1, x: ox, y: baseline, paint: c.word, part: "word")]
        artworks.append(Artwork(name: "lockup-horizontal-\(variant)", width: right - left + 2 * clear, height: bottom - top + 2 * clear,
                                shapes: shapes, svgScale: 0.5, pngScale: 1))
    }
}

// Stacked: the envelope centred over the word's ink, `stackedGap` above the cap height's overshoot.
do {
    let markHeight = metric("stackedMark"), gap = metric("stackedGap")
    let clear = markHeight / 4
    let markWidth = markBounds.width * markHeight / markBounds.height
    let width = max(wordInk.width, markWidth)
    let baseline = clear + markHeight + gap - wordTop
    for (variant, c) in variants {
        let shapes = mark(height: markHeight, x: clear + (width - markWidth) / 2, y: clear, c)
            + [Shape(data: wordmarkPath, scale: 1, x: clear + (width - wordInk.width) / 2 - wordInk.minX, y: baseline, paint: c.word,
                     part: "word")]
        artworks.append(Artwork(name: "lockup-stacked-\(variant)", width: width + 2 * clear, height: baseline + wordBottom + clear,
                                shapes: shapes, svgScale: 0.5, pngScale: 1))
    }
}

// MARK: - Write

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

let fm = FileManager.default
/// Where the files go: docs/brand, or under --check a temporary folder compared with it afterwards.
let output = check ? fm.temporaryDirectory.appendingPathComponent("brand-assets-\(UUID().uuidString)") : brandDir
do { try fm.createDirectory(at: output, withIntermediateDirectories: true) } catch { fail("cannot make \(output.path): \(error)") }
var made: [String] = []
for art in artworks {
    do { try Data(svg(art).utf8).write(to: output.appendingPathComponent("\(art.name).svg")) } catch { fail("cannot write \(art.name).svg: \(error)") }
    made.append("\(art.name).svg")
    for raster in art.rasters {
        writePNG(png(art, raster), to: output.appendingPathComponent("\(raster.name).png"))
        made.append("\(raster.name).png")
    }
}
if !check {
    print("brand-assets: wrote \(artworks.count) SVG and \(made.count - artworks.count) PNG files to docs/brand")
    exit(0)
}

// Everything in docs/brand but the README and source/ is this script's, so anything else there is left over.
var stale: [String] = []
for name in made where fm.contents(atPath: output.appendingPathComponent(name).path) != fm.contents(atPath: brandDir.appendingPathComponent(name).path) {
    stale.append("docs/brand/\(name)" + (fm.fileExists(atPath: brandDir.appendingPathComponent(name).path) ? "" : " (missing)"))
}
let present = Set((try? fm.contentsOfDirectory(atPath: brandDir.path)) ?? []).subtracting(["README.md", "source", ".DS_Store"])
for name in present.subtracting(made).sorted() { stale.append("docs/brand/\(name) (no longer made)") }
try? fm.removeItem(at: output)
if stale.isEmpty {
    print("brand-assets: the \(made.count) files in docs/brand are up to date")
    exit(0)
}
FileHandle.standardError.write(Data("brand-assets: out of date (run `swift scripts/tools/brand-assets.swift`):\n".utf8))
for s in stale { FileHandle.standardError.write(Data("  \(s)\n".utf8)) }
exit(1)
