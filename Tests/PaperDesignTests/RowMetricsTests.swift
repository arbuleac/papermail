import AppKit
import XCTest
@testable import PaperDesign

/// Script fallback keeps row metrics fixed (spec §4.4, §8.7): subjects in seven scripts are set with the role
/// the coverage check picks (New York or its SF Pro twin) and never grow past the role's line height, at each of
/// the four Text sizes (spec §4.15), where the line height is the role's at that size.
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

    private let sizes = QuireFont.TextSize.allCases

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
        for size in sizes {
            for role in [QuireFont.Role.subject, .headline, .reading, .composeSubject, .masthead] {
                let line = role.lineHeight(at: size)
                for s in samples {
                    for unread in [false, true] {
                        let string = QuireFont.attributedString(s.text, role: role, color: .black, unread: unread, textSize: size)
                        let used = QuireFont.resolvedRole(role, for: s.text)
                        XCTAssertEqual(used.lineHeight(at: size), line, "twins keep the line height at \(size)")
                        let m = layOut(string)
                        XCTAssertEqual(m.lines, 1, "\(role) \(s.script) \(size)")
                        XCTAssertLessThanOrEqual(m.fragment, line + 0.001, "\(role) \(s.script) unread=\(unread) \(size): fragment \(m.fragment)")
                        XCTAssertLessThanOrEqual(m.used, line + 0.001, "\(role) \(s.script) unread=\(unread) \(size): used \(m.used)")
                    }
                }
            }
        }
    }

    func testStringDrawingAndLabelsHoldTheLineHeight() {
        // The other two ways a row or header puts a string on screen.
        for size in sizes {
            for role in [QuireFont.Role.subject, .sender, .headline] {
                let line = role.lineHeight(at: size)
                for s in samples {
                    let string = QuireFont.attributedString(s.text, role: role, color: .black, textSize: size)
                    let drawn = string.boundingRect(with: NSSize(width: 600, height: 200), options: QuireFont.drawingOptions)
                    XCTAssertLessThanOrEqual(drawn.height, line + 0.001, "\(role) \(s.script) \(size) drawn")
                    let label = NSTextField(labelWithAttributedString: string)
                    XCTAssertLessThanOrEqual(label.cell!.cellSize.height, line + 0.001, "\(role) \(s.script) \(size) label")
                }
            }
        }
    }

    func testSansRowLinesHoldTheirHeightToo() {
        for size in sizes {
            for role in [QuireFont.Role.sender, .snippet, .meta, .runningHead, .writing] {
                for s in samples {
                    let m = layOut(QuireFont.attributedString(s.text, role: role, color: .black, textSize: size))
                    XCTAssertLessThanOrEqual(m.fragment, role.lineHeight(at: size) + 0.001, "\(role) \(s.script) \(size)")
                }
            }
        }
    }

    func testLatinLineIsExactlyTheRoleLineHeight() {
        // Min = max line height pins the fragment; the baseline offset centres the font's own line in it.
        for (size, line) in zip(sizes, [17, 18, 19, 20] as [CGFloat]) {
            let m = layOut(QuireFont.attributedString("Lisbon in March?", role: .subject, color: .black, textSize: size))
            XCTAssertEqual(m.fragment, line, accuracy: 0.001, "\(size)")
            let font = QuireFont.font(.subject, textSize: size)
            let natural = NSLayoutManager().defaultLineHeight(for: font)
            XCTAssertEqual(QuireFont.baselineOffset(.subject, textSize: size), (line - natural) / 2, accuracy: 1e-9, "\(size)")
        }
    }

    /// A row's lines, set at each Text size, fit the line boxes `QuireRowMetrics` gives them, so nothing is clipped
    /// and the lines never touch.
    func testRowLinesFitTheirBoxesAtEverySize() {
        for size in sizes {
            for compact in [false, true] {
                let m = QuireRowMetrics(textSize: size, compact: compact)
                let lines: [(QuireFont.Role, CGFloat, CGFloat)] = compact
                    ? [(.sender, m.senderY, m.senderHeight), (.subject, m.subjectY, m.subjectHeight)]
                    : [(.sender, m.senderY, m.senderHeight), (.subject, m.subjectY, m.subjectHeight), (.snippet, m.snippetY, m.snippetHeight)]
                var bottom: CGFloat = 0
                for (role, top, height) in lines {
                    XCTAssertEqual(height, role.lineHeight(at: size), "\(role) \(size) compact=\(compact): the box is the role's line")
                    XCTAssertGreaterThan(top, bottom, "\(role) \(size) compact=\(compact): below the line above, with a gap")
                    for s in samples {
                        let drawn = QuireFont.attributedString(s.text, role: role, color: .black, textSize: size)
                            .boundingRect(with: NSSize(width: 600, height: 200), options: QuireFont.drawingOptions)
                        XCTAssertLessThanOrEqual(drawn.height, height + 0.001, "\(role) \(s.script) \(size)")
                    }
                    bottom = top + height
                }
                XCTAssertLessThan(bottom, m.height, "\(size) compact=\(compact): the last line ends inside the row")
                XCTAssertLessThanOrEqual(m.timeHeight, m.senderHeight, "\(size): the time sits on the sender line")
            }
        }
    }
}
