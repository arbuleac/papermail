// Builds the brand files in docs/brand (spec §5.42, docs/brand/README.md): the symbol, the wordmark, the lockups and the
// construction drawing, as SVG and PNG, from the brand mark's path in docs/design/tokens.json (`customGlyphs[icon.brand]`,
// the paper plane), the inks and lockup metrics in `layout.brand`, the app icon's grid in `layout.appIcon`, and the
// wordmark's master outlines in docs/brand/source/wordmark.svg. Nothing in docs/brand but the README and source/ is edited
// by hand.
//
// Usage: swift scripts/tools/brand-assets.swift [--check] [--root <repo>]
//   --check  writes nothing: renders into a temporary folder, compares every file byte for byte with docs/brand, and
//            exits 1 listing each one that is missing, stale or no longer made.
//
// Two colours only, both the icon's: ink and paper (white). The lockup is laid out in the wordmark's units (cap height
// `capHeight`), baseline y 0: the plane `lockupMark` tall (1.75 cap heights), its box centred at `lockupCentre` (on the cap
// height) and `lockupGap` (0.55 cap heights) before the word's origin, as the approved lockup draws it. The symbol carries
// one step of the isometric lattice (10 glyph units, 80 px on the icon) of clear space around the plane's box; the
// wordmark and the lockup half the cap height around their frames. SVGs are sized at 1 px per icon pixel for the symbol
// (8 px a glyph unit) and 0.2 px per unit for the word and the lockup; PNGs at twice that. The construction drawing is
// the symbol on the app icon's 1024 canvas, 1 px per unit, with its 8 px grid, its isometric lattice and its guides.
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
      let glyphPaths = glyph["paths"] as? [String], glyphPaths.count == 1, let gridNumber = glyph["grid"] as? NSNumber,
      let layout = tokens["layout"] as? [String: Any], let brand = layout["brand"] as? [String: Any],
      let appIcon = layout["appIcon"] as? [String: Any] else {
    fail("tokens.json needs icon.brand, its one-path glyph, layout.appIcon and layout.brand")
}
let planeData = glyphPaths[0]
let grid = CGFloat(gridNumber.doubleValue)

func hex(_ value: Any?, _ name: String) -> String {
    guard let value = value as? String, value.count == 7, value.hasPrefix("#") else { fail("\(name) must be #RRGGBB") }
    return value.uppercased()
}
func metric(_ table: [String: Any], _ name: String, _ key: String) -> CGFloat {
    guard let value = table[key] as? NSNumber else { fail("layout.\(name).\(key) must be a number") }
    return CGFloat(value.doubleValue)
}
func metric(_ key: String) -> CGFloat { metric(brand, "brand", key) }
let ink = hex(brand["ink"], "layout.brand.ink")
let paper = hex(brand["paper"], "layout.brand.paper")

/// The wordmark master: its path data and its frame (x from 0 to the advance, y from the cap height to the descender,
/// baseline 0).
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

/// How a shape is painted: filled, or stroked with a width and an optional dash, at an opacity.
enum Paint {
    case fill(String)
    case stroke(String, width: CGFloat, dash: [CGFloat])
}

/// One shape: path data in its own units, placed by a scale and an offset, and its paint.
struct Shape {
    let data: String
    var scale: CGFloat = 1
    var x: CGFloat = 0, y: CGFloat = 0
    let paint: Paint
    var opacity: CGFloat = 1
}

/// A brand file: its frame in units, the shapes on it, how many pixels a unit is in the SVG and in the PNG.
struct Artwork {
    let name: String
    let width: CGFloat, height: CGFloat
    let shapes: [Shape]
    let svgScale: CGFloat
    let pngScale: CGFloat
}

