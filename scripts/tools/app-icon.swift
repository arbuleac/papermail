// Draws the app icon (spec §5.42) from docs/design/tokens.json alone: the brand mark's path (`customGlyphs[icon.brand]`,
// the paper plane) and the `layout.appIcon` geometry and colours. Nothing is drawn by hand elsewhere.
//
// Usage: swift scripts/tools/app-icon.swift [--check] [--root <repo>] [--preview <png>]
//
// Writes:
//   Resources/AppIcon.icon/  an Icon Composer document (icon.json and one SVG layer) that `actool` compiles into the asset
//                            catalog for macOS 26 and later. The tile is the document's fill; the plane is one layer in one
//                            group, each with a solid fill specialized for dark and tinted, and glass, specular, shadow and
//                            translucency off: black and white, nothing added. The colours live only in icon.json, so no
//                            per-appearance copy of the artwork can drift from it. The system masks the squircle. A macOS
//                            AppIcon.appiconset cannot carry dark or tinted images (actool reports them as unassigned
//                            children); this document can.
//   Resources/AppIcon.icns   the default appearance on the macOS 15 template (the body on the 1024 canvas, Apple's continuous
//                            corners, the template's drop shadow outside the body), built by `iconutil` from a temporary
//                            .iconset, 16 to 1024 px. 16 and 32 px are pixel-fitted masters (`layout.appIcon.fit16`,
//                            `fit32`): the body on whole pixels and the plane redrawn on that size's own pixel grid, every
//                            vertex on a pixel corner, anti-aliased. A 1-bit plane would turn each diagonal into a
//                            staircase, and at these sizes the plane then stops reading as one. 64 to 512 px are the 1024
//                            master reduced with Core Graphics' high-quality resampling, as the approved board reduces
//                            it (the pixels `sips -Z` makes): inside the body every size is the approved image, pixel
//                            for pixel. It is the bundle's icon only where the asset catalog is not read (a build
//                            without actool, tools that open CFBundleIconFile): once actool has compiled the document,
//                            every macOS reads CFBundleIconName from Assets.car, and macOS 15 shows actool's own flat
//                            renderings of the document. actool ignores an AppIcon.appiconset that shares the
//                            document's name (Xcode 27.2), so no image set is written for macOS 15 (spec §5.42).
//   --check                  writes nothing in the repository: renders into a temporary folder, compares both outputs
//                            byte for byte, and exits 1 listing every file that is missing, stale or no longer made.
//   --preview <png>          optional, for review: the document's six system appearances rendered by Xcode's `ictool`
//                            (when Xcode is installed), the .icns sizes, and the icon in a light Dock at 64 and 32 px among
//                            Apple's white-tile apps and Mail (which App Review 5.2.5 says it must not resemble), and in a
//                            dark Dock on its own. NSWorkspace hands back the other apps' light icons under every
//                            appearance, so the dark row cannot compare them.
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
func string(_ path: String) -> String {
    guard let value = lookup(path) as? String else { fail("\(path) is not a string") }
    return value
}

/// The brand mark: its grid and its one path, the plane's three facets (glyph names hold a dot, so this reads the glyph
/// table directly rather than through `lookup`).
guard let brandName = lookup("icon.brand") as? String, let glyphs = tokens["customGlyphs"] as? [String: Any],
      let brandGlyph = glyphs[brandName] as? [String: Any], let glyphPaths = brandGlyph["paths"] as? [String], glyphPaths.count == 1,
      let brandGrid = (brandGlyph["grid"] as? NSNumber)?.doubleValue, (brandGlyph["stroke"] as? NSNumber)?.doubleValue == 0 else {
    fail("customGlyphs[icon.brand] must be a filled glyph with one path, the plane")
}
let planeData = glyphPaths[0]

/// One colour as the icon uses it: hex for the SVG layer, sRGB components for drawing and for icon.json.
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

