import AppKit
import XCTest
@testable import SSDesign

/// The SVG path parser and the five custom glyphs (spec §4.11, §8.7), the brand mark's construction and the app icon's
/// placement of it (§5.42).
final class GlyphPathTests: XCTestCase {
    private func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, accuracy: CGFloat = 1e-6,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: accuracy, "minX of \(r)", file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: accuracy, "minY of \(r)", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: accuracy, "width of \(r)", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: accuracy, "height of \(r)", file: file, line: line)
    }

    // MARK: Glyphs

    func testEveryGlyphParsesAndStaysInsideItsGrid() throws {
        for glyph in Quire.CustomGlyph.allCases {
            for d in glyph.paths { XCTAssertNoThrow(try QuireSVGPath.parse(d), glyph.rawValue) }
            let geometry = QuireGlyph.path(glyph).boundingBoxOfPath
            XCTAssertFalse(geometry.isEmpty, glyph.rawValue)
            let grid = CGRect(x: 0, y: 0, width: glyph.grid, height: glyph.grid)
            XCTAssertTrue(grid.contains(geometry), "\(glyph.rawValue) geometry \(geometry) leaves its \(glyph.grid) grid")
            // With half the stroke and the filled circles, the ink still fits: nothing is clipped at any size.
            let ink = QuireGlyph.inkBounds(glyph)
            XCTAssertTrue(grid.insetBy(dx: -1e-9, dy: -1e-9).contains(ink), "\(glyph.rawValue) ink \(ink) leaves its \(glyph.grid) grid")
        }
    }

    func testGlyphGeometryIsWhereTheSpecDrawsIt() {
        // ss.quire: the envelope body runs 1.75…14.25 by 6.25…13.75, the top stroke sits at y 1.5.
        let quire = QuireGlyph.path(.ssQuire).boundingBoxOfPath
        assertRect(quire, 1.75, 1.5, 12.5, 12.25)
        // ss.elide: two brackets from x 2.75 to 13.25, y 2.75 to 13.25.
        assertRect(QuireGlyph.path(.ssElide).boundingBoxOfPath, 2.75, 2.75, 10.5, 10.5)
        // ss.queued: the arrow only (the dot is a fill), on the 12 grid.
        assertRect(QuireGlyph.path(.ssQueued).boundingBoxOfPath, 5.75, 2.25, 4, 4)
        XCTAssertEqual(Quire.CustomGlyph.ssQueued.fills, [QuireGlyphCircle(cx: 2.75, cy: 9.25, r: 1.6)])
        XCTAssertEqual(Quire.CustomGlyph.ssPaperPlane.fillRule, .winding)
        XCTAssertEqual(Quire.CustomGlyph.ssPaperPlane.stroke, 0)
        XCTAssertEqual(Quire.Icon.brand, Quire.CustomGlyph.ssPaperPlane.rawValue)
    }

    /// The plane's triangles as the path data names them: the far wing (N, WF, T), the near wing (N, S, WN) and the keel
    /// (X, Sk, K). Only M, L and Z are allowed: every edge of the mark is a straight segment.
    private func triangles(_ data: String, file: StaticString = #filePath, line: UInt = #line) throws -> [[CGPoint]] {
        let allowed = CharacterSet(charactersIn: "MLZ0123456789 .-")
        XCTAssertTrue(data.unicodeScalars.allSatisfy(allowed.contains), "straight segments only (M, L, Z): \(data)", file: file, line: line)
        return data.split(separator: "Z").map { part in
            let numbers = part.split(whereSeparator: { "ML ".contains($0) }).compactMap { Double($0) }.map { CGFloat($0) }
            return stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
        }.filter { !$0.isEmpty }
    }

    /// The direction from a to b as a reduced whole-unit step, so a slope reads exactly (1:2 is (2, 1) or (-2, -1)).
    private func step(_ a: CGPoint, _ b: CGPoint) -> (Int, Int) {
        var dx = Int(b.x - a.x), dy = Int(b.y - a.y)
        var g = dx == 0 ? abs(dy) : dy == 0 ? abs(dx) : 1
        if dx != 0, dy != 0 { var (m, n) = (abs(dx), abs(dy)); while n != 0 { (m, n) = (n, m % n) }; g = m }
        dx /= g; dy /= g
        return (dx, dy)
    }

    /// The brand mark (spec §4.11, §5.42): the paper plane drawn on an isometric grid, its 80 grid one unit to an 8 px
    /// unit of the icon's 1024 template. Three triangles, every vertex a whole unit; the trailing edge WF–T–S–WN is one
    /// 1:2 line and the spine N–S runs 1:2; the far leading edge rises 1:4; the near wing's leading edge and the keel's
    /// foot lie on one 45° line; the keel's top runs 1:2 and its back is vertical; the fold between the wings closes at
    /// the nose and opens at the tail, the keel's gap stays open; the box is 80 × 60, centred; nothing overlaps.
    func testPaperPlaneKeepsItsConstruction() throws {
        let glyph = Quire.CustomGlyph.ssPaperPlane
        XCTAssertEqual(glyph.grid, 80)
        XCTAssertEqual(glyph.paths.count, 1, "one path, one colour")
        let t = try triangles(glyph.paths[0])
        XCTAssertEqual(t.map(\.count), [3, 3, 3], "far wing, near wing, keel")
        for point in t.joined() {
            XCTAssertEqual(point.x, point.x.rounded(), "\(point) on a grid intersection")
            XCTAssertEqual(point.y, point.y.rounded(), "\(point) on a grid intersection")
        }
        let (n, wf, tail) = (t[0][0], t[0][1], t[0][2])
        XCTAssertEqual(t[1][0], n, "the wings meet at the nose")
        let (s, wn) = (t[1][1], t[1][2])
        let (x, sk, k) = (t[2][0], t[2][1], t[2][2])
        XCTAssertEqual([n, wf, tail, s, wn, sk, x, k],
                       [CGPoint(x: 80, y: 10), CGPoint(x: 0, y: 30), CGPoint(x: 16, y: 38), CGPoint(x: 20, y: 40),
                        CGPoint(x: 40, y: 50), CGPoint(x: 20, y: 43), CGPoint(x: 38, y: 52), CGPoint(x: 20, y: 70)],
                       "the approved vertices")

        // The lines it is built on.
        for (a, b) in [(wf, tail), (tail, s), (s, wn)] {
            XCTAssertTrue(step(a, b) == (2, 1), "the trailing edge runs 1:2, one straight line through \(a) and \(b)")
        }
        XCTAssertTrue(step(s, n) == (2, -1), "the spine N–S runs 1:2")
        XCTAssertTrue(step(wf, n) == (4, -1), "the far leading edge rises 1:4")
        for (a, b) in [(k, x), (x, wn), (wn, n)] {
            XCTAssertTrue(step(a, b) == (1, -1), "the near wing's leading edge and the keel's foot are one 45° line")
        }
        XCTAssertTrue(step(sk, x) == (2, 1), "the keel's top is parallel to the trailing edge")
        XCTAssertEqual(s.x, sk.x, "the keel's back is vertical")
        XCTAssertEqual(sk.x, k.x, "the keel's back is vertical")

        // The fold between the wings is a wedge: closed at N, (4, 2) open at the tail, about 3.6 units across.
        func across(_ p: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
            abs((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) / hypot(b.x - a.x, b.y - a.y)
        }
        XCTAssertEqual(across(tail, from: n, to: s), 3.58, accuracy: 0.01, "the fold open at the tail")
        // The keel's gap: 3 units down from the near wing's trailing edge, about 2.7 across, the same all along.
        XCTAssertEqual(sk.y - s.y, 3, "the keel's gap at its back")
        XCTAssertEqual(across(sk, from: s, to: wn), across(x, from: s, to: wn), accuracy: 1e-9, "the keel's gap keeps its width")
        XCTAssertEqual(across(sk, from: s, to: wn), 2.68, accuracy: 0.01)

        let box = QuireGlyph.path(glyph).boundingBoxOfPath
        assertRect(box, 0, 10, 80, 60)
        XCTAssertEqual(box.midX, glyph.grid / 2, "centred across")
        XCTAssertEqual(box.midY, glyph.grid / 2, "centred down")

        // The triangles never overlap, and the folds are ground: sample the plane's box.
        let parts = try t.map { triangle -> CGPath in
            try QuireSVGPath.parse("M" + triangle.map { "\($0.x) \($0.y)" }.joined(separator: " L") + " Z")
        }
        for px in stride(from: box.minX + 0.05, to: box.maxX, by: 0.25) {
            for py in stride(from: box.minY + 0.05, to: box.maxY, by: 0.25) {
                let point = CGPoint(x: px, y: py)
                XCTAssertLessThanOrEqual(parts.filter { $0.contains(point) }.count, 1, "triangles overlap at \(point)")
            }
        }
        let plane = QuireGlyph.path(glyph)
        let foldMid = CGPoint(x: n.x + ((tail.x + s.x) / 2 - n.x) / 2, y: n.y + ((tail.y + s.y) / 2 - n.y) / 2)
        XCTAssertFalse(plane.contains(foldMid), "the fold is open at \(foldMid)")
        let gapMid = CGPoint(x: (s.x + wn.x) / 2 + 0.5, y: (s.y + wn.y) / 2 + 1.75)
        XCTAssertFalse(plane.contains(gapMid), "the keel's gap is open at \(gapMid)")
    }

    /// The app icon (spec §5.42) puts one glyph unit on one 8 px unit of the 1024 template, so every vertex is a grid
    /// point, and places the plane where the approved board draws it: its box from (200, 296) to (840, 776), set optically
    /// (midway between the box's centre and the ink's centroid lies within 3 px of the canvas's centre on each axis, 1.8 px
    /// left and 2.6 px low). A white plane on the near-black tile, in dark too; white on black for the system to tint.
    func testAppIconPlacesThePlaneOnTheConstructionGrid() throws {
        let icon = Quire.Layout.AppIcon.self, glyph = Quire.CustomGlyph.ssPaperPlane
        XCTAssertEqual(icon.markSize / glyph.grid, 8, "one unit to 8 px")
        XCTAssertEqual(icon.markX.truncatingRemainder(dividingBy: 8), 0)
        XCTAssertEqual(icon.markY.truncatingRemainder(dividingBy: 8), 0)
        let box = QuireGlyph.path(glyph).boundingBoxOfPath
        assertRect(CGRect(x: icon.markX + box.minX * 8, y: icon.markY + box.minY * 8, width: box.width * 8, height: box.height * 8),
                   200, 296, 640, 480)
        // The ink's centroid, from the three triangles' areas.
        var area: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for p in try triangles(glyph.paths[0]) {
            let a = abs((p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x)) / 2
            area += a; cx += a * (p[0].x + p[1].x + p[2].x) / 3; cy += a * (p[0].y + p[1].y + p[2].y) / 3
        }
        let centroid = CGPoint(x: icon.markX + cx / area * 8, y: icon.markY + cy / area * 8)
        let optical = CGPoint(x: (centroid.x + icon.markX + box.midX * 8) / 2, y: (centroid.y + icon.markY + box.midY * 8) / 2)
        XCTAssertEqual(optical.x, icon.canvas / 2, accuracy: 3, "placed optically across")
        XCTAssertEqual(optical.y, icon.canvas / 2, accuracy: 3, "and down")
        XCTAssertEqual([icon.tile, icon.plane, icon.tileDark, icon.planeDark, icon.tileTinted, icon.planeTinted],
                       ["#0A0A0A", "#FFFFFF", "#0A0A0A", "#FFFFFF", "#000000", "#FFFFFF"], "black and white only")
    }

    /// The 16 and 32 px masters (`layout.appIcon.fit16`, `fit32`) are straight-edged polygons with every vertex on a pixel
    /// corner, drawn anti-aliased, so only their diagonals carry grey pixels and stay straight, inside a body snapped to
    /// whole pixels with at least a pixel of tile around.
    func testPixelFittedMastersAreWholePixelsInsideTheirBodies() throws {
        let icon = Quire.Layout.AppIcon.self
        for (size, body, data) in [(16, icon.Fit16.body, icon.Fit16.path), (32, icon.Fit32.body, icon.Fit32.path)] {
            let side = body * CGFloat(size) / icon.canvas
            XCTAssertEqual(side, side.rounded(), "\(size) px body on whole pixels")
            XCTAssertEqual((CGFloat(size) - side) / 2, ((CGFloat(size) - side) / 2).rounded(), "\(size) px body centred on whole pixels")
            var vertices = 0
            try QuireSVGPath.parse(data).applyWithBlock { element in
                let e = element.pointee
                switch e.type {
                case .moveToPoint, .addLineToPoint:
                    let p = e.points[0]
                    XCTAssertEqual(p.x, p.x.rounded(), "\(size) px vertex \(p) on a pixel corner")
                    XCTAssertEqual(p.y, p.y.rounded(), "\(size) px vertex \(p) on a pixel corner")
                    vertices += 1
                case .closeSubpath:
                    break
                default:
                    XCTFail("\(size) px master: straight segments only")
                }
            }
            XCTAssertGreaterThanOrEqual(vertices, 3, "\(size) px master draws a polygon")
            let inset = (CGFloat(size) - side) / 2
            let ink = try QuireSVGPath.parse(data).boundingBoxOfPath
            XCTAssertTrue(CGRect(x: inset, y: inset, width: side, height: side).insetBy(dx: 1, dy: 1).contains(ink),
                          "\(size) px plane \(ink) keeps a pixel of tile around it")
        }
    }

    func testImagesAreTemplatesAtTheRequestedSize() {
        let image = QuireGlyph.image(.ssNib, pointSize: 18)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(QuireGlyph.image(.ssNib, pointSize: 18) === image, "cached per point size")
        XCTAssertFalse(QuireGlyph.image(.ssNib, pointSize: 12) === image)
        // It actually inks: render at 2× and look for opaque pixels.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<36 { for y in 0..<36 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
        XCTAssertGreaterThan(inked, 40)
    }

    // MARK: Parser

    func testAbsoluteAndRelativeLinesAndImplicitRepeats() throws {
        // After M, extra pairs are line-tos; after m they are relative line-tos.
        let a = try QuireSVGPath.parse("M2.1 7 8 10.6 13.9 7")
        assertRect(a.boundingBoxOfPath, 2.1, 7, 11.8, 3.6)
        let b = try QuireSVGPath.parse("m1 1 2 0 0 2 -2 0z")
        assertRect(b.boundingBoxOfPath, 1, 1, 2, 2)
        let c = try QuireSVGPath.parse("M1 1h4v3H1V1")
        assertRect(c.boundingBoxOfPath, 1, 1, 4, 3)
        let d = try QuireSVGPath.parse("M1 1h4v3h-4z")
        assertRect(d.boundingBoxOfPath, 1, 1, 4, 3)
    }

    func testCompactNumberForms() throws {
        // "1-1" is two numbers, ".5.5" is two numbers, exponents parse, commas separate.
        assertRect(try QuireSVGPath.parse("M0 0L1-1").boundingBoxOfPath, 0, -1, 1, 1)
        assertRect(try QuireSVGPath.parse("M0,0L.5.5").boundingBoxOfPath, 0, 0, 0.5, 0.5)
        assertRect(try QuireSVGPath.parse("M0 0L1e1 2E-1").boundingBoxOfPath, 0, 0, 10, 0.2)
        assertRect(try QuireSVGPath.parse("M-1-1l+2+2").boundingBoxOfPath, -1, -1, 2, 2)
    }

    func testCurvesAndSmoothReflection() throws {
        // C then S: S reflects the previous second control point. The curve's end points bound it here.
        let p = try QuireSVGPath.parse("M0 0C0 1 1 1 1 0S2 -1 2 0")
        XCTAssertEqual(p.currentPoint.x, 2, accuracy: 1e-9)
        XCTAssertEqual(p.currentPoint.y, 0, accuracy: 1e-9)
        var elements: [CGPathElementType] = []
        var controls: [CGPoint] = []
        p.applyWithBlock { e in
            elements.append(e.pointee.type)
            if e.pointee.type == .addCurveToPoint { controls.append(e.pointee.points[0]) }
        }
        XCTAssertEqual(elements, [.moveToPoint, .addCurveToPoint, .addCurveToPoint])
        XCTAssertEqual(controls.last, CGPoint(x: 1, y: -1), "S reflects (1, 1) about (1, 0)")
        // Q then T, relative.
        let q = try QuireSVGPath.parse("M0 0q1 1 2 0t2 0")
        XCTAssertEqual(q.currentPoint, CGPoint(x: 4, y: 0))
        // S after a non-curve uses the current point as its first control.
        XCTAssertNoThrow(try QuireSVGPath.parse("M0 0L1 1s1 1 2 0"))
    }

    func testArcsIncludingPackedFlags() throws {
        // A half circle of radius 1 from (0, 0) to (2, 0), sweeping through y = -1 or y = +1.
        let up = try QuireSVGPath.parse("M0 0A1 1 0 0 1 2 0")
        assertRect(up.boundingBoxOfPath, 0, -1, 2, 1, accuracy: 1e-3)
        let down = try QuireSVGPath.parse("M0 0A1 1 0 0 0 2 0")
        assertRect(down.boundingBoxOfPath, 0, 0, 2, 1, accuracy: 1e-3)
        // Flags packed without separators, relative form.
        let packed = try QuireSVGPath.parse("M0 0a1 1 0 012 0")
        assertRect(packed.boundingBoxOfPath, 0, -1, 2, 1, accuracy: 1e-3)
        // Radii too small are scaled up to reach the end point.
        let scaled = try QuireSVGPath.parse("M0 0A0.1 0.1 0 0 1 4 0")
        assertRect(scaled.boundingBoxOfPath, 0, -2, 4, 2, accuracy: 1e-3)
        // A rotated ellipse arc ends exactly on its end point.
        let rotated = try QuireSVGPath.parse("M0 0A3 1 30 1 1 2 2")
        XCTAssertEqual(rotated.currentPoint.x, 2, accuracy: 1e-9)
        XCTAssertEqual(rotated.currentPoint.y, 2, accuracy: 1e-9)
        // The rounded corners of ss.quire: a quarter circle of radius 1.
        let corner = try QuireSVGPath.parse("M13.25 6.25a1 1 0 0 1 1 1")
        assertRect(corner.boundingBoxOfPath, 13.25, 6.25, 1, 1, accuracy: 1e-3)
    }

    func testZStartsTheNextSubpathAtTheClosedOnesStart() throws {
        let p = try QuireSVGPath.parse("M1 1h2v2z l1 0")
        XCTAssertEqual(p.currentPoint, CGPoint(x: 2, y: 1))
    }

    func testMalformedDataThrows() {
        XCTAssertThrowsError(try QuireSVGPath.parse("L1 1"))
        XCTAssertThrowsError(try QuireSVGPath.parse("M1"))
        XCTAssertThrowsError(try QuireSVGPath.parse("M0 0A1 1 0 2 1 2 0"))
        XCTAssertThrowsError(try QuireSVGPath.parse("M0 0 X1 1"))
    }
}
