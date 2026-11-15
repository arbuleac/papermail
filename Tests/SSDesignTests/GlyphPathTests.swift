import AppKit
import XCTest
@testable import SSDesign

/// The SVG path parser and the five custom glyphs (spec §4.11, §8.7).
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
        XCTAssertEqual(Quire.CustomGlyph.ssItalicEnvelope.fillRule, .winding)
        XCTAssertEqual(Quire.CustomGlyph.ssItalicEnvelope.stroke, 0)
        XCTAssertEqual(Quire.Icon.brand, Quire.CustomGlyph.ssItalicEnvelope.rawValue)
    }

    /// The brand mark (spec §4.11, §5.42): a √2 box 24 tall on the 40 grid, its top at y 8 and its bottom at y 32 (a fifth
    /// and four fifths, so a multiple of 5 pt puts both on whole points), sheared 12° about its centre. Two paths, the front
    /// then the flap, because the app icon colours them apart; between them the crease is open from side to side and
    /// symmetric about its apex.
    func testItalicEnvelopeKeepsItsSlantAndAnOpenSymmetricCrease() throws {
        let glyph = Quire.CustomGlyph.ssItalicEnvelope
        XCTAssertEqual(glyph.grid, 40)
        XCTAssertEqual(glyph.paths.count, 2)
        let front = try QuireSVGPath.parse(glyph.paths[0]), flap = try QuireSVGPath.parse(glyph.paths[1])
        XCTAssertEqual(flap.boundingBoxOfPath.minY, 8, accuracy: 1e-3, "the flap carries the top edge")
        XCTAssertEqual(front.boundingBoxOfPath.maxY, 32, accuracy: 1e-3, "the front carries the bottom edge")

        // The sides, found where a row of the whole mark starts and ends, below the crease (whose lowest point, the front's
        // notch, is above y 25) and above the bottom corners' rounding.
        let mark = QuireGlyph.path(glyph)
        func side(y: CGFloat, fromLeft: Bool) -> CGFloat {
            var outside: CGFloat = fromLeft ? 0 : 40, inside: CGFloat = 20
            for _ in 0..<40 {
                let mid = (outside + inside) / 2
                if mark.contains(CGPoint(x: mid, y: y)) { inside = mid } else { outside = mid }
            }
            return inside
        }
        let slant = tan(12 * CGFloat.pi / 180)
        XCTAssertEqual((side(y: 25, fromLeft: true) - side(y: 28, fromLeft: true)) / 3, slant, accuracy: 1e-3, "the left side leans 12°")
        XCTAssertEqual((side(y: 25, fromLeft: false) - side(y: 28, fromLeft: false)) / 3, slant, accuracy: 1e-3, "the right side leans 12°")
        // The centre line of the sheared box passes through (20, 20): at y 28 it is 8 · tan 12° left of x 20.
        XCTAssertEqual((side(y: 28, fromLeft: true) + side(y: 28, fromLeft: false)) / 2, 20 - 8 * slant, accuracy: 1e-3, "centred on x 20")
        for y: CGFloat in [25, 28] {
            XCTAssertEqual(side(y: y, fromLeft: false) - side(y: y, fromLeft: true), 24 * 2.0.squareRoot(), accuracy: 1e-3, "√2 × 24 wide at y \(y)")
        }

        // Column by column, from just inside one side to just inside the other: the flap, then the open crease, then the
        // front, never both at once. The crease's height in each column is kept to check its symmetry.
        func crease(atX x: CGFloat) -> CGFloat {
            var gap: CGFloat = 0, seenFront = false, seenFlap = false
            for step in 0...2400 {
                let point = CGPoint(x: x, y: 8 + CGFloat(step) / 100)
                let inFlap = flap.contains(point), inFront = front.contains(point)
                XCTAssertFalse(inFlap && inFront, "the parts overlap at \(point)")
                if inFlap { XCTAssertFalse(seenFront, "flap below the front at \(point)"); seenFlap = true }
                if inFront { seenFront = true }
                if seenFlap, !seenFront, !inFlap, !inFront { gap += 0.01 }
            }
            return gap
        }
        let apexX: CGFloat = 21.658
        for x in stride(from: CGFloat(6), through: 37, by: 1) {
            XCTAssertGreaterThan(crease(atX: x), 0.05, "the crease is shut at x \(x)")
        }
        XCTAssertGreaterThan(crease(atX: apexX), 3.6, "the crease is widest at its apex")
        for d: CGFloat in [3, 8, 13] {
            XCTAssertEqual(crease(atX: apexX - d), crease(atX: apexX + d), accuracy: 0.03, "the V is symmetric \(d) from its apex")
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
