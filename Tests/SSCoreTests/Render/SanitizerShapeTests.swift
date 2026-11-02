import XCTest
@testable import SSCore

/// Real-world shapes: replies from the big clients, a table-layout newsletter, inline images and text bodies.
final class SanitizerShapeTests: XCTestCase {
    func testGmailReplyQuoteIsWrapped() {
        let out = RenderTestSupport.sanitize(MailShapeFixtures.gmailReply)
        XCTAssertTrue(out.hasQuotedContent)
        assertContains(out.html, "<div class=\"ss-quote\" data-ss-collapsed=\"true\"><div class=\"gmail_quote\">")
        assertOrdered(out.html, "Thanks, that works for me.", before: "ss-quote")
        assertOrdered(out.html, "ss-quote", before: "Can we move the meeting to Thursday?")
        assertContains(out.html, "<a href=\"mailto:bob@example.com\">bob@example.com</a>")
        assertContains(out.html, "border-left:1px solid rgb(204,204,204)")
        assertContains(out.plainText, "Thanks, that works for me.")
        assertContains(out.plainText, "Can we move the meeting to Thursday?")
        XCTAssertEqual(out.blockedRemoteImageCount, 0)
    }

    func testOutlookWebReplyQuoteIsWrapped() {
        let out = RenderTestSupport.sanitize(MailShapeFixtures.outlookWebReply)
        XCTAssertTrue(out.hasQuotedContent)
        assertOrdered(out.html, "Sounds good, see you then.", before: "ss-quote")
        assertOrdered(out.html, "ss-quote", before: "id=\"ss-divRplyFwdMsg\"")
        assertOrdered(out.html, "ss-quote", before: "Can we move the meeting to Thursday?")
        assertContains(out.html, "id=\"ss-appendonsend\"")
        assertContains(out.html, "<hr")
        assertContains(out.html, "<b>From:</b> Bob Example &lt;bob@example.com&gt;")
        // The head stylesheet travels with the body; the meta tag does not.
        assertContains(out.html, "<style type=\"text/css\" style=\"display:none\">p{margin-top:0;margin-bottom:0}</style>")
        assertNotContainsIgnoringCase(out.html, "<meta")
        XCTAssertEqual(out.html.components(separatedBy: "class=\"ss-quote\"").count - 1, 1)
    }

    func testOutlookDesktopReplyQuoteIsWrapped() {
        let out = RenderTestSupport.sanitize(MailShapeFixtures.outlookDesktopReply)
        XCTAssertTrue(out.hasQuotedContent)
        assertOrdered(out.html, "Yes, Thursday works.", before: "ss-quote")
        assertOrdered(out.html, "ss-quote", before: "<b>From:</b>")
        assertOrdered(out.html, "ss-quote", before: "Can we move the meeting to Thursday?")
    }

    func testAppleMailReplyQuoteIsWrapped() {
        let out = RenderTestSupport.sanitize(MailShapeFixtures.appleMailReply)
        XCTAssertTrue(out.hasQuotedContent)
        assertOrdered(out.html, "Works for me.", before: "ss-quote")
        assertContains(out.html, "<div class=\"ss-quote\" data-ss-collapsed=\"true\"><blockquote type=\"cite\"")
        assertOrdered(out.html, "ss-quote", before: "Can we move the meeting to Thursday?")
        // Apple Mail styles the body element itself; that style moves onto the wrapper.
        assertContains(out.html, "class=\"ss-body\" style=\"word-wrap: break-word;")
    }

    func testYahooReplyQuoteIsWrapped() {
        let out = RenderTestSupport.sanitize(MailShapeFixtures.yahooReply)
        XCTAssertTrue(out.hasQuotedContent)
        assertOrdered(out.html, "Fine by me.", before: "ss-quote")
        assertContains(out.html, "<div class=\"ss-quote\" data-ss-collapsed=\"true\"><div id=\"ss-yahoo_quoted_123\" class=\"yahoo_quoted\">")
    }

    func testGenericAttributionAndBlockquoteAreWrapped() {
        let out = RenderTestSupport.sanitize(MailShapeFixtures.genericReply)
        XCTAssertTrue(out.hasQuotedContent)
        assertContains(out.html, "<p>Agreed.</p><div class=\"ss-quote\" data-ss-collapsed=\"true\"><p>On Mon, Oct 27, 2025 at 9:14 AM, Bob Example wrote:</p><blockquote>")
    }

    func testPlainBlockquoteWithoutAttributionIsNotFolded() {
        let out = RenderTestSupport.sanitize("<p>Note:</p><blockquote>A pull quote</blockquote>")
        XCTAssertFalse(out.hasQuotedContent)
        assertNotContains(out.html, "ss-quote")
    }

