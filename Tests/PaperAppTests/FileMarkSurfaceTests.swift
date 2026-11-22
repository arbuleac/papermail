import AppKit
import XCTest
@testable import PaperCore
@testable import PaperDesign
@testable import PaperApp

/// The file mark (spec §5.57) on the app's own surfaces: the composer's chip wears the reader's mark and words for the
/// same file, every label PaperCore's mapping can give fits the band, and every family has its ink.
@MainActor
final class FileMarkSurfaceTests: XCTestCase {
    override func tearDown() {
        QuireEnvironment.shared.setOverrides(.init())
        super.tearDown()
    }

    func testEveryFamilyHasItsInkAndEveryLabelFitsTheBand() {
        XCTAssertEqual(FileFamily.allCases.map(\.rawValue), Quire.FileInk.allCases.map(\.rawValue))
        for family in FileFamily.allCases {
            XCTAssertEqual(QuireFileMark(FileMark(family: family, label: "X", kind: "")).ink.rawValue, family.rawValue)
        }
        for (ext, mark) in FileMark.byExtension.merging(FileMark.tarballs, uniquingKeysWith: { a, _ in a }) {
            XCTAssertLessThanOrEqual(QuireFileMark.labelWidth(mark.label), QuireFileMark.labelRoom, "\(ext): \(mark.label) is squeezed")
        }
    }

    private func chip(_ attachment: ComposeAttachment) -> AttachmentChipView {
        let view = AttachmentChipView(attachment: attachment)
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The reader's chip, with remove in Download's place (spec §5.22): 44 pt, the mark at 8, the name over the meta in
    /// the reader's words, at most 264 pt.
    func testTheComposerChipIsTheReadersChipWithRemove() {
        let c = Quire.Layout.Composer.self
        XCTAssertEqual(c.stripChip, Quire.Layout.AttachmentChip.height)
        XCTAssertEqual(c.stripChipRadius, Quire.Layout.AttachmentChip.radius)
        XCTAssertEqual(c.stripChipMarkGap, Quire.Layout.AttachmentChip.gap)
        XCTAssertGreaterThanOrEqual(c.strip - c.stripChip, 16, "the chip has room in its band")
        let plan = chip(ComposeAttachment(filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 2_400_000, source: .data(Data())))
        XCTAssertEqual(plan.frame.height, 44)
        XCTAssertEqual(plan.metaText, "PDF \u{00B7} 2.4 MB")
        XCTAssertEqual(plan.markRect, NSRect(x: 8, y: 8, width: 28, height: 28))
        XCTAssertEqual(plan.accessibilityLabel(), "plan.pdf, PDF \u{00B7} 2.4 MB")
        let csv = ComposeAttachment(filename: "attendees.csv", mimeType: "text/csv", sizeBytes: 900, source: .data(Data()))
        XCTAssertEqual(csv.fileMark, FileMark(filename: "attendees.csv", mimeType: "text/csv"), "the reader's own mapping")
        XCTAssertEqual(chip(csv).metaText, "CSV \u{00B7} 900 B")
        let long = chip(ComposeAttachment(filename: String(repeating: "Quarterly report ", count: 8) + ".xlsx", mimeType: "",
                                          sizeBytes: 1, source: .data(Data())))
        XCTAssertEqual(long.frame.width, c.stripChipMaxWidth)
        let failed = chip(ComposeAttachment(filename: "huge.mov", mimeType: "video/quicktime", sizeBytes: 1,
                                            source: .data(Data()), state: .failed(short: "Too large", detail: "Too large for Gmail: 25 MB limit")))
        XCTAssertEqual(failed.metaText, "Too large")
        XCTAssertEqual(failed.accessibilityLabel(), "huge.mov, Too large for Gmail: 25 MB limit")
    }

    /// Its pixels: the band in the family's ink and the paper `raised` where the tokens put them, in Light and Dark; a
    /// failed chip draws the warning tile instead.
    func testTheComposerChipDrawsTheMark() throws {
        for mode in [QuireMode.light, .dark] {
            let rep = try XCTUnwrap(QuireOffscreenRenderer.render(mode: mode, scale: 2) {
                self.chip(ComposeAttachment(filename: "Q4.xlsx", mimeType: "", sizeBytes: 1_000, source: .data(Data())))
            })
            let band = mode.performAsCurrent { Quire.FileInk.spreadsheet.color.usingColorSpace(.sRGB) }!
            let paper = mode.performAsCurrent { NSColor.qRaised.usingColorSpace(.sRGB) }!
            assertPixel(rep, x: 8 + 4, y: 8 + 20, band, "\(mode) band")
            assertPixel(rep, x: 8 + 6, y: 8 + 5, paper, "\(mode) paper")
            let failed = try XCTUnwrap(QuireOffscreenRenderer.render(mode: mode, scale: 2) {
                self.chip(ComposeAttachment(filename: "Q4.xlsx", mimeType: "", sizeBytes: 1, source: .data(Data()),
                                            state: .failed(short: "Too large", detail: "Too large")))
            })
            let onTile = raw(failed, x: 8 + 4, y: 8 + 20)
            XCTAssertNotEqual(hex(onTile), hex(band), "\(mode): no band on a failed chip")
        }
    }

    // MARK: Pixels

    private func raw(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> (Double, Double, Double) {
        guard let data = rep.bitmapData else { return (0, 0, 0) }
        let offset = Int(y * 2) * rep.bytesPerRow + Int(x * 2) * rep.samplesPerPixel
        let a = Double(data[offset + 3]) / 255
        func ch(_ i: Int) -> Double { a > 0 ? min(1, Double(data[offset + i]) / 255 / a) : 0 }
        return (ch(0), ch(1), ch(2))
    }

    private func hex(_ c: (Double, Double, Double)) -> String {
        String(format: "#%02X%02X%02X", Int((c.0 * 255).rounded()), Int((c.1 * 255).rounded()), Int((c.2 * 255).rounded()))
    }

    private func hex(_ c: NSColor) -> String {
        hex((Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
    }

    private func assertPixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, _ expected: NSColor, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let p = raw(rep, x: x, y: y)
        for (a, e) in [(p.0, expected.redComponent), (p.1, expected.greenComponent), (p.2, expected.blueComponent)] {
            XCTAssertEqual(a, Double(e), accuracy: 2.5 / 255, "\(what): \(hex(p)) vs \(hex(expected))", file: file, line: line)
        }
    }
}
