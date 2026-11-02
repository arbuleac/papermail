import AppKit
import XCTest
@testable import SSDesign

final class QuireSymbolTests: XCTestCase {
    func testDefaultSizesAreTheSpecs() {
        XCTAssertEqual(QuireSymbolSize.window, .init(pointSize: 15))
        XCTAssertEqual(QuireSymbolSize.inText, .init(pointSize: 14))
        XCTAssertEqual(QuireSymbolSize.row, .init(pointSize: 12, weight: .semibold))
        XCTAssertEqual(QuireSymbolSize.rail, .init(pointSize: 18))
    }

    func testEveryIconTheAppDrawsExists() {
        // `icon` is the full symbol map (spec §4.11): every entry must draw, SF Symbol or custom glyph.
        let icons = DesignTokensFile.shared.object("icon") as! [String: String]
        for (action, name) in icons.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(QuireSymbol.exists(name), "icon.\(action) = \(name)")
            XCTAssertNotNil(QuireSymbol.image(name, size: .row), "icon.\(action) = \(name)")
        }
        for name in Quire.readerSymbols {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "readerSymbols: \(name)")
        }
    }

    func testCustomGlyphsComeThroughTheSameCall() {
        let nib = QuireSymbol.image(Quire.Icon.compose, size: .custom(Quire.Layout.ListHeader.composeGlyph))
        XCTAssertNotNil(nib)
        XCTAssertEqual(nib?.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(nib?.isTemplate ?? false)
        let labelled = QuireSymbol.image(Quire.Icon.compose, size: .window, accessibilityDescription: "New Message")
        XCTAssertEqual(labelled?.accessibilityDescription, "New Message")
        XCTAssertEqual(QuireGlyph.image(.ssNib, pointSize: 15).accessibilityDescription, Quire.CustomGlyph.ssNib.meaning,
                       "labelling a copy leaves the cached image alone")
    }

    func testSystemSymbolsAreTemplates() {
        let archive = QuireSymbol.image(Quire.Icon.archive, size: .window)
        XCTAssertNotNil(archive)
        XCTAssertTrue(archive?.isTemplate ?? false)
        XCTAssertNil(QuireSymbol.image("no.such.symbol.quire"))
    }
}