    func testNewsletterKeepsStylesAndBlocksRemoteImages() {
        let out = RenderTestSupport.sanitize(MailShapeFixtures.newsletter)
        XCTAssertEqual(out.blockedRemoteImageCount, 4)
        assertNotContains(out.html, "cdn.example/hero.jpg")
        assertNotContains(out.html, " src=\"https://")
        assertContains(out.html, "data-ss-src=\"https://cdn.example/logo.png\"")
        assertContains(out.html, "data-ss-src=\"https://track.example/open.gif?id=42\"")
        assertContains(out.html, "src=\"\(HTMLSanitizer.placeholderImage)\"")
        // Styles that needed no filtering are byte-for-byte the sender's; the stylesheet lost a url() and was rewritten.
        assertContains(out.html, "background-color:#ffffff;border-radius:8px")
        assertContains(out.html, "font-size:24px")
        assertContains(out.html, "padding: 24px;background-image: none;")
        assertContains(out.html, "td{font-family: Helvetica,Arial,sans-serif;}")
        assertContains(out.html, "href=\"https://acme.example/read?utm=1&amp;id=7\"")
        assertContains(out.html, "<table width=\"600\"")
        assertNotContainsIgnoringCase(out.html, "<title")
        assertNotContainsIgnoringCase(out.html, "<!doctype")
        assertContains(out.html, "class=\"ss-body\" style=\"margin:0;padding:0;background-color:#f4f4f4\"")
        assertContains(out.plainText, "This week at Acme")
        assertContains(out.plainText, "Read more (https://acme.example/read?utm=1&id=7)")
        XCTAssertFalse(out.hasQuotedContent)
    }

    func testBlockedBackgroundAttributeIsParkedForLoadImages() {
        // A hero cell whose only image is a background= attribute: blocked, but kept so "Load images" can
        // put it back, like a parked <img src>.
        let out = RenderTestSupport.sanitize("<table><tr><td background=\"https://cdn.example/hero.jpg\">Hi</td></tr></table>")
        XCTAssertEqual(out.blockedRemoteImageCount, 1)
        assertContains(out.html, "data-ss-background=\"https://cdn.example/hero.jpg\"")
        assertNotContains(out.html, " background=")
    }

    func testNewsletterWithRemoteImagesAllowed() {
        let out = RenderTestSupport.sanitize(MailShapeFixtures.newsletter, allowRemoteImages: true)
        XCTAssertEqual(out.blockedRemoteImageCount, 0)
        assertContains(out.html, "src=\"https://cdn.example/logo.png\"")
        assertNotContains(out.html, "data-ss-src")
        assertContains(out.html, "background:url(https://cdn.example/hero.jpg) center/cover")
        assertContains(out.html, "background-image:url(https://cdn.example/hero.jpg)")
    }

    func testInlineImagesAreRewrittenToInlineImageScheme() {
        let out = RenderTestSupport.sanitize(MailShapeFixtures.inlineImage)
        let chart = RenderTestSupport.inlineImageURL("chart.png@01DB2F3A.5F2C1E80")
        let logo = RenderTestSupport.inlineImageURL("my logo.png")
        XCTAssertTrue(chart.hasPrefix("ss-cid://acct-1/msg-1/chart.png"), chart)
        XCTAssertEqual(logo, "ss-cid://acct-1/msg-1/my%20logo.png")
        assertContains(out.html, "<img src=\"\(chart)\" width=\"400\" />")
        assertContains(out.html, "<img src=\"\(logo)\" />")
        assertNotContains(out.html, "\"cid:")
        assertNotContains(out.html, "<chart")
        XCTAssertEqual(out.blockedRemoteImageCount, 0)
    }

    func testTextBodyIsRenderedWhenHTMLIsMissing() {
        let out = RenderTestSupport.sanitizeText("Hello <b>\nhttps://example.com\n\nOn Mon, Oct 27, 2025, Bob wrote:\n> quoted")
        assertContains(out.html, "<div class=\"ss-body ss-plain\">")
        assertContains(out.html, "<p>Hello &lt;b&gt;<br><a href=\"https://example.com\">https://example.com</a></p>")
        assertContains(out.html, "<div class=\"ss-quote\" data-ss-collapsed=\"true\"><p>On Mon, Oct 27, 2025, Bob wrote:</p><blockquote><p>quoted</p></blockquote></div>")
        XCTAssertTrue(out.hasQuotedContent)
        XCTAssertEqual(out.blockedRemoteImageCount, 0)
        assertContains(out.plainText, "Hello <b>")
    }

    func testWhitespaceOnlyHTMLFallsBackToText() {
        let out = HTMLSanitizer().sanitize(MessageBody(html: "  \n ", text: "plain"), messageID: RenderTestSupport.messageID)
        assertContains(out.html, "ss-plain")
        assertContains(out.html, "plain")
        XCTAssertEqual(out.plainText, "plain")
    }

    func testEmptyBodyProducesEmptyWrapper() {
        let out = HTMLSanitizer().sanitize(MessageBody(html: nil, text: nil), messageID: RenderTestSupport.messageID)
        XCTAssertEqual(out.html, "<div class=\"ss-body ss-plain\"></div>")
        XCTAssertEqual(out.plainText, "")
    }
}
