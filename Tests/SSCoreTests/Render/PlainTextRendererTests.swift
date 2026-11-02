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

    func testPreservesLineBreaksAndIndentationInsideAParagraph() {
        let rendered = PlainTextRenderer.render("one\r\ntwo\n  three\n\tfour")
        XCTAssertEqual(rendered.html, "<p>one<br>two<br>&nbsp;&nbsp;three<br>&nbsp;&nbsp;&nbsp;&nbsp;four</p>")
        XCTAssertFalse(rendered.hasQuotedContent)
    }

    // MARK: Paragraphs (spec §5.14: the reading page's 12 pt paragraph gap, not an empty line)

    func testBlankLinesSeparateParagraphs() {
        let rendered = PlainTextRenderer.render("Hi Sam,\n\nThe flat is booked.\nKeys at the desk.\n\nAlex")
        XCTAssertEqual(rendered.html, "<p>Hi Sam,</p><p>The flat is booked.<br>Keys at the desk.</p><p>Alex</p>")
        XCTAssertFalse(rendered.html.contains("<br><br>"))
    }

    func testRunsOfBlankLinesAndEdgeBlankLinesLeaveNoEmptyParagraph() {
        XCTAssertEqual(PlainTextRenderer.render("\n\none\n\n\n \t\ntwo\r\n\r\n").html, "<p>one</p><p>two</p>")
        XCTAssertEqual(PlainTextRenderer.render("\n  \n\t\n").html, "", "whitespace only renders nothing")
    }

    func testNoNewlineIsWrittenBetweenElements() {
        // The plain body is `white-space: pre-wrap`: a newline in the markup would show as an extra line.
        let rendered = PlainTextRenderer.render("a\n\nb\n> q\n>\n> r\n\nc")
        XCTAssertFalse(rendered.html.contains("\n"))
        XCTAssertFalse(rendered.html.contains("\r"))
    }

    func testParagraphTextIsEscapedAndLinkified() {
        let rendered = PlainTextRenderer.render("<p onclick=\"x()\">hi</p>\n\n</p><script>alert(1)</script> https://example.com")
        XCTAssertEqual(
            rendered.html,
            "<p>&lt;p onclick=&quot;x()&quot;&gt;hi&lt;/p&gt;</p><p>&lt;/p&gt;&lt;script&gt;alert(1)&lt;/script&gt; "
                + "<a href=\"https://example.com\">https://example.com</a></p>"
        )
    }

    func testSanitizedPlainBodyIsParagraphsInsideThePlainWrapper() {
        let body = RenderTestSupport.sanitizeText("First.\n\nSecond.")
        XCTAssertEqual(body.html, "<div class=\"ss-body ss-plain\"><p>First.</p><p>Second.</p></div>")
        XCTAssertEqual(body.plainText, "First.\n\nSecond.")
    }

    // MARK: Quotes

    func testQuoteBlockBecomesBlockquote() {
        let rendered = PlainTextRenderer.render("Reply\n\n> quoted one\n> quoted two\n\nAfter")
        XCTAssertTrue(rendered.hasQuotedContent)
        XCTAssertEqual(
            rendered.html,
            "<p>Reply</p><div class=\"ss-quote\" data-ss-collapsed=\"true\"><blockquote><p>quoted one<br>quoted two</p></blockquote></div><p>After</p>"
        )
    }

    func testAttributionLineJoinsTheQuote() {
        let rendered = PlainTextRenderer.render("Thanks!\n\nOn Mon, Oct 27, 2025 at 9:14 AM, Bob Example <bob@example.com> wrote:\n> Can we move it?\n>\n> Bob")
        XCTAssertTrue(rendered.hasQuotedContent)
        XCTAssertEqual(
            rendered.html,
            "<p>Thanks!</p><div class=\"ss-quote\" data-ss-collapsed=\"true\"><p>On Mon, Oct 27, 2025 at 9:14 AM, Bob Example &lt;<a href=\"mailto:bob@example.com\">bob@example.com</a>&gt; wrote:</p><blockquote><p>Can we move it?</p><p>Bob</p></blockquote></div>"
        )
    }

    func testNestedQuoteLevels() {
        let rendered = PlainTextRenderer.render("> outer\n>> inner\n> outer again")
        XCTAssertEqual(
            rendered.html,
            "<div class=\"ss-quote\" data-ss-collapsed=\"true\"><blockquote><p>outer</p><blockquote><p>inner</p></blockquote><p>outer again</p></blockquote></div>"
        )
    }

    func testEmptyTextRendersEmpty() {
        let rendered = PlainTextRenderer.render("")
        XCTAssertEqual(rendered.html, "")
        XCTAssertFalse(rendered.hasQuotedContent)
    }
}