/// A number written the same way on every run, so the files only change when their sources do.
func fixed(_ value: CGFloat, _ places: Int = 2) -> String {
    var text = String(format: "%.\(places)f", Double(value))
    while text.contains("."), text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

func svg(_ art: Artwork) -> String {
    var body = ""
    for shape in art.shapes {
        let transform = shape.scale == 1 && shape.x == 0 && shape.y == 0 ? ""
            : shape.scale == 1 ? " transform=\"translate(\(fixed(shape.x)) \(fixed(shape.y)))\""
            : " transform=\"matrix(\(fixed(shape.scale, 6)) 0 0 \(fixed(shape.scale, 6)) \(fixed(shape.x)) \(fixed(shape.y)))\""
        let paint: String
        switch shape.paint {
        case .fill(let colour): paint = " fill=\"\(colour)\""
        case .stroke(let colour, let width, let dash):
            paint = " fill=\"none\" stroke=\"\(colour)\" stroke-width=\"\(fixed(width))\""
                + (dash.isEmpty ? "" : " stroke-dasharray=\"\(dash.map { fixed($0) }.joined(separator: " "))\"")
        }
        let opacity = shape.opacity == 1 ? "" : " opacity=\"\(fixed(shape.opacity))\""
        body += "<path\(transform)\(paint)\(opacity) d=\"\(shape.data)\"/>"
    }
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(fixed(art.width * art.svgScale))\" height=\"\(fixed(art.height * art.svgScale))\" "
        + "viewBox=\"0 0 \(fixed(art.width)) \(fixed(art.height))\" role=\"img\" aria-label=\"SuperSparrow\">" + body + "</svg>\n"
}

func cgColor(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    guard let value = UInt32(hex.dropFirst(), radix: 16) else { fail("colour \(hex) is not #RRGGBB") }
    return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

func png(_ art: Artwork) -> CGImage {
    let width = Int((art.width * art.pngScale).rounded()), height = Int((art.height * art.pngScale).rounded())
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot make \(art.name).png") }
    // y down, in units.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: art.pngScale, y: -art.pngScale)
    for shape in art.shapes {
        var transform = CGAffineTransform(a: shape.scale, b: 0, c: 0, d: shape.scale, tx: shape.x, ty: shape.y)
        guard let placed = parsePath(shape.data).copy(using: &transform) else { fail("cannot place a shape in \(art.name)") }
        context.addPath(placed)
        switch shape.paint {
        case .fill(let colour):
            context.setFillColor(cgColor(colour, alpha: shape.opacity))
            context.fillPath(using: .winding)
        case .stroke(let colour, let width, let dash):
            context.setStrokeColor(cgColor(colour, alpha: shape.opacity))
            context.setLineWidth(width)
            context.setLineDash(phase: 0, lengths: dash)
            context.strokePath()
        }
    }
    guard let image = context.makeImage() else { fail("cannot finish \(art.name).png") }
    return image
}

/// The plane's vertices in glyph units, as the path names them: the far wing N, WF, T; the near wing N, S, WN, the two
/// wings meeting at the nose N; the keel X, Sk, K.
let facets: [[CGPoint]] = planeData.split(separator: "Z").compactMap { sub in
    let numbers = sub.split(whereSeparator: { "MLZ ,".contains($0) }).compactMap { Double($0) }.map { CGFloat($0) }
    guard numbers.count >= 6, numbers.count % 2 == 0 else { return nil }
    return stride(from: 0, to: numbers.count, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
}
guard facets.count == 3, facets.map(\.count) == [3, 3, 3], facets[0][0] == facets[1][0] else {
    fail("the brand mark must be three triangles (M L Z only): the far wing and the near wing from one nose, then the keel")
}
let vertex = (n: facets[0][0], wf: facets[0][1], t: facets[0][2], s: facets[1][1], wn: facets[1][2],
              x: facets[2][0], sk: facets[2][1], k: facets[2][2])
/// The plane's box in glyph units.
let planeBox = parsePath(planeData).boundingBoxOfPath

/// The plane `height` units tall, its box's top-left at (x, y), in one colour.
func plane(height: CGFloat, x: CGFloat, y: CGFloat, _ colour: String) -> Shape {
    let scale = height / planeBox.height
    return Shape(data: planeData, scale: scale, x: x - planeBox.minX * scale, y: y - planeBox.minY * scale, paint: .fill(colour))
}

func rect(_ r: CGRect) -> String { "M\(fixed(r.minX)) \(fixed(r.minY)) H\(fixed(r.maxX)) V\(fixed(r.maxY)) H\(fixed(r.minX)) Z" }

/// A neutral grey `t` of the way from paper to ink, so every grey in docs/brand is the two brand colours mixed and never
/// a hue (R, G and B equal).
func mix(_ t: CGFloat) -> String {
    func channel(_ hex: String) -> CGFloat { CGFloat(UInt32(hex.dropFirst(), radix: 16)! >> 16 & 0xFF) }
    let value = Int((channel(paper) + (channel(ink) - channel(paper)) * t).rounded())
    return "#" + String(repeating: String(format: "%02X", value), count: 3)
}

let variants: [(suffix: String, colour: String)] = [("", ink), ("-white", paper)]

var artworks: [Artwork] = []

// The symbol: the plane's box with one lattice step (10 glyph units, 80 px on the icon) clear on every side, 1 px a
// pixel of the icon.
for (suffix, colour) in variants {
    let clear: CGFloat = 10
    artworks.append(Artwork(name: "symbol\(suffix)", width: planeBox.width + 2 * clear, height: planeBox.height + 2 * clear,
                            shapes: [plane(height: planeBox.height, x: clear, y: clear, colour)], svgScale: 8, pngScale: 16))
}

// The wordmark alone: its frame (origin to advance, cap height to descender) with half the cap height clear around it.
let wordAdvance = frame[2]
for (suffix, colour) in variants {
    let clear = capHeight / 2
    artworks.append(Artwork(name: "wordmark\(suffix)", width: wordAdvance + 2 * clear, height: wordBottom - wordTop + 2 * clear,
                            shapes: [Shape(data: wordmarkPath, x: clear, y: clear - wordTop, paint: .fill(colour))],
                            svgScale: 0.2, pngScale: 0.4))
}

// The lockup: the plane beside the word, its box centred at `lockupCentre` and `lockupGap` before the word's origin, the
// frame running to the word's advance, with half the cap height clear around it. On white and light grounds in ink, on
// dark grounds and photographs in white, and white on an ink ground that fills the clear space.
do {
    let markHeight = metric("lockupMark"), centre = metric("lockupCentre"), gap = metric("lockupGap")
    let markWidth = planeBox.width * markHeight / planeBox.height
    let clear = capHeight / 2
    let top = min(centre - markHeight / 2, wordTop), bottom = max(centre + markHeight / 2, wordBottom)
    let origin = markWidth + gap
    let width = origin + wordAdvance + 2 * clear, height = bottom - top + 2 * clear
    for (suffix, colour, ground) in [("", ink, nil), ("-white", paper, nil), ("-on-black", paper, ink)] as [(String, String, String?)] {
        var shapes: [Shape] = []
        if let ground { shapes.append(Shape(data: rect(CGRect(x: 0, y: 0, width: width, height: height)), paint: .fill(ground))) }
        shapes.append(plane(height: markHeight, x: clear, y: clear + centre - markHeight / 2 - top, colour))
        shapes.append(Shape(data: wordmarkPath, x: clear + origin, y: clear - top, paint: .fill(colour)))
        artworks.append(Artwork(name: "lockup-horizontal\(suffix)", width: width, height: height, shapes: shapes, svgScale: 0.2, pngScale: 0.4))
    }
}

// Construction: the symbol on the app icon's 1024 canvas, as the approved board draws it: the 8 px grid (one glyph unit), the
// isometric lattice anchored on the tail point S (verticals every 10 units, 80 px, and lines at 1:2 both ways), the plane,
// its construction lines dashed (the trailing edge WF–WN, the keel's top Sk–X, the 45° line N–K, the spine N–S, the fold
// line N–T, the keel's back through S, the far leading edge N–WF) and every vertex marked. The greys are paper and ink
// mixed, so the drawing too is black and white only.
do {
    let canvas = metric(appIcon, "appIcon", "canvas")
    let unit = metric(appIcon, "appIcon", "markSize") / grid
    let ox = metric(appIcon, "appIcon", "markX"), oy = metric(appIcon, "appIcon", "markY")
    func at(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + p.x * unit, y: oy + p.y * unit) }
    func line(_ a: CGPoint, _ b: CGPoint) -> String { "M\(fixed(a.x)) \(fixed(a.y)) L\(fixed(b.x)) \(fixed(b.y))" }
    /// The line through a and b, from t0 to t1 of the way (0 at a, 1 at b).
    func extended(_ a: CGPoint, _ b: CGPoint, _ t0: CGFloat, _ t1: CGFloat) -> String {
        let a = at(a), b = at(b)
        return line(CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0), CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1))
    }
    var fine = ""
    for v in stride(from: CGFloat(0), through: canvas, by: unit) {
        fine += "M\(fixed(v)) 0 V\(fixed(canvas)) M0 \(fixed(v)) H\(fixed(canvas)) "
    }
    // The lattice: one step is 10 units, the distance between the trailing edge's 1:2 line and the keel's top across
    // the near wing, anchored on S so the tail sits on a node.
    let anchor = at(vertex.s), step = 10 * unit
    var lattice = ""
    for i in -20...20 {
        let x = anchor.x + CGFloat(i) * step
        if x >= 0, x <= canvas { lattice += "M\(fixed(x)) 0 V\(fixed(canvas)) " }
    }
    for j in -40...40 {
        for sign: CGFloat in [1, -1] {
            let y0 = anchor.y + CGFloat(j) * step - sign * anchor.x / 2, y1 = anchor.y + CGFloat(j) * step + sign * (canvas - anchor.x) / 2
            if max(y0, y1) < 0 || min(y0, y1) > canvas { continue }
            lattice += "M0 \(fixed(y0)) L\(fixed(canvas)) \(fixed(y1)) "
        }
    }
    let v = vertex
    let guides = [extended(v.wf, v.wn, -0.15, 1.15), extended(v.sk, v.x, -0.5, 1.6), extended(v.n, v.k, -0.05, 1.12),
                  extended(v.n, v.s, -0.05, 1.25), extended(v.n, v.t, -0.05, 1.12),
                  line(CGPoint(x: at(v.s).x, y: at(v.s).y - 37 * unit), CGPoint(x: at(v.s).x, y: at(v.s).y + 38 * unit)),
                  extended(v.n, v.wf, -0.05, 1.12)].joined(separator: " ")
    let guide = mix(0.673)
    var shapes = [Shape(data: rect(CGRect(x: 0, y: 0, width: canvas, height: canvas)), paint: .fill(paper)),
                  Shape(data: fine.trimmingCharacters(in: .whitespaces), paint: .stroke(mix(0.11), width: 1, dash: [])),
                  Shape(data: lattice.trimmingCharacters(in: .whitespaces), paint: .stroke(mix(0.306), width: 1.5, dash: [])),
                  Shape(data: planeData, scale: unit, x: ox, y: oy, paint: .fill(ink)),
                  Shape(data: guides, paint: .stroke(guide, width: 2.5, dash: [14, 8]))]
    for m in [v.n, v.wf, v.t, v.s, v.wn, v.sk, v.x, v.k].map(at) {
        shapes.append(Shape(data: rect(CGRect(x: m.x - 6, y: m.y - 6, width: 12, height: 12)), paint: .fill(paper)))
        shapes.append(Shape(data: rect(CGRect(x: m.x - 6, y: m.y - 6, width: 12, height: 12)), paint: .stroke(guide, width: 3, dash: [])))
    }
    artworks.append(Artwork(name: "construction", width: canvas, height: canvas, shapes: shapes, svgScale: 1, pngScale: 1))
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
    writePNG(png(art), to: output.appendingPathComponent("\(art.name).png"))
    made += ["\(art.name).svg", "\(art.name).png"]
}
// Everything in docs/brand but the README and source/ is this script's, so anything else there is left over.
let present = Set((try? fm.contentsOfDirectory(atPath: brandDir.path)) ?? []).subtracting(["README.md", "source", ".DS_Store"])
let leftOver = present.subtracting(made).sorted()
if !check {
    print("brand-assets: wrote \(artworks.count) SVG and \(artworks.count) PNG files to docs/brand")
    for name in leftOver { print("brand-assets: docs/brand/\(name) is no longer made; delete it") }
    exit(leftOver.isEmpty ? 0 : 1)
}

var stale: [String] = []
for name in made where fm.contents(atPath: output.appendingPathComponent(name).path) != fm.contents(atPath: brandDir.appendingPathComponent(name).path) {
    stale.append("docs/brand/\(name)" + (fm.fileExists(atPath: brandDir.appendingPathComponent(name).path) ? "" : " (missing)"))
}
for name in leftOver { stale.append("docs/brand/\(name) (no longer made)") }
try? fm.removeItem(at: output)
if stale.isEmpty {
    print("brand-assets: the \(made.count) files in docs/brand are up to date")
    exit(0)
}
FileHandle.standardError.write(Data("brand-assets: out of date (run `swift scripts/tools/brand-assets.swift`):\n".utf8))
for s in stale { FileHandle.standardError.write(Data("  \(s)\n".utf8)) }
exit(1)
