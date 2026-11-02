// Draws the Quire app icon (spec §5.42) from docs/design/tokens.json: the `ss.sparrow` glyph's vector path, the
// `layout.appIcon` metrics and the `accentFill` / `accent` / `ink` colours. Nothing is drawn by hand elsewhere.
//
// Usage: swift scripts/tools/app-icon.swift [--root <repo>] [--preview <png>]
//
// Writes:
//   Resources/AppIcon.icns   the icon macOS 15 shows: the default face on the system's 824/1024 squircle grid with
//                            its drop shadow, built by `iconutil` from a temporary .iconset (16 to 1024 px).
//   Resources/AppIcon.icon/  an Icon Composer document (icon.json and SVG layers) that `actool` compiles into the
//                            asset catalog for macOS 26 and later. A macOS AppIcon.appiconset cannot carry dark or
//                            tinted images (actool reports them as unassigned children); this document can, and
//                            there the system masks the squircle and draws the default, dark and tinted
//                            appearances, tinting the mark alone.
//   --preview <png>          optional: default, dark and tinted side by side at 256 px, for review.
//
// Plain Foundation, AppKit and ImageIO, no packages. The SVG path parser below handles the commands the token
// file's glyphs use (M L H V C A Z, absolute and relative) and fails loudly on anything else.
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("app-icon: \(message)\n".utf8))
    exit(2)
}

// MARK: - Arguments and tokens

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}
let rootOption = option("--root")
let previewPath = option("--preview")
if let unknown = arguments.first { fail("unknown argument \(unknown). Usage: swift scripts/tools/app-icon.swift [--root <repo>] [--preview <png>]") }

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
guard let tokenData = FileManager.default.contents(atPath: root.appendingPathComponent("docs/design/tokens.json").path),
      let tokens = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any] else { fail("cannot read docs/design/tokens.json") }

func lookup(_ path: String) -> Any {
    var node: Any = tokens
    for key in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
        guard let object = node as? [String: Any], let next = object[key] else { fail("tokens.json has no \(path)") }
        node = next
    }
    return node
}
func number(_ path: String) -> CGFloat {
    guard let value = lookup(path) as? NSNumber else { fail("\(path) is not a number") }
    return CGFloat(value.doubleValue)
}
func string(_ path: String) -> String {
    guard let value = lookup(path) as? String else { fail("\(path) is not a string") }
    return value
}
func glyphPath(_ name: String) -> String {
    guard let glyphs = tokens["customGlyphs"] as? [String: Any], let glyph = glyphs[name] as? [String: Any],
          let paths = glyph["paths"] as? [String], paths.count == 1, (glyph["grid"] as? NSNumber)?.intValue == 24 else {
        fail("customGlyphs.\(name) must be one path on the 24 grid")
    }
    return paths[0]
}

