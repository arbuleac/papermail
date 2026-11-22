import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// The PNGs in docs/brand (spec §5.42, docs/brand/README.md) are pixel-clean: sRGB, the brand's ink and paper only, the
/// clear space empty to the file's edge, and a ground that fills its frame covering every pixel to the last column and
/// row. `brand-assets --check` compares the files only with the script's own output, so this is what holds the output.
final class BrandFilesTests: XCTestCase {
    private let brand = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PaperDesignTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repository
        .appendingPathComponent("docs/brand")

    private struct Pixels {
        let width: Int, height: Int
        let isSRGB: Bool
        /// RGBA, premultiplied, in sRGB.
        let bytes: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

        func hex(_ x: Int, _ y: Int) -> String {
            let i = (y * width + x) * 4
            return String(format: "#%02X%02X%02X", bytes[i], bytes[i + 1], bytes[i + 2])
        }

        /// Every pixel on the four edges.
        var edge: [(Int, Int)] {
            (0..<width).flatMap { [($0, 0), ($0, height - 1)] } + (0..<height).flatMap { [(0, $0), (width - 1, $0)] }
        }
    }

    private func pixels(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Pixels {
        let url = brand.appendingPathComponent("\(name).png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot read \(url.path)", file: file, line: line)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(name).png has no image", file: file, line: line)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "cannot draw \(name).png", file: file, line: line)
        return Pixels(width: image.width, height: image.height, isSRGB: image.colorSpace?.name == CGColorSpace.sRGB, bytes: bytes)
    }

    private func colour(_ key: String) throws -> String {
        try XCTUnwrap(DesignTokensFile.shared.value("layout.brand.\(key)") as? String).uppercased()
    }

    /// The lockup on black and the construction drawing carry their own ground, which fills the frame: every pixel is
    /// opaque, the last column and row too, whatever fraction of a pixel the frame's size ends on. The lockup's edges are
    /// its clear space, so they are the ink ground and nothing else.
    func testAGroundCoversEveryPixelToTheLastColumnAndRow() throws {
        let ink = try colour("ink")
        for name in ["lockup-horizontal-on-black", "construction"] {
            let image = try pixels(name)
            XCTAssertTrue(image.isSRGB, "\(name).png is sRGB")
            var seams: [Int: UInt8] = [:]
            for y in 0..<image.height {
                for x in 0..<image.width where image.alpha(x, y) != 255 { seams[x] = image.alpha(x, y) }
            }
            XCTAssertEqual(seams, [:], "\(name).png: columns that are not opaque, with an alpha found in each")
        }
        let lockup = try pixels("lockup-horizontal-on-black")
        let edgeColours = Set(lockup.edge.map { lockup.alpha($0.0, $0.1) == 255 ? lockup.hex($0.0, $0.1) : "alpha \(lockup.alpha($0.0, $0.1))" })
        XCTAssertEqual(edgeColours, [ink], "the lockup on black's clear space is its ink ground to the edge")
    }

    /// The files without a ground are one colour, ink or paper, on transparency: every fully covered pixel is exactly that
    /// colour, and the clear space (half the cap height, 140 px, around the word and the lockups; one lattice step, 160 px,
    /// around the symbol) is empty to the file's edge, within the pixel a frame's fraction can round off.
    func testTheFilesWithoutAGroundAreOneColourInsideTheirClearSpace() throws {
        let ink = try colour("ink"), paper = try colour("paper")
        let capHeight = try XCTUnwrap(DesignTokensFile.shared.number("layout.brand.capHeight"))
        // The word and the lockups are 0.4 px a wordmark unit; the symbol 16 px a glyph unit, its lattice step 10 units.
        let wordClear = Int(capHeight / 2 * 0.4), symbolClear = 10 * 16
        let files: [(String, String, Int)] = [
            ("symbol", ink, symbolClear), ("symbol-white", paper, symbolClear),
            ("wordmark", ink, wordClear), ("wordmark-white", paper, wordClear),
            ("lockup-horizontal", ink, wordClear), ("lockup-horizontal-white", paper, wordClear),
        ]
        for (name, want, clear) in files {
            let image = try pixels(name)
            XCTAssertTrue(image.isSRGB, "\(name).png is sRGB")
            var colours = Set<String>(), minX = image.width, maxX = -1, minY = image.height, maxY = -1
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let alpha = image.alpha(x, y)
                    guard alpha > 0 else { continue }
                    if alpha == 255 { colours.insert(image.hex(x, y)) }
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            XCTAssertEqual(colours, [want], "\(name).png inks in \(want) and nothing else")
            let margins = [("left", minX), ("right", image.width - 1 - maxX), ("top", minY), ("bottom", image.height - 1 - maxY)]
            for (side, margin) in margins {
                XCTAssertGreaterThanOrEqual(margin, clear - 1, "\(name).png: the clear space on the \(side)")
            }
        }
    }
}