/// One appearance's two colours: the tile and the plane. Nothing else is coloured.
struct Look {
    let tile: Ink, plane: Ink
}
let defaultLook = Look(tile: Ink(string("layout.appIcon.tile")), plane: Ink(string("layout.appIcon.plane")))
let darkLook = Look(tile: Ink(string("layout.appIcon.tileDark")), plane: Ink(string("layout.appIcon.planeDark")))
let tintedLook = Look(tile: Ink(string("layout.appIcon.tileTinted")), plane: Ink(string("layout.appIcon.planeTinted")))

let canvas = number("layout.appIcon.canvas")
let body = number("layout.appIcon.body")
let markRect = CGRect(x: number("layout.appIcon.markX"), y: number("layout.appIcon.markY"),
                      width: number("layout.appIcon.markSize"), height: number("layout.appIcon.markSize"))
/// The body's continuous corners (a fraction of its side) and the macOS 15 template's drop shadow, in canvas units.
let corner = number("layout.appIcon.corner")
let shadow = (y: number("layout.appIcon.shadowY"), blur: number("layout.appIcon.shadowBlur"), alpha: number("layout.appIcon.shadowAlpha"))

/// A pixel-fitted small master: its body in canvas units (a whole number of pixels, centred, so the tile's edge is a
/// whole pixel rather than a half-covered ring) and the plane in that size's pixels.
struct Fit {
    let body: CGFloat
    let plane: String
}
func fit(_ size: Int) -> Fit {
    let p = "layout.appIcon.fit\(size)."
    return Fit(body: number(p + "body"), plane: string(p + "path"))
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

/// The plane on the canvas, from the glyph's path.
let masterPlane = placed(planeData, markTransform)

/// A pixel-fitted master's plane, from its own pixels onto the canvas.
func fittedPlane(_ fit: Fit, size: Int) -> CGPath {
    let scale = canvas / CGFloat(size)
    return placed(fit.plane, CGAffineTransform(scaleX: scale, y: scale))
}

/// A square with Apple's continuous corners of radius `radius`: the shape the system masks icons with. Each corner
/// leaves its edge 1.52866483 radii before the corner and runs through three cubics to the same distance along the next
/// edge (the control points in radii, as iOS draws a rounded rectangle whose radius is not limited by its size).
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, rect.width / 2 / 1.52866483, rect.height / 2 / 1.52866483)
    let curve: [[(CGFloat, CGFloat)]] = [
        [(1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600)],
        [(0.43231650, 0.12608359), (0.12608359, 0.43231650), (0.06549600, 0.66993427)],
        [(0, 0.86840689), (0, 1.08849323), (0, 1.52866483)],
    ]
    let path = CGMutablePath()
    // Each corner in its own frame: `along` runs with the edge that leads into it, `across` toward the next edge.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    path.move(to: CGPoint(x: rect.minX + 1.52866483 * r, y: rect.minY))
    for (origin, along, across) in corners {
        func at(_ p: CGFloat, _ q: CGFloat) -> CGPoint {
            CGPoint(x: origin.x - p * r * along.dx + q * r * across.dx, y: origin.y - p * r * along.dy + q * r * across.dy)
        }
        path.addLine(to: at(1.52866483, 0))
        for c in curve {
            path.addCurve(to: at(c[2].0, c[2].1), control1: at(c[0].0, c[0].1), control2: at(c[1].0, c[1].1))
        }
    }
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

/// The master: the body filled with the tile's colour and the plane in its own, on the whole canvas at one pixel a unit,
/// with nothing outside the body. Every size but the pixel-fitted ones is this image, reduced.
func renderMaster(look: Look) -> CGImage {
    let size = Int(canvas)
    let context = sRGBContext(size, size)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    // Draw y down, in canvas units, as the path data and the tokens are written.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)
    let inset = (canvas - body) / 2
    context.addPath(squircle(CGRect(x: inset, y: inset, width: body, height: body), radius: corner * body))
    context.setFillColor(look.tile.cgColor())
    context.fillPath()
    context.addPath(masterPlane)
    context.setFillColor(look.plane.cgColor())
    context.fillPath(using: .winding)
    guard let image = context.makeImage() else { fail("cannot finish the master") }
    return image
}

