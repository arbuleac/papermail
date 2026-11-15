// Draws the app icon (spec §5.42) from docs/design/tokens.json alone: the brand mark's two paths
// (`customGlyphs[icon.brand]`, the envelope's front then its flap) and the `layout.appIcon` geometry and colours.
// Nothing is drawn by hand elsewhere.
//
// Usage: swift scripts/tools/app-icon.swift [--check] [--root <repo>] [--preview <png>]
//
// Writes:
//   Resources/AppIcon.icon/  an Icon Composer document (icon.json and one SVG layer per part) that `actool` compiles
//                            into the asset catalog for macOS 26 and later. The ground is the document's fill (default
//                            and dark); the envelope is one glass group of two layers, the flap above the front, each
//                            filled with its own top-to-bottom gradient and specialized for dark and tinted. The system
//                            masks the squircle and adds Liquid Glass, specular edges and shadow: nothing of the kind is
//                            drawn into the layers. A macOS AppIcon.appiconset cannot carry dark or tinted images
//                            (actool reports them as unassigned children); this document can.
//   Resources/AppIcon.icns   the default appearance on the macOS 15 template (the body on the 1024 canvas, continuous
//                            corners, the template's drop shadow), built by `iconutil` from a temporary .iconset, 16 to
//                            1024 px. 16 and 32 px are pixel-fitted masters (`layout.appIcon.fit16`, `fit32`): the body
//                            on whole pixels and the envelope drawn on that size's own pixel grid.
//   --check                  writes nothing in the repository: renders into a temporary folder, compares both outputs
//                            byte for byte, and exits 1 listing every file that is missing, stale or no longer made.
//   --preview <png>          optional, for review: the document's six system appearances rendered by Xcode's `ictool`
//                            (when Xcode is installed), the .icns sizes, the icon in a light Dock at 64 and 32 px beside
//                            Apple Mail's, which App Review 5.2.5 says it must not resemble, and in a dark Dock on its own.
//                            NSWorkspace hands back Mail's light icon under every appearance, so the preview cannot
//                            compare the dark, tinted or clear looks; those are checked by hand against Mail itself.
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
let check = arguments.contains("--check")
arguments.removeAll { $0 == "--check" }
let rootOption = option("--root")
let previewPath = option("--preview")
if let unknown = arguments.first {
    fail("unknown argument \(unknown). Usage: swift scripts/tools/app-icon.swift [--check] [--root <repo>] [--preview <png>]")
}

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
func strings(_ path: String, count: Int) -> [String] {
    guard let value = lookup(path) as? [String], value.count == count else { fail("\(path) must be \(count) strings") }
    return value
}

/// The brand mark: its grid and its two paths, the front then the flap (glyph names hold a dot, so this reads the glyph
/// table directly rather than through `lookup`).
guard let brandName = lookup("icon.brand") as? String, let glyphs = tokens["customGlyphs"] as? [String: Any],
      let brandGlyph = glyphs[brandName] as? [String: Any], let partData = brandGlyph["paths"] as? [String], partData.count == 2,
      let brandGrid = (brandGlyph["grid"] as? NSNumber)?.doubleValue, (brandGlyph["stroke"] as? NSNumber)?.doubleValue == 0 else {
    fail("customGlyphs[icon.brand] must be a filled glyph with two paths, the front then the flap")
}

/// One colour as the icon uses it: hex for the SVG layers, sRGB components for drawing and for icon.json.
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

/// A top-to-bottom pair of stops.
struct Ramp {
    let top: Ink, bottom: Ink
}
func ramp(_ path: String) -> Ramp {
    let pair = strings(path, count: 2)
    return Ramp(top: Ink(pair[0]), bottom: Ink(pair[1]))
}

/// One appearance's colours: the ground's ramp and the envelope's two parts'.
struct Look {
    let ground: Ramp, front: Ramp, flap: Ramp
}
let defaultLook = Look(ground: ramp("layout.appIcon.ground"), front: ramp("layout.appIcon.front"), flap: ramp("layout.appIcon.flap"))
let darkLook = Look(ground: ramp("layout.appIcon.groundDark"), front: ramp("layout.appIcon.frontDark"), flap: ramp("layout.appIcon.flapDark"))
/// The pixel-fitted sizes take deeper parts on the default ground, so the white crease keeps its contrast there.
let smallLook = Look(ground: defaultLook.ground, front: ramp("layout.appIcon.frontSmall"), flap: ramp("layout.appIcon.flapSmall"))
let white = Ink("#FFFFFF")
let monoFront = number("layout.appIcon.monoFront")
let monoFlap = number("layout.appIcon.monoFlap")

