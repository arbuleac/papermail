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

    // MARK: Style blocks

    func testStyleBlocksAreDroppedFromTheQuote() {
        // The viewer fences these in a sandboxed iframe; the outgoing message has no such fence, so they
        // would paint the user's own paragraphs white and hide the attribution.
        let hostile = StoredBody(
            body: MessageBody(html: nil, text: nil),
            renderedHTML: "<style>p{color:#fff} .ss-reply-header{display:none}</style><p>Buy</p><div><STYLE type=\"text/css\">b{display:none}</STYLE><b>now</b></div>",
            plainText: "Buy now"
        )
        let reply = QuotedReply.reply(original: original, body: hostile)
        XCTAssertFalse(reply.html.localizedCaseInsensitiveContains("<style"))
        XCTAssertTrue(reply.html.hasSuffix("<blockquote class=\"ss-reply-quote\"><p>Buy</p><div><b>now</b></div></blockquote>"))

        let forward = QuotedReply.forward(original: original, body: hostile)
        XCTAssertFalse(forward.html.localizedCaseInsensitiveContains("<style"))
        XCTAssertTrue(forward.html.hasSuffix("<div class=\"ss-forward-body\"><p>Buy</p><div><b>now</b></div></div>"))

        let typed = NSAttributedString(string: "Thanks")
        let export = ComposerHTMLExporter().export(typed, appending: reply)
        XCTAssertFalse(export.html.localizedCaseInsensitiveContains("<style"))
        XCTAssertTrue(export.html.hasPrefix("<div><p>Thanks</p></div>\n<div class=\"ss-reply-header\">"))
    }

    func testInlineStylesStay() {
        let styled = "<p style=\"color:red\">Hi</p><style>p{}</style>"
        XCTAssertEqual(QuotedReply.sendableHTML(styled), "<p style=\"color:red\">Hi</p>")
    }

    // MARK: Content-IDs

    func testPercentEncodedContentIDsAreDecoded() {
        let id = MessageID(accountID: account, providerID: "m1")
        let spaced = RenderURLScheme.inlineImageURL(for: id, contentID: "image 001@x").absoluteString
        XCTAssertTrue(spaced.contains("%20"), "the scheme encodes the id, which is what the quote must undo")
        XCTAssertTrue(QuotedReply.sendableHTML("<img src=\"\(spaced)\">", of: id).contains("src=\"cid:image 001@x\""))
        XCTAssertTrue(QuotedReply.sendableHTML("<img src=\"\(spaced)\">").contains("src=\"cid:image 001@x\""))

        let braced = RenderURLScheme.inlineImageURL(for: id, contentID: "{5%}#?|@x").absoluteString
        XCTAssertTrue(QuotedReply.sendableHTML("<img src=\"\(braced)\">", of: id).contains("src=\"cid:{5%}#?|@x\""))

        // A slash is legal in a msg-id and the scheme leaves it alone; only the message's prefix tells
        // where the id starts.
        let slashed = RenderURLScheme.inlineImageURL(for: id, contentID: "part/1@x").absoluteString
        XCTAssertTrue(QuotedReply.sendableHTML("<img src=\"\(slashed)\">", of: id).contains("src=\"cid:part/1@x\""))
    }

    func testDecodedReferencesMatchTheirParts() {
        let id = MessageID(accountID: account, providerID: "m1")
        let part = AttachmentInfo(id: "a1", filename: "image 001.png", mimeType: "image/png", sizeBytes: 1, contentID: "image 001@x", isInline: true)
        let url = RenderURLScheme.inlineImageURL(for: id, contentID: part.contentID!).absoluteString
        let quoted = QuotedReply.sendableHTML("<img src=\"\(url)\">", of: id)
        XCTAssertEqual(QuotedReply.partsToCarry(from: [part], quotedHTML: quoted, isForward: false), [QuotedReply.CarriedPart(info: part, contentID: "image 001@x")])
    }

    // MARK: Parts to carry

    func testReferencedPartsTravelInlineWhateverTheirDisposition() {
        // Outlook marks images it references from the body as attachments; the reference decides.
        let referenced = AttachmentInfo(id: "a1", filename: "img1.png", mimeType: "image/png", sizeBytes: 1, contentID: "img1", isInline: false)
        let unreferencedInline = AttachmentInfo(id: "a2", filename: "logo.png", mimeType: "image/png", sizeBytes: 1, contentID: "logo", isInline: true)
        let plain = AttachmentInfo(id: "a3", filename: "doc.pdf", mimeType: "application/pdf", sizeBytes: 1, isInline: false)
        let parts = [referenced, unreferencedInline, plain]
        let html = "<blockquote><img src=\"cid:img1\"></blockquote>"

        XCTAssertEqual(
            QuotedReply.partsToCarry(from: parts, quotedHTML: html, isForward: false),
            [QuotedReply.CarriedPart(info: referenced, contentID: "img1")]
        )
        XCTAssertEqual(
            QuotedReply.partsToCarry(from: parts, quotedHTML: html, isForward: true),
            [
                QuotedReply.CarriedPart(info: referenced, contentID: "img1"),
                QuotedReply.CarriedPart(info: unreferencedInline),
                QuotedReply.CarriedPart(info: plain),
            ]
        )
    }

    func testReferenceMatchingIsExact() {
        XCTAssertTrue(QuotedReply.references(contentID: "img1", in: "<img src=\"cid:img1\">"))
        XCTAssertTrue(QuotedReply.references(contentID: "img1", in: "<td background='cid:img1'>"))
        XCTAssertTrue(QuotedReply.references(contentID: "img1", in: "style=\"background:url(cid:img1)\""))
        XCTAssertFalse(QuotedReply.references(contentID: "img1", in: "<img src=\"cid:img10\">"))
        XCTAssertTrue(QuotedReply.references(contentID: "a&b", in: "<img src=\"cid:a&amp;b\">"))
    }

    // MARK: Inline references outside <img src>

    /// Outlook newsletters and signatures paint with `background="cid:…"` and `url(cid:…)`; the sanitizer
    /// points those at `ss-cid://` like any image, and the quote must turn every one back into `cid:` or
    /// recipients get dead URLs that also expose the account and provider message ids.
    func testBackgroundAndStyleReferencesBecomeCIDAgainAndTheirPartsTravel() throws {
        let messageID = MessageID(accountID: AccountID("9F2C-ACCT"), providerID: "AAMkAD=")
        var metadata = original
        metadata.id = messageID
        let source = #"<table background="cid:bg@1"><tr><td style="background-image:url(cid:bg2@1)"><a href="cid:doc@1">doc</a></td></tr></table>"#
        let sanitized = HTMLSanitizer().sanitize(MessageBody(html: source, text: nil), messageID: messageID)
        XCTAssertTrue(sanitized.html.contains("ss-cid://"), "precondition: the sanitizer rewrote the references")
        let stored = StoredBody(body: MessageBody(html: source, text: nil), renderedHTML: sanitized.html, plainText: sanitized.plainText)

        let rendering = QuotedReply.reply(original: metadata, body: stored)

        XCTAssertFalse(rendering.html.contains("ss-cid"), rendering.html)
        XCTAssertFalse(rendering.html.contains("9F2C-ACCT"), "the account id must not leave the machine")
        XCTAssertTrue(rendering.html.contains(#"background="cid:bg@1""#), rendering.html)
        XCTAssertTrue(rendering.html.contains("cid:bg2@1"), rendering.html)
        XCTAssertTrue(rendering.html.contains(#"href="cid:doc@1""#), rendering.html)
        let parts = [
            AttachmentInfo(id: "A1", filename: "bg.png", mimeType: "image/png", sizeBytes: 10, contentID: "bg@1", isInline: true),
            AttachmentInfo(id: "A2", filename: "bg2.png", mimeType: "image/png", sizeBytes: 10, contentID: "bg2@1", isInline: true),
        ]
        let carried = QuotedReply.partsToCarry(from: parts, quotedHTML: rendering.html, isForward: false)
        XCTAssertEqual(carried.map(\.contentID), ["bg@1", "bg2@1"])
    }
}