/// One colour as the icon uses it: hex for the SVG layers, sRGB components for drawing.
struct Ink {
    let hex: String
    let red: CGFloat, green: CGFloat, blue: CGFloat
    init(_ hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { fail("colour \(hex) is not #RRGGBB") }
        self.hex = "#" + digits.uppercased()
        red = CGFloat((value >> 16) & 0xFF) / 255
        green = CGFloat((value >> 8) & 0xFF) / 255
        blue = CGFloat(value & 0xFF) / 255
    }
    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// The spec's three appearances. The tinted one is the mark alone, in white, for the system to tint.
struct Appearance {
    let name: String
    let faceTop: Ink?
    let faceBottom: Ink?
    let laid: Ink?
    let mark: Ink
    let showsStamp: Bool
}

let metrics = (
    laidAlpha: number("layout.appIcon.laidLineAlpha"),
    laidStep: number("layout.appIcon.laidLineStep"),
    stampInset: number("layout.appIcon.stampInset"),
    stampAlpha: number("layout.appIcon.stampAlpha"),
    markWidth: number("layout.appIcon.markWidth"),
    markOffsetX: number("layout.appIcon.markOffsetX"),
    markOffsetY: number("layout.appIcon.markOffsetY")
)
let lightAppearance = Appearance(name: "default", faceTop: Ink(string("layout.appIcon.faceTop")),
                                 faceBottom: Ink(string("layout.appIcon.faceBottom")), laid: Ink(string("color.ink.light")),
                                 mark: Ink(string("color.accentFill.light")), showsStamp: true)
let darkAppearance = Appearance(name: "dark", faceTop: Ink(string("layout.appIcon.darkFaceTop")),
                                faceBottom: Ink(string("layout.appIcon.darkFaceBottom")), laid: Ink(string("color.ink.dark")),
                                mark: Ink(string("color.accent.dark")), showsStamp: true)
let tintedAppearance = Appearance(name: "tinted", faceTop: nil, faceBottom: nil, laid: nil, mark: Ink("#FFFFFF"), showsStamp: false)
let sparrowData = glyphPath(string("icon.brand"))

/// The squircle's corner radius as a fraction of its side, the system's (185.4 of 824). The stamp rule's corners
/// are concentric with it.
let cornerFraction: CGFloat = 0.225
/// The stamp rule's width as a fraction of the face: one point on a 64 pt icon, as the specimen draws it.
let stampWidthFraction: CGFloat = 1.0 / 64

// MARK: - SVG path data

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

// MARK: - Geometry (y down, in pixels)

/// A rounded square with continuous corners, the shape macOS masks icons with: each corner starts 1.6 radii from
/// it, eases in along a cubic, turns through a 36° arc and eases out again (corner smoothing 0.6).
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let smoothing: CGFloat = 0.6
    let r = min(radius, rect.width / 2 / (1 + smoothing))
    let p = (1 + smoothing) * r
    let arcMeasure = 90 * (1 - smoothing) * CGFloat.pi / 180
    let arcSection = sin(arcMeasure / 2) * r * 2.0.squareRoot()
    let alpha = (CGFloat.pi / 2 - arcMeasure) / 2
    let p3ToP4 = r * tan(alpha / 2)
    let beta = CGFloat.pi / 4 * smoothing
    let c = p3ToP4 * cos(beta)
    let d = c * tan(beta)
    let b = (p - arcSection - c - d) / 3
    let a = 2 * b
    let path = CGMutablePath()
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    // Each corner in its own frame: `along` runs with the edge that leads into it, `across` toward the next edge.
    func corner(_ origin: CGPoint, _ along: CGVector, _ across: CGVector) {
        func at(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + along.dx * u + across.dx * v, y: origin.y + along.dy * u + across.dy * v)
        }
        // From the start point (p before the corner along the edge) to the start of the arc.
        path.addCurve(to: at(-p + a + b + c, d), control1: at(-p + a, 0), control2: at(-p + a + b, 0))
        // The arc's chord runs at 45°; its centre sits r inside both edges.
        let arcEnd = at(-p + a + b + c + arcSection, d + arcSection)
        let centre = at(-r, r)
        let startAngle = atan2(at(-p + a + b + c, d).y - centre.y, at(-p + a + b + c, d).x - centre.x)
        let endAngle = atan2(arcEnd.y - centre.y, arcEnd.x - centre.x)
        var sweep = endAngle - startAngle
        if sweep > .pi { sweep -= 2 * .pi }
        if sweep < -.pi { sweep += 2 * .pi }
        path.addArc(center: centre, radius: r, startAngle: startAngle, endAngle: startAngle + sweep, clockwise: sweep < 0)
        // Out of the arc and onto the next edge, p past the corner: the first cubic mirrored.
        path.addCurve(to: at(0, p), control1: at(0, p - a - b), control2: at(0, p - a))
    }
    path.move(to: CGPoint(x: minX + p, y: minY))
    path.addLine(to: CGPoint(x: maxX - p, y: minY))
    corner(CGPoint(x: maxX, y: minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1))
    path.addLine(to: CGPoint(x: maxX, y: maxY - p))
    corner(CGPoint(x: maxX, y: maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0))
    path.addLine(to: CGPoint(x: minX + p, y: maxY))
    corner(CGPoint(x: minX, y: maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1))
    path.addLine(to: CGPoint(x: minX, y: minY + p))
    corner(CGPoint(x: minX, y: minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0))
    path.closeSubpath()
    return path
}