let canvas = number("layout.appIcon.canvas")
let body = number("layout.appIcon.body")
let markRect = CGRect(x: number("layout.appIcon.markX"), y: number("layout.appIcon.markY"),
                      width: number("layout.appIcon.markSize"), height: number("layout.appIcon.markSize"))
/// The macOS 15 template: the body's continuous corners and the drop shadow under it, in canvas units.
let corner = number("layout.appIcon.corner")
let smoothing = number("layout.appIcon.smoothing")
let shadow = (y: number("layout.appIcon.shadowY"), blur: number("layout.appIcon.shadowBlur"), alpha: number("layout.appIcon.shadowAlpha"))

/// A pixel-fitted small master: its body in canvas units (a whole number of pixels, centred, so the tile's edge is a
/// whole pixel rather than a half-covered ring) and the envelope's front and flap in that size's pixels.
struct Fit {
    let body: CGFloat
    let parts: [String]
}
func fit(_ size: Int) -> Fit {
    let p = "layout.appIcon.fit\(size)."
    return Fit(body: number(p + "body"), parts: strings(p + "paths", count: 2))
}
let fits: [Int: Fit] = [16: fit(16), 32: fit(32)]

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


// MARK: - Geometry (y down, in canvas units)

/// The mark's transform from its glyph grid onto the canvas: the `markSize` square at (markX, markY).
let markTransform = CGAffineTransform(a: markRect.width / CGFloat(brandGrid), b: 0, c: 0, d: markRect.height / CGFloat(brandGrid),
                                      tx: markRect.minX, ty: markRect.minY)

func placed(_ data: String, _ transform: CGAffineTransform) -> CGPath {
    var transform = transform
    guard let path = parsePath(data).copy(using: &transform) else { fail("cannot place the mark") }
    return path
}

/// The front and the flap on the canvas, from the glyph's paths.
let masterParts: [CGPath] = partData.map { placed($0, markTransform) }

/// A pixel-fitted master's front and flap, from its own pixels onto the canvas.
func fittedParts(_ fit: Fit, size: Int) -> [CGPath] {
    let scale = canvas / CGFloat(size)
    return fit.parts.map { placed($0, CGAffineTransform(scaleX: scale, y: scale)) }
}

/// A rounded square with continuous corners, the shape the macOS 15 template masks icons with: each corner starts
/// (1 + smoothing) radii from it, eases in along a cubic, turns through an arc and eases out again.
func squircle(_ rect: CGRect, radius: CGFloat, smoothing: CGFloat) -> CGPath {
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

// MARK: - Raster (the .icns)

func sRGBContext(_ width: Int, _ height: Int) -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot make a \(width) × \(height) px context") }
    return context
}

/// One icon image `size` pixels square on the macOS 15 template: the body with the template's drop shadow, its

