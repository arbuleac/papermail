import AppKit
import XCTest
@testable import SSDesign

/// Script fallback keeps row metrics fixed (spec §4.4, §8.7): subjects in seven scripts are set with the role
/// the coverage check picks (New York or its SF Pro twin) and never grow past the role's line height.
final class RowMetricsTests: XCTestCase {
    private let samples: [(script: String, text: String, newYork: Bool)] = [
        ("Latin", "Lisbon in March? Booked the flat near Alfama", true),
        ("Cyrillic", "Встреча в четверг: повестка и материалы", true),
        ("Japanese", "来週の打ち合わせの議題について", false),
        ("Arabic", "جدول أعمال اجتماع الأسبوع القادم", false),
        ("Hebrew", "סדר היום לפגישה בשבוע הבא", false),
        ("Thai", "วาระการประชุมสัปดาห์หน้า", false),
        ("Devanagari", "अगले सप्ताह की बैठक का एजेंडा", false),
    ]

    /// Lays `text` out on one line with a layout manager prepared by `QuireFont.configure`, as rows and
    /// headers will, and returns the line fragment and used heights.
    private func layOut(_ string: NSAttributedString, width: CGFloat = 600) -> (fragment: CGFloat, used: CGFloat, lines: Int) {
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        QuireFont.configure(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var fragment: CGFloat = 0
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, _, _ in
            fragment = max(fragment, rect.height)
            lines += 1
        }
        return (fragment, manager.usedRect(for: container).height, lines)
    }

    func testCoverageCheckPicksNewYorkOrTheTwin() {
        for s in samples {
            let role = QuireFont.resolvedRole(.subject, for: s.text)
            XCTAssertEqual(role, s.newYork ? .subject : .subjectSans, "\(s.script) should be set in \(s.newYork ? "New York" : "SF Pro")")
            XCTAssertEqual(QuireFont.newYorkCovers(s.text), s.newYork, s.script)
        }
        // Digits, punctuation and emoji never force the twin; only letters count.
        XCTAssertTrue(QuireFont.newYorkCovers("Re: 3 × 4 = 12 — ok? 👍"))
        // A sans role is never swapped.
        XCTAssertEqual(QuireFont.resolvedRole(.sender, for: "来週"), .sender)
    }

    func testEveryScriptStaysWithinTheRoleLineHeight() {
        for role in [QuireFont.Role.subject, .headline, .reading, .composeSubject, .masthead] {
            for s in samples {
                for unread in [false, true] {
                    let string = QuireFont.attributedString(s.text, role: role, color: .black, unread: unread)
                    let used = QuireFont.resolvedRole(role, for: s.text)
                    XCTAssertEqual(used.lineHeight, role.lineHeight, "twins keep the line height")
                    let m = layOut(string)
                    XCTAssertEqual(m.lines, 1, "\(role) \(s.script)")
                    XCTAssertLessThanOrEqual(m.fragment, role.lineHeight + 0.001, "\(role) \(s.script) unread=\(unread): fragment \(m.fragment)")
                    XCTAssertLessThanOrEqual(m.used, role.lineHeight + 0.001, "\(role) \(s.script) unread=\(unread): used \(m.used)")
                }
            }
        }
    }

    func testStringDrawingAndLabelsHoldTheLineHeight() {
        // The other two ways a row or header puts a string on screen.
        for role in [QuireFont.Role.subject, .sender, .headline] {
            for s in samples {
                let string = QuireFont.attributedString(s.text, role: role, color: .black)
                let drawn = string.boundingRect(with: NSSize(width: 600, height: 200), options: QuireFont.drawingOptions)
                XCTAssertLessThanOrEqual(drawn.height, role.lineHeight + 0.001, "\(role) \(s.script) drawn")
                let label = NSTextField(labelWithAttributedString: string)
                XCTAssertLessThanOrEqual(label.cell!.cellSize.height, role.lineHeight + 0.001, "\(role) \(s.script) label")
            }
        }
    }

    func testSansRowLinesHoldTheirHeightToo() {
        for role in [QuireFont.Role.sender, .snippet, .meta, .runningHead, .writing] {
            for s in samples {
                let m = layOut(QuireFont.attributedString(s.text, role: role, color: .black))
                XCTAssertLessThanOrEqual(m.fragment, role.lineHeight + 0.001, "\(role) \(s.script)")
            }
        }
    }

    func testLatinLineIsExactlyTheRoleLineHeight() {
        // Min = max line height pins the fragment; the baseline offset centres the font's own line in it.
        let m = layOut(QuireFont.attributedString("Lisbon in March?", role: .subject, color: .black))
        XCTAssertEqual(m.fragment, 18, accuracy: 0.001)
        let font = QuireFont.font(.subject)
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        XCTAssertEqual(QuireFont.baselineOffset(.subject), (18 - natural) / 2, accuracy: 1e-9)
    }
}
