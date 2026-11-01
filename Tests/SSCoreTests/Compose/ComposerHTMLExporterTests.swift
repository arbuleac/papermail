import AppKit
import XCTest
@testable import SSCore

final class ComposerHTMLExporterTests: XCTestCase {
    private let regular = NSFont.systemFont(ofSize: 13)
    private let bold = NSFont.boldSystemFont(ofSize: 13)
    private var italic: NSFont { NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask) }

    private func paragraph(_ text: String, block: ComposerBlock = .paragraph, font: NSFont? = nil, extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font ?? regular]
        if block != .paragraph { attributes[ComposerBlock.attributeKey] = block.rawValue }
        for (key, value) in extra { attributes[key] = value }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func join(_ parts: [NSAttributedString]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            result.append(part)
            if index < parts.count - 1 {
                // The newline takes the attributes of the paragraph it ends, as the text view does.
                result.append(NSAttributedString(string: "\n", attributes: part.length > 0 ? part.attributes(at: part.length - 1, effectiveRange: nil) : [:]))
            }
        }
        return result
    }

    func testBoldLinkListAndQuote() {
        let first = NSMutableAttributedString(string: "Hello ", attributes: [.font: regular])
        first.append(NSAttributedString(string: "world", attributes: [.font: bold]))
        first.append(NSAttributedString(string: ", see ", attributes: [.font: regular]))
        first.append(NSAttributedString(string: "the docs", attributes: [.font: regular, .link: URL(string: "https://example.com/docs?a=1&b=2")!]))
        first.append(NSAttributedString(string: ".", attributes: [.font: regular]))

        let body = join([
            first,
            paragraph("One", block: .bulletItem),
            paragraph("Two & three", block: .bulletItem),
            paragraph("First", block: .numberedItem),
            paragraph("Second", block: .numberedItem),
            paragraph("A quoted <line>", block: .quote),
            paragraph("Bye", font: italic, extra: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
        ])

        let output = ComposerHTMLExporter().export(body)
        XCTAssertEqual(
            output.html,
            "<div>"
                + "<p>Hello <b>world</b>, see <a href=\"https://example.com/docs?a=1&amp;b=2\">the docs</a>.</p>"
                + "<ul><li>One</li><li>Two &amp; three</li></ul>"
                + "<ol><li>First</li><li>Second</li></ol>"
                + "<blockquote><p>A quoted &lt;line&gt;</p></blockquote>"
                + "<p><i><u>Bye</u></i></p>"
                + "</div>"
        )
        XCTAssertEqual(
            output.text,
            "Hello world, see the docs <https://example.com/docs?a=1&b=2>.\n"
                + "- One\n- Two & three\n"
                + "1. First\n2. Second\n"
                + "> A quoted <line>\n"
                + "Bye"
        )
    }

    func testEmptyBodyWithQuotedOriginal() {
        let quoted = QuotedReply.Rendering(html: "<blockquote class=\"ss-reply-quote\"><p>Original</p></blockquote>", text: "> Original")
        let output = ComposerHTMLExporter().export(NSAttributedString(string: ""), appending: quoted)
        XCTAssertEqual(output.html, "<div><p><br></p></div>\n" + quoted.html)
        XCTAssertEqual(output.text, "\n\n> Original")
    }

    func testTypedContentPrecedesQuoteVerbatim() {
        let quoted = QuotedReply.Rendering(html: "<div class=\"ss-reply-header\">On x, y wrote:</div><blockquote class=\"ss-reply-quote\"><b>raw</b></blockquote>", text: "On x, y wrote:\n> raw")
        let body = join([paragraph("Thanks!"), paragraph("")])
        let output = ComposerHTMLExporter().export(body, appending: quoted)
        XCTAssertEqual(output.html, "<div><p>Thanks!</p><p><br></p></div>\n" + quoted.html)
        XCTAssertEqual(output.text, "Thanks!\n\n\nOn x, y wrote:\n> raw")
    }

    func testBoldRunsAreCoalescedAndUnsafeLinksDropped() {
        let body = NSMutableAttributedString(string: "ab", attributes: [.font: bold])
        body.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 1, length: 1))
        body.append(NSAttributedString(string: "x", attributes: [.font: regular, .link: "javascript:alert(1)"]))
        let output = ComposerHTMLExporter().export(body)
        XCTAssertEqual(output.html, "<div><p><b>ab</b>x</p></div>")
        XCTAssertEqual(output.text, "abx")
    }

    func testLineSeparatorBecomesBreakAndTrailingNewlineIsNotAParagraph() {
        let body = join([paragraph("line one\u{2028}line two"), paragraph("")])
        let withTrailingNewline = NSMutableAttributedString(attributedString: body)
        let output = ComposerHTMLExporter().export(withTrailingNewline)
        XCTAssertEqual(output.html, "<div><p>line one<br>line two</p><p><br></p></div>")
        XCTAssertEqual(output.text, "line one\nline two\n")
    }

    // MARK: Direction

    /// The composer lays out an Arabic or Hebrew paragraph right to left; without a `dir` the recipient's
    /// client renders it left to right, left-aligned and with trailing punctuation on the wrong side.
    func testRightToLeftParagraphsCarryTheirDirection() {
        let body = join([
            paragraph("مرحبا، كيف حالك؟"),
            paragraph("Hello there"),
            paragraph("שלום", block: .bulletItem),
            paragraph("123 עברית"),
        ])
        let html = ComposerHTMLExporter().export(body).html
        XCTAssertEqual(html, "<div><p dir=\"rtl\">مرحبا، كيف حالك؟</p><p>Hello there</p><ul dir=\"rtl\"><li dir=\"rtl\">שלום</li></ul><p dir=\"rtl\">123 עברית</p></div>")
    }

    func testExplicitWritingDirectionWins() {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = .rightToLeft
        let html = ComposerHTMLExporter().export(paragraph("OK?", extra: [.paragraphStyle: style])).html
        XCTAssertEqual(html, "<div><p dir=\"rtl\">OK?</p></div>")
    }

    func testQuickReplyParagraphsCarryTheirDirection() {
        XCTAssertEqual(QuickReplyComposer.paragraphsHTML(from: "שלום\n\nHi"), "<p dir=\"rtl\">שלום</p><p>Hi</p>")
    }
}
