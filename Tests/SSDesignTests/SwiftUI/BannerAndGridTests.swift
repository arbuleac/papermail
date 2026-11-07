import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// `QuireBanner` against spec §5.38 and the `QuireSettingsGrid` family against §5.40.
@MainActor
final class BannerAndGridTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    // MARK: Banner

    func testVariantTokens() {
        XCTAssertEqual(QuireBannerVariant.neutral.face, QuireFill(wash: .fill))
        XCTAssertEqual(QuireBannerVariant.info.face, QuireFill(.infoWash))
        XCTAssertEqual(QuireBannerVariant.success.face, QuireFill(.successWash))
        XCTAssertEqual(QuireBannerVariant.warning.face, QuireFill(.warningWash))
        XCTAssertEqual(QuireBannerVariant.danger.face, QuireFill(.dangerWash))
        XCTAssertEqual(QuireBannerVariant.allCases.map(\.glyphColor), [.ink2, .info, .success, .warning, .danger])
        XCTAssertEqual(QuireBannerVariant.info.defaultGlyph, "info.circle")
        XCTAssertEqual(QuireBannerVariant.danger.defaultGlyph, "exclamationmark.triangle.fill")
        for variant in QuireBannerVariant.allCases {
            XCTAssertTrue(QuireSymbol.exists(variant.defaultGlyph), variant.rawValue)
        }
    }

    func testSingleLineBannerIs32PointsAndWrappedBannerGrows() {
        let b = Quire.Layout.Banner.self
        let line = QuireFont.Role.snippet.lineHeight
        let recorder = FrameRecorder()
        let long = "To add a Gmail account, SuperSparrow needs your own Google OAuth client ID. Enter it below and click Save, then try again."
        let view = VStack(spacing: 8) {
            QuireBanner(.info, "Demo mode: nothing syncs.", link: ("Leave demo…", {}), onDismiss: {}).recordFrame("one", in: recorder)
            QuireBanner(.info, long, link: ("How to create one…", {})).recordFrame("two", in: recorder)
            QuireBanner(.danger, long, wraps: false).recordFrame("truncated", in: recorder)
        }
        .frame(width: 512)
        let host = SwiftUIHost(view)
        XCTAssertEqual(recorder["one"].height, b.height)
        let two = recorder["two"].height
        let lines = ((two - 2 * b.padY) / line).rounded()
        XCTAssertGreaterThanOrEqual(lines, 2, "the long notice wraps")
        XCTAssertEqual(two, 2 * b.padY + lines * line, accuracy: 0.5, "8 pt above and below, one snippet line per line")
        XCTAssertEqual(recorder["truncated"].height, b.height, "wraps: false keeps one truncating line")
        host.close()
    }

    func testRenderedBannerFaceAndGlyphInset() {
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.pinned(mode))
            for variant in QuireBannerVariant.allCases {
                let view = QuireBanner(variant, "Words").frame(width: 200).padding(4).background(Color.qSheet)
                let host = SwiftUIHost(view, mode: mode)
                let rep = host.render()
                XCTAssertColor(rep.srgb(at: CGPoint(x: 4 + 190, y: 4 + 16)), Expected.color(variant.face, over: .sheet, mode),
                               "\(variant) \(mode)")
                host.close()
            }
        }
    }

    // MARK: Settings grid

    /// Rows are measured through the controls inside them: a modifier on a grid row itself would turn it into a
    /// full-width cell (see `QuireSettingsGrid`).
    func testGridColumnsRowsCaptionsAndDivider() {
        let s = Quire.Layout.Settings.self
        let recorder = FrameRecorder()
        let view = QuireSettingsGrid {
            QuireSettingsSection("Google", isFirst: true)
            QuireSettingsRow("Client ID") {
                TextField("", text: .constant("")).quireFieldStyle(.mono).recordFrame("field", in: recorder)
            }
            QuireSettingsRow("Tenant") {
                Color.clear.frame(height: 1).recordFrame("control2", in: recorder)
            }
            QuireSettingsCaption("Register a Desktop app client.")
            QuireSettingsDivider()
            QuireSettingsSection("Microsoft")
            QuireSettingsRow("Remote images") {
                Toggle("Load by default", isOn: .constant(true)).toggleStyle(.quire).recordFrame("toggle", in: recorder)
            }
        }
        .recordFrame("grid", in: recorder)
        .frame(width: s.width - 2 * s.padX)
        let host = SwiftUIHost(view)
        let grid = recorder["grid"]
        let field = recorder["field"]
        XCTAssertEqual(field.minX - grid.minX, s.labelColumn + s.labelGap, "controls start 12 pt after the 140 pt label column")
        XCTAssertEqual(field.width, s.fieldWidth, accuracy: 0.5, "fields fill to the content padding: 360 pt at 560")
        XCTAssertEqual(field.height, s.fieldHeight)
        let title = QuireFont.Role.title.lineHeight
        XCTAssertEqual(field.midY - grid.minY, title + s.row / 2, accuracy: 0.5,
                       "the first row follows the first title, its control centred in 40 pt")
        let control2 = recorder["control2"]
        XCTAssertEqual(control2.midY - field.midY, s.row, accuracy: 0.5, "rows are 40 pt")
        // Between the Tenant row's centre and the toggle's: half a row, a one-line caption (8 pt under the
        // field, which ends 8 pt above the row's edge), the 40 pt divider slot, the second section (20 pt gap
        // and its title), and half a row.
        let expected = s.row / 2 + QuireSettingsCaption.topPadding + QuireFont.Role.meta.lineHeight + s.row + s.sectionGap + title + s.row / 2
        XCTAssertEqual(QuireSettingsCaption.topPadding, 0, "a 24 pt control already ends 8 pt above its 40 pt row's edge")
        XCTAssertEqual(recorder["toggle"].midY - control2.midY, expected, accuracy: 0.5)
        XCTAssertEqual(recorder["toggle"].minX - grid.minX, s.labelColumn + s.labelGap)
        host.close()
    }

    func testCaptionAndDividerDrawWhereTheSpecPutsThem() {
        let s = Quire.Layout.Settings.self
        let recorder = FrameRecorder()
        let view = QuireSettingsGrid {
            QuireSettingsRow("Tenant") { Color.clear.frame(height: 1).recordFrame("control", in: recorder) }
            QuireSettingsCaption("Register a Desktop app client.")
            QuireSettingsDivider()
        }
        .recordFrame("grid", in: recorder)
        .frame(width: s.width - 2 * s.padX)
        .background(Color.qCanvas)
        let host = SwiftUIHost(view)
        let rep = host.render()
        let grid = recorder["grid"]
        let captionTop = recorder["control"].midY + s.row / 2
        let canvas = TokenResolver.resolve("canvas", .light)
        func hasInk(_ xs: StrideTo<CGFloat>, _ ys: StrideTo<CGFloat>) -> Bool {
            for x in xs { for y in ys where rep.srgb(at: CGPoint(x: x, y: y)) != canvas { return true } }
            return false
        }
        let captionLine = stride(from: captionTop, to: captionTop + QuireFont.Role.meta.lineHeight, by: 0.5)
        XCTAssertTrue(hasInk(stride(from: grid.minX + s.labelColumn + s.labelGap, to: grid.minX + s.labelColumn + s.labelGap + 8, by: 0.5), captionLine),
                      "the caption starts in the field column")
        XCTAssertFalse(hasInk(stride(from: grid.minX, to: grid.minX + s.labelColumn, by: 2), captionLine), "nothing in the label column")
        let dividerY = captionTop + QuireFont.Role.meta.lineHeight + s.row / 2
        XCTAssertColor(rep.srgb(at: CGPoint(x: grid.minX + 2, y: dividerY + 0.25)), TokenResolver.resolve("rule", .light),
                       "the hairline runs from the content's leading edge, centred in its slot")
        XCTAssertColor(rep.srgb(at: CGPoint(x: grid.maxX - 2, y: dividerY + 0.25)), TokenResolver.resolve("rule", .light),
                       "to its trailing edge")
        host.close()
    }

    /// `Grid` measures second-column cells at an even share of its width while it settles the columns; a
    /// wrapping caption measured that narrow reserved a line it never drew, and the stack squeezed the banner
    /// beside it from 46 to 32 pt to pay for it.
    func testWrappedCaptionMeasuresAsItDrawsAndSqueezesNothing() {
        let s = Quire.Layout.Settings.self
        let recorder = FrameRecorder()
        let caption = "Register a Desktop app client in Google Cloud Console with the Gmail API enabled, and a Mobile and desktop app."
        let long = "To add a Gmail account, SuperSparrow needs your own Google OAuth client ID. Enter it below and click Save, then try again."
        let view = VStack(alignment: .leading, spacing: 24) {
            QuireSettingsGrid {
                QuireSettingsRow("Tenant") { Text("common").recordFrame("first", in: recorder) }
                QuireSettingsCaption(caption)
                QuireSettingsRow(nil) { Text("Save").recordFrame("next", in: recorder) }
            }
            .frame(width: s.width - 2 * s.padX)
            QuireBanner(.info, long).frame(width: s.width - 2 * s.padX).recordFrame("banner", in: recorder)
        }
        let host = SwiftUIHost(view)
        let lines = 2 * QuireFont.Role.meta.lineHeight
        XCTAssertEqual(recorder["next"].midY - recorder["first"].midY, s.row + lines, accuracy: 0.5,
                       "the caption takes exactly its two drawn lines")
        XCTAssertEqual(recorder["banner"].height, 2 * Quire.Layout.Banner.padY + 2 * QuireFont.Role.snippet.lineHeight, accuracy: 0.5,
                       "and the banner keeps its full height")
        host.close()
    }

    func testTextRowGrowsByOneLinePerExtraLineUpToItsCap() {
        let s = Quire.Layout.Settings.self
        let line = QuireFont.Role.meta.lineHeight
        let words = { (n: Int) in Array(repeating: "Gmail returned an unexpected response.", count: n).joined(separator: " ") }
        let recorder = FrameRecorder()
        let view = QuireSettingsGrid {
            QuireSettingsRow("Colour") { Text("a").recordFrame("a", in: recorder) }
            QuireSettingsTextRow("Last error", text: words(1))
            QuireSettingsRow(nil) { Text("b").recordFrame("b", in: recorder) }
            QuireSettingsTextRow("Last error", text: words(3))
            QuireSettingsRow(nil) { Text("c").recordFrame("c", in: recorder) }
            QuireSettingsTextRow("Last error", text: words(20))
            QuireSettingsRow(nil) { Text("d").recordFrame("d", in: recorder) }
        }
        .frame(width: s.width - 2 * s.padX)
        let host = SwiftUIHost(view)
        let rowOf = { (from: String, to: String) in recorder[to].midY - recorder[from].midY - s.row }
        XCTAssertEqual(rowOf("a", "b"), s.row, accuracy: 0.5, "one line: a 40 pt row")
        let three = rowOf("b", "c")
        XCTAssertGreaterThan(three, s.row, "three sentences wrap")
        XCTAssertEqual((three - s.row).truncatingRemainder(dividingBy: line), 0, accuracy: 0.5, "each extra line adds 14 pt")
        XCTAssertEqual(rowOf("c", "d"), s.row + (s.lastErrorMaxLines - 1) * line, accuracy: 0.5, "never more than three lines")
        host.close()
    }

    func testRowLabelIsRightAlignedInTheColumn() {
        let s = Quire.Layout.Settings.self
        let recorder = FrameRecorder()
        let view = QuireSettingsGrid {
            QuireSettingsRow("Undo send") { Color.clear.frame(width: 10, height: 10) }
        }
        .recordFrame("grid", in: recorder)
        let host = SwiftUIHost(view.padding(10).background(Color.qCanvas))
        let rep = host.render()
        let grid = recorder["grid"]
        let width = ("Undo send" as NSString).size(withAttributes: [.font: QuireFont.font(.body)]).width
        // Ink right at the column's trailing edge, none at its leading edge.
        var inkNearEnd = false
        for x in stride(from: grid.minX + s.labelColumn - 6, to: grid.minX + s.labelColumn, by: 0.5) {
            for y in stride(from: grid.midY - 4, to: grid.midY + 4, by: 0.5) {
                let c = rep.srgb(at: CGPoint(x: x, y: y))
                if c.r < 0.5 { inkNearEnd = true }
            }
        }
        XCTAssertTrue(inkNearEnd, "the label ends at the column's trailing edge")
        XCTAssertColor(rep.srgb(at: CGPoint(x: grid.minX + s.labelColumn - width - 3, y: grid.midY)), TokenResolver.resolve("canvas", .light),
                       "nothing before the label's start")
        host.close()
    }
}
