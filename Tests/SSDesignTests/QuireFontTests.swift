import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// The §8.2 font recipe: families, weights, italic, tabular digits, attributes and caching.
final class QuireFontTests: XCTestCase {
    private func design(_ font: NSFont) -> String {
        // The design shows in the font's PostScript name: New York is ".NewYork…", Rounded "…Rounded…".
        font.fontName
    }

    func testFamilies() {
        XCTAssertTrue(design(QuireFont.font(.subject)).localizedCaseInsensitiveContains("NewYork"), design(QuireFont.font(.subject)))
        XCTAssertFalse(design(QuireFont.font(.sender)).localizedCaseInsensitiveContains("NewYork"))
        XCTAssertTrue(design(QuireFont.font(.badge)).localizedCaseInsensitiveContains("Rounded"), design(QuireFont.font(.badge)))
        XCTAssertTrue(QuireFont.font(.mono).isFixedPitch, design(QuireFont.font(.mono)))
        XCTAssertEqual(QuireFont.font(.subject).pointSize, 14)
        XCTAssertEqual(QuireFont.font(.headline).pointSize, 24)
        XCTAssertEqual(QuireFont.font(.meta).pointSize, 11)
    }

    func testWeightsAndUnread() {
        func weight(_ f: NSFont) -> CGFloat {
            let traits = f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        }
        XCTAssertEqual(weight(QuireFont.font(.body)), NSFont.Weight.regular.rawValue, accuracy: 0.01)
        XCTAssertEqual(weight(QuireFont.font(.bodyMedium)), NSFont.Weight.medium.rawValue, accuracy: 0.01)
        XCTAssertEqual(weight(QuireFont.font(.bodyStrong)), NSFont.Weight.semibold.rawValue, accuracy: 0.01)
        XCTAssertEqual(weight(QuireFont.font(.sender, unread: true)), NSFont.Weight.semibold.rawValue, accuracy: 0.01)
        // A role without an unread weight ignores the flag and shares the cached font.
        XCTAssertTrue(QuireFont.font(.snippet, unread: true) === QuireFont.font(.snippet))
        XCTAssertTrue(QuireFont.font(.subject) === QuireFont.font(.subject), "cached per role")
        XCTAssertEqual(QuireFont.fontWeight(600), .semibold)
        XCTAssertEqual(QuireFont.fontWeight(400), .regular)
    }

    func testItalicAndTabular() {
        XCTAssertTrue(QuireFont.font(.aside).fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(QuireFont.font(.asideSans).fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(QuireFont.font(.reading).fontDescriptor.symbolicTraits.contains(.italic))
        // Tabular digits: every digit advances the same.
        let font = QuireFont.font(.meta)
        let widths = "0123456789".map { NSAttributedString(string: String($0), attributes: [.font: font]).size().width }
        XCTAssertEqual(Set(widths.map { ($0 * 100).rounded() }).count, 1, "\(widths)")
    }

    func testMonogramSizes() {
        // 0.42 × d rounded to the half point, never below 10 (spec §4.3, §5.29).
        XCTAssertEqual(QuireFont.monogramSize(diameter: 24), 10)
        XCTAssertEqual(QuireFont.monogramSize(diameter: 30), 12.5)
        XCTAssertEqual(QuireFont.monogramSize(diameter: 36), 15)
        XCTAssertEqual(QuireFont.monogramSize(diameter: 16), 10)
        XCTAssertEqual(QuireFont.monogramFont(diameter: 30).pointSize, 12.5)
        XCTAssertEqual(QuireFont.Role.monogram.lineHeight, 10, "1.0 × the minimum size")
    }

    func testParagraphStyleAndAttributes() {
        let style = QuireFont.paragraphStyle(.subject)
        XCTAssertEqual(style.minimumLineHeight, 18)
        XCTAssertEqual(style.maximumLineHeight, 18)
        XCTAssertEqual(style.lineBreakMode, .byTruncatingTail)
        XCTAssertFalse(style.allowsDefaultTighteningForTruncation)
        XCTAssertEqual(style.baseWritingDirection, .natural)
        XCTAssertEqual(style.alignment, .left)

        let a = QuireFont.attributes(.runningHead, color: .qInk3)
        XCTAssertNil(a[.kern], "sentence case at the system's own tracking (1.8.7)")
        XCTAssertTrue(a[.font] as? NSFont === QuireFont.font(.runningHead))
        XCTAssertNotNil(a[.baselineOffset] as? CGFloat)
        // Zero tracking leaves kerning to the font: an explicit 0 would switch it off.
        XCTAssertNil(QuireFont.attributes(.body, color: .qInk)[.kern])
        XCTAssertEqual(QuireFont.attributes(.display, color: .qInk)[.kern] as? CGFloat, -0.6)
    }

    func testAttributedStringKeepsTheWordsAndFallsBack() {
        // No role is uppercased (1.8.7): a running head reads as it is written.
        let head = QuireFont.attributedString("Yesterday", role: .runningHead, color: .qInk3, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(head.string, "Yesterday")
        XCTAssertNil(head.attribute(.kern, at: 0, effectiveRange: nil), "the system's own tracking")
        XCTAssertFalse(QuireFont.Role.allCases.contains(where: \.uppercase), "no role is set in capitals")
        let cjk = QuireFont.attributedString("来週の議題", role: .subject, color: .qInk)
        XCTAssertTrue((cjk.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) === QuireFont.font(.subjectSans))
        let latin = QuireFont.attributedString("Agenda", role: .subject, color: .qInk, unread: true)
        XCTAssertTrue((latin.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) === QuireFont.font(.subject, unread: true))
        XCTAssertTrue(QuireFont.font(.reading, for: "Привет") === QuireFont.font(.reading))
        XCTAssertTrue(QuireFont.font(.reading, for: "مرحبا") === QuireFont.font(.readingSans))
    }

    func testStaticAccessorsAndSwiftUI() {
        XCTAssertTrue(QuireFont.subject === QuireFont.font(.subject))
        XCTAssertTrue(QuireFont.bodyStrong === QuireFont.font(.bodyStrong))
        _ = Font.quire(.body)
        _ = Font.quire(.subject, unread: true)
    }

    func testFontsCanBeBuiltOffTheMainThread() {
        let done = expectation(description: "background fonts")
        done.expectedFulfillmentCount = 8
        for i in 0..<8 {
            DispatchQueue.global().async {
                let role = QuireFont.Role.allCases[(i * 5) % QuireFont.Role.allCases.count]
                _ = QuireFont.attributedString("Off main \(i)", role: role, color: .qInk)
                _ = QuireFont.newYorkCovers("Ünïcödé \(i)")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
    }
}
