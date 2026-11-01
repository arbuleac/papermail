import XCTest
@testable import SSCore

final class ReplyQuoterTests: XCTestCase {
    private let bob = EmailAddress(name: "Bob Example", address: "bob@example.com")
    private let alice = EmailAddress(name: nil, address: "alice@example.com")

    /// A stored body the way the sanitizer leaves it: base stylesheet, blocked image, ss-cid image, folded quote.
    private var stored: StoredBody {
        let rendered = "<div class=\"ss-body\"><style class=\"ss-base\">.ss-body{max-width:100%}</style>"
            + "<p>Original <img src=\"\(HTMLSanitizer.placeholderImage)\" data-ss-src=\"https://cdn.example/a.png\"> "
            + "<img src=\"\(RenderTestSupport.inlineImageURL("logo one"))\"></p>"
            + "<div class=\"ss-quote\" data-ss-collapsed=\"true\"><blockquote>older</blockquote></div></div>"
        return StoredBody(body: MessageBody(html: "<p>Original</p>", text: nil), renderedHTML: rendered, plainText: "Original\n\nolder")
    }

    func testQuotedReplyHasHeaderAndQuote() {
        let html = ReplyQuoter.quotedReplyHTML(original: stored, from: bob, date: RenderTestSupport.date, locale: RenderTestSupport.locale)
        assertContains(html, "<div class=\"ss-reply-attribution\">On ")
        assertContains(html, "2025")
        assertContains(html, "Bob Example &lt;bob@example.com&gt; wrote:</div>")
        assertContains(html, "<blockquote class=\"ss-reply-quote\" type=\"cite\"")
        assertContains(html, "<p>Original ")
        assertContains(html, "src=\"https://cdn.example/a.png\"")
        assertContains(html, "src=\"cid:logo one\"")
        assertContains(html, "<blockquote>older</blockquote>")
        assertNotContains(html, "ss-base")
        assertNotContains(html, "data-ss-src")
        assertNotContains(html, "data-ss-collapsed")
        assertNotContains(html, "ss-cid://")
        XCTAssertTrue(html.hasSuffix("</blockquote>"))
    }

    func testQuotedReplyWithoutSender() {
        let html = ReplyQuoter.quotedReplyHTML(original: stored, from: nil, date: RenderTestSupport.date, locale: RenderTestSupport.locale)
        assertContains(html, "unknown sender wrote:")
    }

    func testForwardHasOutlookStyleHeader() {
        let html = ReplyQuoter.forwardHTML(original: stored, subject: "Meeting <notes>", from: bob, to: [alice, bob], date: RenderTestSupport.date)
        assertContains(html, "<div class=\"ss-forward-header\"><hr")
        assertContains(html, "<b>From:</b> Bob Example &lt;bob@example.com&gt;<br><b>Sent:</b> ")
        assertContains(html, "<b>To:</b> alice@example.com; Bob Example &lt;bob@example.com&gt;<br><b>Subject:</b> Meeting &lt;notes&gt;")
        assertContains(html, "<div class=\"ss-forward-body\">")
        assertContains(html, "src=\"https://cdn.example/a.png\"")
        assertContains(html, "src=\"cid:logo one\"")
        assertNotContains(html, "ss-base")
    }

    func testPlainTextAlternatives() {
        XCTAssertEqual(ReplyQuoter.plainText(forHTML: "<p>Hi <b>there</b></p><ul><li>a</li></ul>"), "Hi there\n\n- a")
        let text = ReplyQuoter.quotedReplyText(original: stored, from: bob, date: RenderTestSupport.date, locale: RenderTestSupport.locale)
        XCTAssertTrue(text.hasPrefix("On "))
        assertContains(text, "Bob Example <bob@example.com> wrote:\n> Original\n>\n> older")
        let forward = ReplyQuoter.forwardText(original: stored, subject: "Meeting", from: bob, to: [alice], date: RenderTestSupport.date, locale: RenderTestSupport.locale)
        assertContains(forward, "From: Bob Example <bob@example.com>\nSent: ")
        assertContains(forward, "\nTo: alice@example.com\nSubject: Meeting\n\nOriginal\n\nolder")
    }
}