/// One icon image `size` pixels square on the macOS 15 template, with the template's drop shadow outside the body so the
/// icon sits on a macOS 15 Dock like its neighbours. 16 and 32 px draw their pixel-fitted masters, body included; every
/// other size draws the master at that size with high-quality resampling, which is how the approved board reduces it
/// (64 to 512 px there are `sips -Z` reductions of its 1024 px image, and `sips` resamples exactly so): drawing each size
/// from the paths instead covers the same edges by area, a softer edge that differs from the approved images by up to
/// 56 levels at 64 px. Either way the shadow is cast by the opaque body and lies under it, so it changes nothing inside.
func renderIcon(size: Int, look: Look) -> CGImage {
    let s = CGFloat(size)
    let context = sRGBContext(size, size)
    // Every size is anti-aliased, the pixel-fitted masters too: their vertices sit on pixel corners, so the coverage
    // falls only along the diagonals, which stay straight rather than stepping.
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    // Shadow offsets ignore the transform: they are in pixels, y up.
    context.setShadow(offset: CGSize(width: 0, height: -shadow.y * s / canvas), blur: shadow.blur * s / canvas,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: shadow.alpha))
    guard let fit = fits[size] else {
        context.interpolationQuality = .high
        context.draw(master(look), in: CGRect(x: 0, y: 0, width: s, height: s))
        guard let image = context.makeImage() else { fail("cannot finish the \(size) px image") }
        return image
    }
    // Draw y down, in canvas units, as the path data and the tokens are written.
    context.translateBy(x: 0, y: s)
    context.scaleBy(x: s / canvas, y: -s / canvas)
    let inset = (canvas - fit.body) / 2
    context.addPath(squircle(CGRect(x: inset, y: inset, width: fit.body, height: fit.body), radius: corner * fit.body))
    context.setFillColor(look.tile.cgColor())
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.addPath(fittedPlane(fit, size: size))
    context.setFillColor(look.plane.cgColor())
    context.fillPath(using: .winding)
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

