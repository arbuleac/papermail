import AppKit
import XCTest
@testable import SSDesign

/// The file mark (spec §5.57): its geometry is the tokens', its inks are the palette's in every mode and theme, and
/// what it draws lands where the tokens say, in the colours they name.
@MainActor
final class QuireFileMarkTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private typealias M = Quire.Layout.FileMark

    // MARK: Metrics

    func testGeometryIsTheTokens() throws {
        XCTAssertEqual(M.grid, Quire.Layout.AttachmentChip.tile, "the chip's tile is the grid, drawn 1:1")
        XCTAssertEqual(QuireFileMark.bandRect, CGRect(x: 3, y: 15, width: 22, height: 10))
        XCTAssertEqual(QuireFileMark.labelRoom, 21)
        // The outline runs on the edge's centre line, so the stroke's outer side is the sheet's box.
        let sheet = try QuireSVGPath.parse(M.sheetPath).boundingBoxOfPath
        XCTAssertEqual(sheet.insetBy(dx: -M.edge / 2, dy: -M.edge / 2), CGRect(x: M.sheetX, y: 0, width: M.sheetWidth, height: M.grid))
        let fold = try QuireSVGPath.parse(M.foldPath).boundingBoxOfPath
        XCTAssertEqual(fold.width, M.fold, accuracy: 0.001)
        XCTAssertEqual(fold.height, M.fold, accuracy: 0.001)
        XCTAssertLessThan(fold.maxY, QuireFileMark.bandRect.minY, "the fold ends above the band")
        XCTAssertEqual(QuireFileMark(ink: .pdf, label: "ABCDEFG").label, "ABCD", "at most labelMax characters")
    }

    /// SF Pro at the tokens' size, set on the variable font's own weight and width axes, which WebKit sets for the reader's
    /// `font-weight: 700; font-stretch: 60%`.
    func testLabelFontIsSFProOnItsOwnAxes() throws {
        let font = QuireFileMark.labelFont
        XCTAssertEqual(CTFontGetSize(font), M.labelSize)
        let variation = try XCTUnwrap(CTFontCopyVariation(font) as? [Int: Double])
        XCTAssertEqual(variation[0x7764_7468], Double(M.labelWidth), "wdth")
        XCTAssertEqual(variation[0x7767_6874], Double(M.labelWeight), "wght")
        // The system font, whose face is SF Pro (WebKit's `-apple-system`).
        XCTAssertEqual(CTFontCopyFamilyName(font) as String, CTFontCopyFamilyName(NSFont.systemFont(ofSize: 8) as CTFont) as String)
        // Four capitals of the narrowest width fit the band; only wide unknown types are squeezed.
        for label in ["PDF", "XLS", "HEIC", "WEBM", "JSON", "HTML", "TZST", "MBOX", "AIFF"] {
            XCTAssertLessThanOrEqual(QuireFileMark.labelWidth(label), QuireFileMark.labelRoom, label)
        }
        XCTAssertGreaterThan(QuireFileMark.labelWidth("WMWM"), QuireFileMark.labelRoom)
    }

    // MARK: Colours

    func testInksAreThePaletteInEveryModeAndTheme() throws {
        let palette = try XCTUnwrap(DesignTokensFile.shared.array("filePalette") as? [[String: Any]])
        XCTAssertEqual(palette.compactMap { ($0["name"] as? String)?.lowercased() }, Quire.FileInk.allCases.map(\.rawValue))
        for theme in QuireTheme.allCases {
            QuireTestEnvironment.forceDefaults(theme: theme)
            for (ink, values) in zip(Quire.FileInk.allCases, palette) {
                for mode in QuireMode.allCases {
                    let expected = try XCTUnwrap(values[mode.tokenKey] as? String)
                    XCTAssertEqual(hex(TokenResolver.rgba(ink.color, mode)), expected, "\(ink.name) \(mode) in \(theme)")
                    XCTAssertEqual(hex(TokenResolver.rgba(.qFileLabel, mode)), "#FFFFFF")
                }
            }
        }
    }

    // MARK: Pixels

    private func render(_ mark: QuireFileMark, _ mode: QuireMode, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        try XCTUnwrap(QuireOffscreenRenderer.render(mode: mode, scale: scale) { QuireFileMarkView(mark) })
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat, scale: CGFloat = 2) -> RGBA {
        // The stored bytes: the bitmap is tagged sRGB, and `colorAt` would convert through a calibrated space.
        ComponentSnapshot.rgba(of: rep, x: Int(x * scale), y: Int(y * scale))
    }

    private func assertColor(_ actual: RGBA, _ expected: RGBA, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for (a, e) in [(actual.r, expected.r), (actual.g, expected.g), (actual.b, expected.b), (actual.a, expected.a)] {
            XCTAssertEqual(a, e, accuracy: 2.5 / 255, "\(what): \(hex(actual)) vs \(hex(expected))", file: file, line: line)
        }
    }

    /// Paper, fold, edge, band and the corner the fold leaves open, in every mode, in Study and in Dusk's deeper night.
    func testDrawsTheSheetFoldEdgeAndBandWhereTheTokensSay() throws {
        for theme in [QuireTheme.study, .dusk] {
            QuireTestEnvironment.forceDefaults(theme: theme)
            for mode in QuireMode.allCases {
                let rep = try render(QuireFileMark(ink: .spreadsheet, label: "XLS"), mode)
                let raised = TokenResolver.resolve("raised", mode)
                assertColor(pixel(rep, 6, 5), raised, "paper, \(mode)")
                assertColor(pixel(rep, 6, 26.5), raised, "paper under the band, \(mode)")
                assertColor(pixel(rep, 20.5, 5.5), TokenResolver.resolveStack(["raised", "fill"], mode), "the fold's face, \(mode)")
                assertColor(pixel(rep, 2.5, 12), TokenResolver.resolve("ruleStrong", mode), "the edge, \(mode)")
                assertColor(pixel(rep, 4, 20), TokenResolver.rgba(Quire.FileInk.spreadsheet.color, mode), "the band, \(mode)")
                XCTAssertEqual(pixel(rep, 25, 1).a, 0, accuracy: 0.01, "the folded corner is open, \(mode)")
                XCTAssertEqual(pixel(rep, 1, 14).a, 0, accuracy: 0.01, "nothing beside the sheet, \(mode)")
                // The label: white pixels inside the band, and only there.
                var white = 0
                for y in stride(from: 15.25, to: 25, by: 0.5) {
                    for x in stride(from: 3.25, to: 25, by: 0.5) where pixel(rep, x, y).r > 0.95 && pixel(rep, x, y).b > 0.95 { white += 1 }
                }
                XCTAssertGreaterThan(white, 20, "the label is drawn, \(mode)")
            }
        }
    }

    func testAnEmptyLabelIsAPlainSheet() throws {
        for mode in [QuireMode.light, .dark] {
            let rep = try render(QuireFileMark(ink: .other, label: ""), mode)
            assertColor(pixel(rep, 4, 20), TokenResolver.resolve("raised", mode), "no band, \(mode)")
            assertColor(pixel(rep, 14, 20), TokenResolver.resolve("raised", mode), "no label, \(mode)")
        }
    }

    /// At 1x the edge lands on whole pixels: the outline's column is solid, the paper beside it untouched.
    func testTheEdgeIsCrispAtOneX() throws {
        let rep = try render(QuireFileMark(ink: .pdf, label: "PDF"), .light, scale: 1)
        assertColor(pixel(rep, 2, 12, scale: 1), TokenResolver.resolve("ruleStrong", .light), "edge pixel")
        assertColor(pixel(rep, 3, 12, scale: 1), TokenResolver.resolve("raised", .light), "paper pixel")
        assertColor(pixel(rep, 3, 20, scale: 1), TokenResolver.rgba(Quire.FileInk.pdf.color, .light), "band pixel at its edge")
    }

    func testTheViewIsDecorativeAndSizedToTheGrid() {
        let view = QuireFileMarkView(QuireFileMark(ink: .pdf, label: "PDF"))
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 28, height: 28))
        XCTAssertFalse(view.isAccessibilityElement())
        XCTAssertEqual(QuireFileMarkView(nil, side: 32).intrinsicContentSize, NSSize(width: 32, height: 32))
    }

    private func hex(_ c: RGBA) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }
}

private extension QuireMode {
    var tokenKey: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        case .lightHC: return "lightHC"
        case .darkHC: return "darkHC"
        }
    }
}
