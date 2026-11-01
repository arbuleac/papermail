import XCTest
@testable import SSCore

final class QuoteDetectorTests: XCTestCase {
    func testWrapQuotedContentAPI() {
        let result = QuoteDetector.wrapQuotedContent(inHTML: MailShapeFixtures.gmailReply)
        XCTAssertTrue(result.hasQuotedContent)
        assertContains(result.html, "<div class=\"ss-quote\" data-ss-collapsed=\"true\"><div class=\"gmail_quote\">")
    }

    func testNestedGmailQuotesProduceOneWrapper() {
        let html = #"<div>Reply</div><div class="gmail_quote">On A wrote:<blockquote class="gmail_quote">Level 1<div class="gmail_quote">On B wrote:<blockquote class="gmail_quote">Level 2</blockquote></div></blockquote></div>"#
        let result = QuoteDetector.wrapQuotedContent(inHTML: html)
        XCTAssertEqual(result.html.components(separatedBy: "ss-quote").count - 1, 1)
        assertOrdered(result.html, "Reply", before: "ss-quote")
    }

    func testHrFollowedByOutlookHeaderIsWrapped() {
        let html = #"<div>Reply text</div><hr><div><b>From:</b> Bob &lt;bob@example.com&gt;<br><b>Sent:</b> Monday<br><b>To:</b> Alice<br><b>Subject:</b> Hi</div><div>Older body</div>"#
        let result = QuoteDetector.wrapQuotedContent(inHTML: html)
        XCTAssertTrue(result.hasQuotedContent)
        assertContains(result.html, "<div>Reply text</div><div class=\"ss-quote\" data-ss-collapsed=\"true\"><hr /><div><b>From:</b>")
        assertOrdered(result.html, "ss-quote", before: "Older body")
    }

    func testHrWithoutHeaderIsLeftAlone() {
        let result = QuoteDetector.wrapQuotedContent(inHTML: "<p>a</p><hr><p>b</p>")
        XCTAssertFalse(result.hasQuotedContent)
        assertNotContains(result.html, "ss-quote")
    }

    func testTextAttributionBeforeBlockquote() {
        let html = "<div>Sure.</div>On 27 Oct 2025, at 09:14, Bob Example wrote:<br><br><blockquote>Earlier</blockquote>"
        let result = QuoteDetector.wrapQuotedContent(inHTML: html)
        XCTAssertTrue(result.hasQuotedContent)
        assertContains(result.html, "<div>Sure.</div><div class=\"ss-quote\" data-ss-collapsed=\"true\">On 27 Oct 2025, at 09:14, Bob Example wrote:<br /><br /><blockquote>Earlier</blockquote></div>")
    }

    func testLocalizedAttributionLines() {
        XCTAssertTrue(QuoteAttribution.isAttributionLine("On Mon, Oct 27, 2025 at 9:14 AM Bob Example <bob@example.com> wrote:"))
        XCTAssertTrue(QuoteAttribution.isAttributionLine("Le 27 oct. 2025 à 09:14, Bob Example <bob@example.com> a écrit :"))
        XCTAssertTrue(QuoteAttribution.isAttributionLine("Am 27.10.2025 um 09:14 schrieb Bob Example <bob@example.com>:"))
        XCTAssertTrue(QuoteAttribution.isAttributionLine("El 27 oct 2025, a las 9:14, Bob Example escribió:"))
        XCTAssertTrue(QuoteAttribution.isAttributionLine("Bob Example (Oct 27, 2025) wrote:"))
        XCTAssertFalse(QuoteAttribution.isAttributionLine("Here is what I wrote last year:"))
        XCTAssertFalse(QuoteAttribution.isAttributionLine("Agenda:"))
        XCTAssertFalse(QuoteAttribution.isAttributionLine("On the agenda for 2025:"))
    }

    func testBlockquoteWithoutAttributionIsLeftAlone() {
        let result = QuoteDetector.wrapQuotedContent(inHTML: "<p>Quote of the day:</p><blockquote>Be kind</blockquote>")
        XCTAssertFalse(result.hasQuotedContent)
        assertNotContains(result.html, "ss-quote")
    }
}