/// The mark's transform from its 24-unit grid onto a face: `markWidth` of the face wide, centred, then nudged by
/// the spec's optical offset (left and up for negative values).
func markTransform(face: CGRect) -> CGAffineTransform {
    let width = metrics.markWidth * face.width
    let scale = width / 24
    let originX = face.midX - width / 2 + metrics.markOffsetX * face.width
    let originY = face.midY - width / 2 + metrics.markOffsetY * face.height
    return CGAffineTransform(translationX: originX, y: originY).scaledBy(x: scale, y: scale)
}

// MARK: - Raster (the .icns)

/// One icon image `size` pixels square: the face on the system grid (824 of 1024, centred) with the template's
/// drop shadow, then the laid lines, the stamp rule and the mark.
func renderIcon(size: Int, appearance: Appearance) -> CGImage {
    let s = CGFloat(size)
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot make a \(size) px context") }
    // Draw y down, as the path data and the spec's offsets are written.
    context.translateBy(x: 0, y: s)
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    let inset = s * 100 / 1024
    let face = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = squircle(face, radius: cornerFraction * face.width)

    if let top = appearance.faceTop, let bottom = appearance.faceBottom {
        // The macOS template's shadow (y 10, blur 10 of 1024), so the icon sits on the Dock like its neighbours.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 10 / 1024,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
        context.addPath(shape)
        context.setFillColor(bottom.cgColor())
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [top.cgColor(), bottom.cgColor()] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: face.midX, y: face.minY), end: CGPoint(x: face.midX, y: face.maxY), options: [])
        // Laid lines: too fine to resolve below about six pixels apart, where they would only tint the face.
        if let laid = appearance.laid {
            let step = metrics.laidStep * face.width
            if step >= 6 {
                context.setFillColor(laid.cgColor(alpha: metrics.laidAlpha))
                let thickness = max(1, step / 8)
                var y = face.minY + step
                while y < face.maxY {
                    context.fill(CGRect(x: face.minX, y: (y - thickness / 2).rounded(), width: face.width, height: thickness))
                    y += step
                }
            }
        }
        context.restoreGState()
    }

    if appearance.showsStamp {
        // Not rounded up to a pixel: at 16 and 32 px a whole pixel would outweigh the mark it frames.
        let lineWidth = stampWidthFraction * face.width
        let stampInset = metrics.stampInset * face.width + lineWidth / 2
        let stampRect = face.insetBy(dx: stampInset, dy: stampInset)
        context.addPath(squircle(stampRect, radius: max(0, cornerFraction * face.width - stampInset)))
        context.setStrokeColor(appearance.mark.cgColor(alpha: metrics.stampAlpha))
        context.setLineWidth(lineWidth)
        context.strokePath()
    }

    var transform = markTransform(face: face)
    guard let mark = parsePath(sparrowData).copy(using: &transform) else { fail("cannot place the mark") }
    context.addPath(mark)
    context.setFillColor(appearance.mark.cgColor())
    context.fillPath(using: .evenOdd)

    guard let image = context.makeImage() else { fail("cannot finish the \(size) px image") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

func run(_ tool: String, _ args: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    do { try process.run() } catch { fail("cannot run \(tool): \(error)") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(tool) \(args.joined(separator: " ")) failed (\(process.terminationStatus))") }
}

let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("app-icon-\(UUID().uuidString)")
let iconset = scratch.appendingPathComponent("AppIcon.iconset")
do { try fm.createDirectory(at: iconset, withIntermediateDirectories: true) } catch { fail("cannot make \(iconset.path): \(error)") }
defer { try? fm.removeItem(at: scratch) }

var rendered: [Int: CGImage] = [:]
func image(_ size: Int) -> CGImage {
    if let cached = rendered[size] { return cached }
    let made = renderIcon(size: size, appearance: lightAppearance)
    rendered[size] = made
    return made
}
for points in [16, 32, 128, 256, 512] {
    writePNG(image(points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(image(points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
run("/usr/bin/iconutil", ["--convert", "icns", "--output", icns.path, iconset.path])
print("app-icon: wrote Resources/AppIcon.icns")

// MARK: - Icon Composer document (macOS 26 and later)

/// A number written the same way on every run, so the document only changes when the tokens do.
func fixed(_ value: CGFloat) -> String {
    let text = String(format: "%.3f", Double(value))
    var trimmed = text
    while trimmed.hasSuffix("0") { trimmed.removeLast() }
    if trimmed.hasSuffix(".") { trimmed.removeLast() }
    return trimmed == "-0" ? "0" : trimmed
}

func srgb(_ ink: Ink) -> String {
    "srgb:" + [ink.red, ink.green, ink.blue, 1].map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
}

/// The document's canvas is the whole squircle: the system masks it and adds its own margin and shadow.
let canvas: CGFloat = 1024
let canvasRect = CGRect(x: 0, y: 0, width: canvas, height: canvas)

func svg(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\(body)</svg>\n"
}

func faceSVG(_ appearance: Appearance) -> String {
    guard let top = appearance.faceTop, let bottom = appearance.faceBottom else { fail("\(appearance.name) has no face") }
    return svg("<defs><linearGradient id=\"face\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(top.hex)\"/>"
        + "<stop offset=\"1\" stop-color=\"\(bottom.hex)\"/></linearGradient></defs><rect width=\"1024\" height=\"1024\" fill=\"url(#face)\"/>")
}

func laidSVG(_ appearance: Appearance) -> String {
    guard let laid = appearance.laid else { fail("\(appearance.name) has no laid lines") }
    let step = metrics.laidStep * canvas
    var rows: [String] = []
    var y = step
    while y < canvas {
        rows.append("<rect x=\"0\" y=\"\(fixed(y - step / 16))\" width=\"1024\" height=\"\(fixed(step / 8))\"/>")
        y += step
    }
    return svg("<g fill=\"\(laid.hex)\" fill-opacity=\"\(fixed(metrics.laidAlpha))\">" + rows.joined() + "</g>")
}

func stampSVG(_ appearance: Appearance) -> String {
    let lineWidth = stampWidthFraction * canvas
    let inset = metrics.stampInset * canvas + lineWidth / 2
    let rect = canvasRect.insetBy(dx: inset, dy: inset)
    let radius = cornerFraction * canvas - inset
    return svg("<rect x=\"\(fixed(rect.minX))\" y=\"\(fixed(rect.minY))\" width=\"\(fixed(rect.width))\" height=\"\(fixed(rect.height))\" "
        + "rx=\"\(fixed(radius))\" fill=\"none\" stroke=\"\(appearance.mark.hex)\" stroke-opacity=\"\(fixed(metrics.stampAlpha))\" "
        + "stroke-width=\"\(fixed(lineWidth))\"/>")
}

func markSVG(_ appearance: Appearance) -> String {
    let t = markTransform(face: canvasRect)
    return svg("<path transform=\"matrix(\(fixed(t.a)) 0 0 \(fixed(t.d)) \(fixed(t.tx)) \(fixed(t.ty)))\" fill=\"\(appearance.mark.hex)\" "
        + "fill-rule=\"evenodd\" d=\"\(sparrowData)\"/>")
}

/// A layer shown only in the listed appearances ("default" is the light one).
func layer(_ name: String, shownIn shown: Set<String>, opacity: CGFloat? = nil) -> String {
    let hidden = ["default", "dark", "tinted"].map { appearance -> String in
        let value = shown.contains(appearance) ? "false" : "true"
        return appearance == "default" ? "        { \"value\" : \(value) }" : "        { \"appearance\" : \"\(appearance)\", \"value\" : \(value) }"
    }
    var lines = [
        "      {",
        "      \"glass\" : false,",
        "      \"hidden-specializations\" : [",
        hidden.joined(separator: ",\n"),
        "      ],",
        "      \"image-name\" : \"\(name).svg\",",
        "      \"name\" : \"\(name)\"" + (opacity == nil ? "" : ","),
    ]
    if let opacity { lines.append("      \"opacity\" : \(fixed(opacity))") }
    lines.append("      }")
    return lines.joined(separator: "\n")
}

/// A flat group: the icon is printed paper and ink, so no glass, specular highlight, translucency or shadow of
/// its own inside the squircle.
func group(_ name: String, _ layers: [String]) -> String {
    """
        {
          "layers" : [
    \(layers.joined(separator: ",\n"))
          ],
          "name" : "\(name)",
          "shadow" : { "kind" : "none", "opacity" : 0 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0 }
        }
    """
}

let document = root.appendingPathComponent("Resources/AppIcon.icon")
let assets = document.appendingPathComponent("Assets")
try? fm.removeItem(at: document)
do { try fm.createDirectory(at: assets, withIntermediateDirectories: true) } catch { fail("cannot make \(assets.path): \(error)") }
let layerFiles: [(String, String)] = [
    ("mark", markSVG(lightAppearance)), ("mark-dark", markSVG(darkAppearance)), ("mark-tinted", markSVG(tintedAppearance)),
    ("stamp", stampSVG(lightAppearance)), ("stamp-dark", stampSVG(darkAppearance)),
    ("laid", laidSVG(lightAppearance)), ("laid-dark", laidSVG(darkAppearance)),
    ("face", faceSVG(lightAppearance)), ("face-dark", faceSVG(darkAppearance)),
]
for (name, content) in layerFiles {
    do { try Data(content.utf8).write(to: assets.appendingPathComponent("\(name).svg")) } catch { fail("cannot write \(name).svg: \(error)") }
}
// Front to back. The fill under everything is the face's top colour, so an edge the system antialiases never
// shows a third colour; the tinted appearance replaces it with the system's ground.
let iconJSON = """
{
  "fill-specializations" : [
    { "value" : { "solid" : "\(srgb(lightAppearance.faceTop!))" } },
    { "appearance" : "dark", "value" : { "solid" : "\(srgb(darkAppearance.faceTop!))" } }
  ],
  "groups" : [
\(group("Mark", [layer("mark", shownIn: ["default"]), layer("mark-dark", shownIn: ["dark"]), layer("mark-tinted", shownIn: ["tinted"])])),
\(group("Paper", [layer("stamp", shownIn: ["default"]), layer("stamp-dark", shownIn: ["dark"]), layer("laid", shownIn: ["default"]),
                  layer("laid-dark", shownIn: ["dark"]), layer("face", shownIn: ["default"]), layer("face-dark", shownIn: ["dark"])]))
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}

"""
do { try Data(iconJSON.utf8).write(to: document.appendingPathComponent("icon.json")) } catch { fail("cannot write icon.json: \(error)") }
print("app-icon: wrote Resources/AppIcon.icon")

// MARK: - Preview

if let previewPath {
    let size = 256
    let images = [lightAppearance, darkAppearance, tintedAppearance].map { renderIcon(size: size, appearance: $0) }
    let gap = 24
    let width = size * images.count + gap * (images.count + 1)
    let height = size + 2 * gap
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("cannot make the preview")
    }
    // The specimen's desk, with the tinted mark on a stand-in for the system's tinted ground.
    context.setFillColor(Ink("#E3DFD7").cgColor())
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (index, image) in images.enumerated() {
        let x = gap + index * (size + gap)
        let rect = CGRect(x: x, y: gap, width: size, height: size)
        if index == 2 {
            let inset = CGFloat(size) * 100 / 1024
            let face = rect.insetBy(dx: inset, dy: inset)
            context.addPath(squircle(face, radius: cornerFraction * face.width))
            context.setFillColor(Ink("#4A4741").cgColor())
            context.fillPath()
        }
        context.draw(image, in: rect)
    }
    guard let preview = context.makeImage() else { fail("cannot finish the preview") }
    writePNG(preview, to: URL(fileURLWithPath: previewPath))
    print("app-icon: wrote \(previewPath)")
}
