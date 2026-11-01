import XCTest
@testable import SSCore

final class PlainTextRendererTests: XCTestCase {
    func testLinkifiesURLsAndEmails() {
        let html = PlainTextRenderer.linkify("See https://example.com/path?a=1&b=2. Mail bob@example.com!")
        XCTAssertEqual(
            html,
            "See <a href=\"https://example.com/path?a=1&amp;b=2\">https://example.com/path?a=1&amp;b=2</a>. Mail <a href=\"mailto:bob@example.com\">bob@example.com</a>!"
        )
    }

    func testURLInParenthesesKeepsBalancedParentheses() {
        let html = PlainTextRenderer.linkify("(see https://en.wikipedia.org/wiki/Foo_(bar))")
        XCTAssertEqual(html, "(see <a href=\"https://en.wikipedia.org/wiki/Foo_(bar)\">https://en.wikipedia.org/wiki/Foo_(bar)</a>)")
    }

    func testDoesNotLinkInsideWordsOrBareDomains() {
        XCTAssertEqual(PlainTextRenderer.linkify("xhttp://a.example/ and not.an.email"), "xhttp://a.example/ and not.an.email")
    }

    func testEscapesMarkup() {
        XCTAssertEqual(PlainTextRenderer.linkify("<b>&\"'</b>"), "&lt;b&gt;&amp;&quot;&#39;&lt;/b&gt;")
    }

    func testPreservesLineBreaksAndIndentation() {
        let rendered = PlainTextRenderer.render("one\r\ntwo\n  three\n\tfour")
        XCTAssertEqual(rendered.html, "one<br>two<br>&nbsp;&nbsp;three<br>&nbsp;&nbsp;&nbsp;&nbsp;four")
        XCTAssertFalse(rendered.hasQuotedContent)
    }

    func testQuoteBlockBecomesBlockquote() {
        let rendered = PlainTextRenderer.render("Reply\n\n> quoted one\n> quoted two\n\nAfter")
        XCTAssertTrue(rendered.hasQuotedContent)
        XCTAssertEqual(
            rendered.html,
            "Reply<br><div class=\"ss-quote\" data-ss-collapsed=\"true\"><blockquote>quoted one<br>quoted two</blockquote></div><br>After"
        )
    }

    func testAttributionLineJoinsTheQuote() {
        let rendered = PlainTextRenderer.render("Thanks!\n\nOn Mon, Oct 27, 2025 at 9:14 AM, Bob Example <bob@example.com> wrote:\n> Can we move it?\n>\n> Bob")
        XCTAssertTrue(rendered.hasQuotedContent)
        XCTAssertEqual(
            rendered.html,
            "Thanks!<br><div class=\"ss-quote\" data-ss-collapsed=\"true\">On Mon, Oct 27, 2025 at 9:14 AM, Bob Example &lt;<a href=\"mailto:bob@example.com\">bob@example.com</a>&gt; wrote:<br><blockquote>Can we move it?<br><br>Bob</blockquote></div>"
        )
    }

    func testNestedQuoteLevels() {
        let rendered = PlainTextRenderer.render("> outer\n>> inner\n> outer again")
        XCTAssertEqual(
            rendered.html,
            "<div class=\"ss-quote\" data-ss-collapsed=\"true\"><blockquote>outer<blockquote>inner</blockquote>outer again</blockquote></div>"
        )
    }

    func testEmptyTextRendersEmpty() {
        let rendered = PlainTextRenderer.render("")
        XCTAssertEqual(rendered.html, "")
        XCTAssertFalse(rendered.hasQuotedContent)
    }
}