var masters: [String: CGImage] = [:]
func master(_ look: Look) -> CGImage {
    let key = look.tile.hex + look.plane.hex
    if let made = masters[key] { return made }
    let made = renderMaster(look: look)
    masters[key] = made
    return made
}
var rendered: [Int: CGImage] = [:]
func image(_ size: Int, look: Look = defaultLook) -> CGImage {
    if look.tile.hex != defaultLook.tile.hex || look.plane.hex != defaultLook.plane.hex { return renderIcon(size: size, look: look) }
    if let cached = rendered[size] { return cached }
    let made = renderIcon(size: size, look: look)
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

/// One solid colour per appearance: the default, then dark and tinted.
func solidFills(_ keyPath: KeyPath<Look, Ink>) -> JSONValue {
    let looks: [(String?, Look)] = [(nil, defaultLook), ("dark", darkLook), ("tinted", tintedLook)]
    return .array(looks.map { appearance, look in
        var members: [(String, JSONValue)] = [("value", .object([("solid", .string(srgb(look[keyPath: keyPath])))]))]
        if let appearance { members.append(("appearance", .string(appearance))) }
        return .object(members)
    })
}

/// The layer: the plane on the document's canvas, which is the body alone (the system adds the margin and the mask), so
/// the viewBox is the body on the 1024 template and the glyph keeps its whole-unit path under one transform. Its fill is
/// the default plane colour; icon.json's specializations replace it, and the SVG says on its own what the layer is.
func layerSVG() -> String {
    let inset = (canvas - body) / 2
    let t = markTransform
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(fixed(canvas))\" height=\"\(fixed(canvas))\" "
        + "viewBox=\"\(fixed(inset)) \(fixed(inset)) \(fixed(body)) \(fixed(body))\">"
        + "<path transform=\"matrix(\(fixed(t.a)) 0 0 \(fixed(t.d)) \(fixed(t.tx)) \(fixed(t.ty)))\" fill=\"\(defaultLook.plane.hex)\" d=\"\(planeData)\"/></svg>\n"
}

let document = output.appendingPathComponent("Resources/AppIcon.icon")
let assets = document.appendingPathComponent("Assets")
try? fm.removeItem(at: document)
do { try fm.createDirectory(at: assets, withIntermediateDirectories: true) } catch { fail("cannot make \(assets.path): \(error)") }
do { try Data(layerSVG().utf8).write(to: assets.appendingPathComponent("plane.svg")) } catch { fail("cannot write plane.svg: \(error)") }
// One group of one layer. Glass, specular highlights, shadow and translucency are off: the icon is the two colours.
let iconJSON = JSONValue.object([
    ("fill-specializations", solidFills(\.tile)),
    ("groups", .array([.object([
        ("layers", .array([.object([
            ("fill-specializations", solidFills(\.plane)),
            ("glass", .raw("false")),
            ("image-name", .string("plane.svg")),
            ("name", .string("Plane")),
        ])])),
        ("name", .string("Plane")),
        ("shadow", .object([("kind", .string("none")), ("opacity", .raw("0"))])),
        ("specular", .raw("false")),
        ("translucency", .object([("enabled", .raw("false")), ("value", .raw("0"))])),
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
    label("Resources/AppIcon.icns (wherever Assets.car is not read): 1024 px shown at \(cell), then 128, 64, 32 and 16 px at 1×; 32 and 16 px enlarged", x: CGFloat(gap), y: y, bold: true)
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
    label("In the Dock at 64 and 32 px: light among Apple's white-tile apps and Mail (comparison only), dark on its own; the system's render, then the badge",
          x: CGFloat(gap), y: y, bold: true)
    y += CGFloat(labelHeight)
    // Apple's apps as the system shows them: the full template canvas, margin included, like the .icns. Only their light
    // icons: NSWorkspace returns those under darkAqua too, and setting them beside the dark icon would pass for a dark
    // comparison.
    func appIcon(_ name: String, _ size: Int) -> CGImage? {
        var rect = NSRect(x: 0, y: 0, width: size * 2, height: size * 2)
        return NSWorkspace.shared.icon(forFile: "/System/Applications/\(name).app").cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    for (index, (rendition, dock)) in [("Default", Ink("#D5D9E1")), ("Dark", Ink("#2A2B30"))].enumerated() {
        let strip = CGRect(x: CGFloat(gap), y: y + CGFloat(index * (dockHeight + gap / 2)), width: CGFloat(width - 2 * gap), height: CGFloat(dockHeight - gap / 2))
        tile(strip, dock)
        var left = strip.minX + 24
        for size in [64, 32] {
            let s = CGFloat(size), margin = s * 100 / 1024
            let top = strip.midY - s / 2
            let neighbours = index == 0 ? ["Calendar", "Notes", "", "Photos", "Reminders", "Freeform", "Mail"] : [""]
            for name in neighbours {
                let slot = CGRect(x: left, y: top, width: s, height: s)
                if name.isEmpty {
                    // The system's render of this icon is the body alone, so it is set in the template's margin.
                    if let tool, let system = systemRender(tool, rendition: rendition, size: 2 * size) {
                        draw(system, in: slot.insetBy(dx: margin, dy: margin))
                    }
                    if size == 64 {
                        // The badge: system red, at the body's top-right corner.
                        let bodyRect = slot.insetBy(dx: margin, dy: margin)
                        let badge = CGRect(x: bodyRect.maxX - 13, y: bodyRect.minY - 7, width: 20, height: 20)
                        context.setFillColor(Ink("#FF3B30").cgColor())
                        context.fillEllipse(in: badge)
                        let digit = NSAttributedString(string: "3", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
                        digit.draw(at: NSPoint(x: badge.midX - digit.size().width / 2, y: badge.midY - digit.size().height / 2))
                    }
                } else if let icon = appIcon(name, size) {
                    draw(icon, in: slot)
                }
                left += s * 1.15
            }
            left += 32
        }
        label(index == 0 ? "light, beside Apple's apps" : "dark: system render only",
              x: left, y: strip.midY - 7, ink: Ink(index == 0 ? "#3C4352" : "#B8BCC6"))
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
