import XCTest
@testable import SSCore

final class QuotedReplyTests: XCTestCase {
    private let account = AccountID("acct")

    private var original: MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account, providerID: "m1"),
            conversationID: ConversationID(accountID: account, providerID: "c1"),
            subject: "Lunch <today>", snippet: "",
            from: EmailAddress(name: "Alice", address: "alice@example.com"),
            to: [EmailAddress(name: "Me", address: "me@example.com")],
            cc: [EmailAddress(address: "bob@example.com")],
            date: Date(timeIntervalSince1970: 1_700_000_000),
            roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
        )
    }

    private var body: StoredBody {
        StoredBody(
            body: MessageBody(html: "<p>Hi</p>", text: "Hi"),
            renderedHTML: "<div><p>Hi &amp; bye</p><img src=\"ss-cid://acct/m1/logo@1\"><img data-ss-src=\"https://img.example.com/a.png\" alt=\"a\"></div>",
            plainText: "Hi & bye\n\nSecond line"
        )
    }

    func testReplyRenderingHasHeaderAndBlockquote() {
        let rendering = QuotedReply.reply(original: original, body: body, locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(rendering.html.hasPrefix("<div class=\"ss-reply-header\">On "))
        XCTAssertTrue(rendering.html.contains("Alice &lt;alice@example.com&gt; wrote:</div><blockquote class=\"ss-reply-quote\">"))
        XCTAssertTrue(rendering.html.hasSuffix("</blockquote>"))
        XCTAssertTrue(rendering.html.contains("<p>Hi &amp; bye</p>"))
        XCTAssertTrue(rendering.text.hasPrefix("On "))
        XCTAssertTrue(rendering.text.hasSuffix(" wrote:\n> Hi & bye\n>\n> Second line"))
    }

    func testImageReferencesAreMadeSendable() {
        let rendering = QuotedReply.reply(original: original, body: body)
        XCTAssertTrue(rendering.html.contains("src=\"cid:logo@1\""))
        XCTAssertTrue(rendering.html.contains("src=\"https://img.example.com/a.png\""))
        XCTAssertFalse(rendering.html.contains("data-ss-src"))
        XCTAssertFalse(rendering.html.contains("ss-cid://"))
    }

    func testForwardRenderingHasHeaderBlock() {
        let rendering = QuotedReply.forward(original: original, body: body, locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(rendering.html.hasPrefix("<div class=\"ss-forward-header\">---------- Forwarded message ----------<br><b>From:</b> Alice &lt;alice@example.com&gt;<br><b>Date:</b> "))
        XCTAssertTrue(rendering.html.contains("<b>Subject:</b> Lunch &lt;today&gt;<br><b>To:</b> Me &lt;me@example.com&gt;<br><b>Cc:</b> bob@example.com</div><br><div class=\"ss-forward-body\">"))
        XCTAssertTrue(rendering.text.hasPrefix("---------- Forwarded message ----------\nFrom: Alice <alice@example.com>\nDate: "))
        XCTAssertTrue(rendering.text.hasSuffix("Subject: Lunch <today>\nTo: Me <me@example.com>\nCc: bob@example.com\n\nHi & bye\n\nSecond line"))
    }

    func testSendableHTMLLeavesCleanHTMLUntouched() {
        let clean = "<p>nothing to do</p>"
        XCTAssertEqual(QuotedReply.sendableHTML(clean), clean)
    }
}