/// Fills `shape` with `ramp`, top to bottom over the shape's own bounds: the way Icon Composer maps a layer's gradient,
/// so the raster and the system's render light the parts from the same side.
func fill(_ context: CGContext, _ shape: CGPath, _ ramp: Ramp, alpha: CGFloat = 1) {
    let bounds = shape.boundingBoxOfPath
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [ramp.top.cgColor(alpha: alpha), ramp.bottom.cgColor(alpha: alpha)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.minY), end: CGPoint(x: bounds.midX, y: bounds.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

/// One icon image `size` pixels square on the macOS 15 template: the body with the template's drop shadow, its ground,
/// then the front and the flap. 16 and 32 px draw their pixel-fitted masters, body included.
func renderIcon(size: Int, look: Look) -> CGImage {
    let s = CGFloat(size)
    let context = sRGBContext(size, size)
    // Draw y down, in canvas units, as the path data and the tokens are written.
    context.translateBy(x: 0, y: s)
    context.scaleBy(x: s / canvas, y: -s / canvas)
    let side = fits[size]?.body ?? body
    let inset = (canvas - side) / 2
    let face = CGRect(x: inset, y: inset, width: side, height: side)
    let shape = squircle(face, radius: corner * side, smoothing: smoothing)

    // The template's shadow, so the icon sits on a macOS 15 Dock like its neighbours. Shadow offsets ignore the
    // transform: they are in pixels, y up.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -shadow.y * s / canvas), blur: shadow.blur * s / canvas,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: shadow.alpha))
    context.addPath(shape)
    context.setFillColor(look.ground.bottom.cgColor())
    context.fillPath()
    context.restoreGState()

    // The ground runs over the body; the parts stay inside it (the mark clears its edge), so nothing else is clipped.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [look.ground.top.cgColor(), look.ground.bottom.cgColor()] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: face.midX, y: face.minY), end: CGPoint(x: face.midX, y: face.maxY), options: [])
    context.restoreGState()

    let parts = fits[size].map { fittedParts($0, size: size) } ?? masterParts
    fill(context, parts[0], look.front)
    fill(context, parts[1], look.flap)
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
    process.standardOutput = FileHandle.nullDevice
    do { try process.run() } catch { fail("cannot run \(tool): \(error)") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(tool) \(args.joined(separator: " ")) failed (\(process.terminationStatus))") }
}

let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("app-icon-\(UUID().uuidString)")
let iconset = scratch.appendingPathComponent("AppIcon.iconset")
do { try fm.createDirectory(at: iconset, withIntermediateDirectories: true) } catch { fail("cannot make \(iconset.path): \(error)") }
defer { try? fm.removeItem(at: scratch) }
/// Where the outputs go: the repository, or under --check a stand-in for it in the scratch folder.
let output = check ? scratch.appendingPathComponent("check") : root

var rendered: [Int: CGImage] = [:]
func image(_ size: Int) -> CGImage {
    if let cached = rendered[size] { return cached }
    let made = renderIcon(size: size, look: fits[size] == nil ? defaultLook : smallLook)
    rendered[size] = made
    return made
}
for points in [16, 32, 128, 256, 512] {
    writePNG(image(points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(image(points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let icns = output.appendingPathComponent("Resources/AppIcon.icns")
do { try fm.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { fail("cannot make \(icns.path): \(error)") }
run("/usr/bin/iconutil", ["--convert", "icns", "--output", icns.path, iconset.path])
if !check { print("app-icon: wrote Resources/AppIcon.icns") }

// MARK: - Icon Composer document (macOS 26 and later)

/// A number written the same way on every run, so the document only changes when the tokens do.
func fixed(_ value: CGFloat) -> String {
    let text = String(format: "%.4f", Double(value))
    var trimmed = text
    while trimmed.hasSuffix("0") { trimmed.removeLast() }
    if trimmed.hasSuffix(".") { trimmed.removeLast() }
    return trimmed == "-0" ? "0" : trimmed
}

func srgb(_ ink: Ink) -> String {
    "srgb:" + [ink.red, ink.green, ink.blue, 1].map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
}

/// icon.json, written in Icon Composer's own style (sorted keys, ` : `), so a run with unchanged tokens changes nothing.
indirect enum JSONValue {
    case string(String), raw(String), array([JSONValue]), object([(String, JSONValue)])

    func text(_ indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .string(let s): return "\"\(s)\""
        case .raw(let s): return s
        case .array(let items):
            return "[\n" + items.map { inner + $0.text(inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .object(let members):
            let sorted = members.sorted { $0.0 < $1.0 }
            return "{\n" + sorted.map { "\(inner)\"\($0.0)\" : \($0.1.text(inner))" }.joined(separator: ",\n") + "\n\(indent)}"
        }
    }
}

func specializations(_ values: [(appearance: String?, value: JSONValue)]) -> JSONValue {
    .array(values.map { item in
        var members: [(String, JSONValue)] = [("value", item.value)]
        if let appearance = item.appearance { members.append(("appearance", .string(appearance))) }
        return .object(members)
    })
}

func solid(_ ink: Ink) -> JSONValue { .object([("solid", .string(srgb(ink)))]) }

/// A top-to-bottom gradient fill. On a layer Icon Composer maps it onto the layer's own bounds, as the raster does.
func linear(_ ramp: Ramp) -> JSONValue {
    .object([
        ("linear-gradient", .array([.string(srgb(ramp.top)), .string(srgb(ramp.bottom))])),
        ("orientation", .object([("start", .object([("x", .raw("0.5")), ("y", .raw("0"))])),
                                 ("stop", .object([("x", .raw("0.5")), ("y", .raw("1"))]))])),
    ])
}

/// One part as a glass layer. Its fill is the default gradient, specialized for dark and, white, for tinted; a part
/// below full white in tinted keeps its value under the other one there and in the clear looks.
func partLayer(name: String, file: String, defaultRamp: Ramp, darkRamp: Ramp, monoOpacity: CGFloat) -> JSONValue {
    var layer: [(String, JSONValue)] = [
        ("fill-specializations", specializations([(nil, linear(defaultRamp)), ("dark", linear(darkRamp)), ("tinted", solid(white))])),
        ("glass", .raw("true")),
        ("image-name", .string(file)),
        ("name", .string(name)),
    ]
    if monoOpacity != 1 {
        layer.append(("opacity-specializations", specializations([(nil, .raw("1")), ("tinted", .raw(fixed(monoOpacity)))])))
    }
    return .object(layer)
}

/// A layer: one part on the canvas grid, in its default gradient (the document's fill replaces it; the SVG says on its
/// own what the layer is). The viewBox maps the body onto the document's canvas, which is the body alone (the system
/// adds the margin, the mask and the shadow).
func layerSVG(_ data: String, _ ramp: Ramp) -> String {
    let inset = (canvas - body) / 2
    let t = markTransform
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(fixed(canvas))\" height=\"\(fixed(canvas))\" "
        + "viewBox=\"\(fixed(inset)) \(fixed(inset)) \(fixed(body)) \(fixed(body))\">"
        + "<defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(ramp.top.hex)\"/>"
        + "<stop offset=\"1\" stop-color=\"\(ramp.bottom.hex)\"/></linearGradient></defs>"
        + "<path transform=\"matrix(\(fixed(t.a)) 0 0 \(fixed(t.d)) \(fixed(t.tx)) \(fixed(t.ty)))\" fill=\"url(#g)\" d=\"\(data)\"/></svg>\n"
}

let document = output.appendingPathComponent("Resources/AppIcon.icon")
let assets = document.appendingPathComponent("Assets")
try? fm.removeItem(at: document)
do { try fm.createDirectory(at: assets, withIntermediateDirectories: true) } catch { fail("cannot make \(assets.path): \(error)") }
for (name, data, ramp) in [("front", partData[0], defaultLook.front), ("flap", partData[1], defaultLook.flap)] {
    do { try Data(layerSVG(data, ramp).utf8).write(to: assets.appendingPathComponent("\(name).svg")) } catch { fail("cannot write \(name).svg: \(error)") }
}
// One group, so the envelope is one piece of glass; its layers run front to back, the flap above the front. They never
// overlap: the crease between them is the ground, in every appearance.
let iconJSON = JSONValue.object([
    ("fill-specializations", specializations([(nil, linear(defaultLook.ground)), ("dark", linear(darkLook.ground))])),
    ("groups", .array([.object([
        ("layers", .array([
            partLayer(name: "Flap", file: "flap.svg", defaultRamp: defaultLook.flap, darkRamp: darkLook.flap, monoOpacity: monoFlap),
            partLayer(name: "Front", file: "front.svg", defaultRamp: defaultLook.front, darkRamp: darkLook.front, monoOpacity: monoFront),
        ])),
        ("name", .string("Envelope")),
    ])])),
    ("supported-platforms", .object([("squares", .array([.string("macOS")]))])),
])
do { try Data((iconJSON.text() + "\n").utf8).write(to: document.appendingPathComponent("icon.json")) } catch { fail("cannot write icon.json: \(error)") }
if !check { print("app-icon: wrote Resources/AppIcon.icon") }

// MARK: - Preview

/// Icon Composer's renderer, which draws the document as the system does (Liquid Glass and all). It ships inside
/// Xcode; without it the preview shows the raster alone.
func iconComposerTool() -> String? {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let developer = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let tool = URL(fileURLWithPath: developer).deletingLastPathComponent()
        .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool").path
    return fm.isExecutableFile(atPath: tool) ? tool : nil
}

func systemRender(_ tool: String, rendition: String, size: Int) -> CGImage? {
    let out = scratch.appendingPathComponent("\(rendition)-\(size).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = [document.path, "--export-image", "--output-file", out.path, "--platform", "macOS", "--rendition", rendition,
                         "--width", "\(size)", "--height", "\(size)", "--scale", "1"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0, let source = CGImageSourceCreateWithURL(out as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

if let previewPath {
    let cell = 176, gap = 24, labelHeight = 22, rowGap = 40
    let width = 6 * cell + 7 * gap
    let dockHeight = 104
    let height = gap + 2 * (labelHeight + cell + rowGap) + labelHeight + 2 * dockHeight + gap + gap
    let context = sRGBContext(width, height)
    // Work y down, as a page reads.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    let desk = Ink("#EEF0F4"), darkDesk = Ink("#1E1F24")
    context.setFillColor(desk.cgColor())
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func label(_ text: String, x: CGFloat, y: CGFloat, ink: Ink = Ink("#3C4352"), size: CGFloat = 11, bold: Bool = false) {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                                                      .foregroundColor: NSColor(cgColor: ink.cgColor())!])
            .draw(at: NSPoint(x: x, y: y))
    }
    /// Images arrive y up; drawn into this y-down space they would be upside down, so flip each in place.
    func draw(_ image: CGImage, in rect: CGRect, nearest: Bool = false) {
        context.saveGState()
        context.interpolationQuality = nearest ? .none : .high
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
    func tile(_ rect: CGRect, _ ink: Ink) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.setFillColor(ink.cgColor())
        context.fillPath()
    }
    var y = CGFloat(gap)
    let tool = iconComposerTool()
    label("Resources/AppIcon.icon as the system draws it (ictool)", x: CGFloat(gap), y: y, bold: true)
    y += CGFloat(labelHeight)
    let renditions = [("Default", "Default", false), ("Dark", "Dark", true), ("TintedLight", "Tinted light", false),
                      ("TintedDark", "Tinted dark", true), ("ClearLight", "Clear light", false), ("ClearDark", "Clear dark", true)]
    for (index, (rendition, name, dark)) in renditions.enumerated() {
        let x = CGFloat(gap + index * (cell + gap))
        tile(CGRect(x: x, y: y, width: CGFloat(cell), height: CGFloat(cell)), dark ? darkDesk : Ink("#DCE0E8"))
        let inset = CGFloat(cell) * 0.12
        if let tool, let image = systemRender(tool, rendition: rendition, size: 2 * cell) {
            draw(image, in: CGRect(x: x + inset, y: y + inset, width: CGFloat(cell) - 2 * inset, height: CGFloat(cell) - 2 * inset))
        } else {
            label("ictool not found", x: x + 12, y: y + 12)
        }
        label(name, x: x, y: y + CGFloat(cell) + 4)
    }
    y += CGFloat(cell + rowGap)
    label("Resources/AppIcon.icns (macOS 15): 1024 px shown at \(cell), then 128, 64, 32 and 16 px at 1×; 32 and 16 px enlarged", x: CGFloat(gap), y: y, bold: true)
    y += CGFloat(labelHeight)
    draw(image(1024), in: CGRect(x: CGFloat(gap), y: y, width: CGFloat(cell), height: CGFloat(cell)))
    var x = CGFloat(gap + cell + gap)
    for size in [128, 64, 32, 16] {
        draw(image(size), in: CGRect(x: x, y: y + CGFloat(cell - size) / 2, width: CGFloat(size), height: CGFloat(size)))
        x += CGFloat(size + gap)
    }
    for size in [32, 16] {
        let shown = CGFloat(size * (size == 32 ? 5 : 10))
        draw(image(size), in: CGRect(x: x, y: y + (CGFloat(cell) - shown) / 2, width: shown, height: shown), nearest: true)
        x += shown + CGFloat(gap)
    }
    y += CGFloat(cell + rowGap)
    label("In the Dock at 64 and 32 px: light beside Apple Mail (comparison only), dark on its own; the system's render, then the .icns; the badge at 64 px",
          x: CGFloat(gap), y: y, bold: true)
    y += CGFloat(labelHeight)
    // Apple Mail as the system shows it: the full template canvas, margin included, like the .icns. Only its light icon:
    // NSWorkspace returns that one under darkAqua too, and setting it beside the dark icon would pass for a dark comparison.
    let mail = NSWorkspace.shared.icon(forFile: "/System/Applications/Mail.app")
    func mailImage(_ size: Int) -> CGImage? {
        var rect = NSRect(x: 0, y: 0, width: size * 2, height: size * 2)
        return mail.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    for (index, (rendition, dock)) in [("Default", Ink("#D5D9E1")), ("Dark", Ink("#2A2B30"))].enumerated() {
        let strip = CGRect(x: CGFloat(gap), y: y + CGFloat(index * (dockHeight + gap / 2)), width: CGFloat(width - 2 * gap), height: CGFloat(dockHeight - gap / 2))
        tile(strip, dock)
        var left = strip.minX + 24
        for size in [64, 32] {
            let s = CGFloat(size), margin = s * 100 / 1024
            let top = strip.midY - s / 2
            // Apple Mail (light only), then the system's render of this icon (the body alone, so set in the template's
            // margin), then the .icns.
            if index == 0 {
                if let mailIcon = mailImage(size) { draw(mailIcon, in: CGRect(x: left, y: top, width: s, height: s)) }
                left += s * 1.25
            }
            let ours = CGRect(x: left, y: top, width: s, height: s)
            if let tool, let system = systemRender(tool, rendition: rendition, size: 2 * size) {
                draw(system, in: ours.insetBy(dx: margin, dy: margin))
            }
            if size == 64 {
                // The badge: system red, at the body's top-right corner.
                let bodyRect = ours.insetBy(dx: margin, dy: margin)
                let badge = CGRect(x: bodyRect.maxX - 13, y: bodyRect.minY - 7, width: 20, height: 20)
                context.setFillColor(Ink("#FF3B30").cgColor())
                context.fillEllipse(in: badge)
                let digit = NSAttributedString(string: "3", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
                digit.draw(at: NSPoint(x: badge.midX - digit.size().width / 2, y: badge.midY - digit.size().height / 2))
            }
            left += s * 1.25
            if index == 0 { draw(image(size == 32 ? 32 : 128), in: CGRect(x: left, y: top, width: s, height: s)) }
            left += s * 1.25 + 40
        }
        label(index == 0 ? "light: Mail · system render · .icns" : "dark: system render only (no dark Mail to compare here: check it by hand)",
              x: left, y: strip.midY - 7,
              ink: Ink(index == 0 ? "#3C4352" : "#B8BCC6"))
    }
    NSGraphicsContext.current = nil
    guard let preview = context.makeImage() else { fail("cannot finish the preview") }
    writePNG(preview, to: URL(fileURLWithPath: previewPath))
    print("app-icon: wrote \(previewPath)")
}

// MARK: - Check

/// Every regular file under `url` but Finder's .DS_Store, as a path relative to `base`.
func files(under url: URL, relativeTo base: URL) -> [String] {
    guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var out: [String] = []
    for case let file as URL in walker where file.lastPathComponent != ".DS_Store"
        && (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        out.append(String(file.resolvingSymlinksInPath().path.dropFirst(base.resolvingSymlinksInPath().path.count + 1)))
    }
    return out.sorted()
}

if check {
    let made = output.appendingPathComponent("Resources"), committed = root.appendingPathComponent("Resources")
    let expected = ["AppIcon.icns"] + files(under: made.appendingPathComponent("AppIcon.icon"), relativeTo: made)
    let present = Set(files(under: committed.appendingPathComponent("AppIcon.icon"), relativeTo: committed))
    var stale: [String] = []
    for path in expected where fm.contents(atPath: made.appendingPathComponent(path).path) != fm.contents(atPath: committed.appendingPathComponent(path).path) {
        stale.append("Resources/\(path)" + (fm.fileExists(atPath: committed.appendingPathComponent(path).path) ? "" : " (missing)"))
    }
    for path in present.subtracting(expected).sorted() { stale.append("Resources/\(path) (no longer made)") }
    try? fm.removeItem(at: scratch)
    if stale.isEmpty {
        print("app-icon: Resources/AppIcon.icns and the \(expected.count - 1) files of Resources/AppIcon.icon are up to date")
        exit(0)
    }
    FileHandle.standardError.write(Data("app-icon: out of date (run `swift scripts/tools/app-icon.swift`):\n".utf8))
    for s in stale { FileHandle.standardError.write(Data("  \(s)\n".utf8)) }
    exit(1)
}
