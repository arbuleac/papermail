import XCTest
@testable import SSCore

/// The payload in reader mode (spec §5.59), for each source of text: the sender's text part, the text taken from the HTML,
/// an evicted body's kept text, the snippet before a body arrives, and a message shown as sent. Pure: what the builder makes
/// of stored bodies, no WebKit.
final class ReaderModePayloadTests: XCTestCase {
    private typealias F = ConversationFixtures

    private let html = "<div class=\"ss-body\"><table><tr><td><img src=\"data:image/gif;base64,R0lGODlhAQABAAAAACw=\" data-ss-src=\"https://news.test/hero.jpg\">"
        + "<p style=\"color:#123456\">Design words</p></td></tr></table></div>"

    private func styled(text: String?, plain: String, blocked: Int = 1) -> StoredBody {
        StoredBody(body: MessageBody(html: "<p>source</p>", text: text,
                                     attachments: [AttachmentInfo(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 2_000, isInline: false),
                                                   AttachmentInfo(id: "logo", filename: "logo.png", mimeType: "image/png", sizeBytes: 10,
                                                                  contentID: "logo", isInline: true)]),
                   renderedHTML: html, plainText: plain, hasQuotedContent: false, blockedRemoteImageCount: blocked,
                   typesetting: .styled, declaresColors: true, coveredByNewYork: true)
    }

    private func build(_ messages: [MessageMetadata], bodies: [MessageID: StoredBody], reader: ReaderModeRender?,
                       pending: Set<MessageID> = []) -> RenderPayload {
        F.builder.build(messages: messages, bodies: bodies, accounts: F.accounts, pending: pending, readerMode: reader,
                        now: F.utc(2025, 1, 3, 18))
    }

    private func plainHTML(_ text: String) -> String {
        RenderPayloadBuilder.plainBodyPrefix + ReaderText.render(text).html + "</div>"
    }

    func testReaderModeOffLeavesTheHTML() {
        let message = F.message("m1")
        let payload = build([message], bodies: [message.id: styled(text: "Text words", plain: "Design words")], reader: nil)
        let card = payload.messages[0]
        XCTAssertEqual(card.html, html)
        XCTAssertNil(card.reader)
        XCTAssertEqual(card.typesetting, .styled)
        XCTAssertEqual(card.blockedRemoteImageCount, 1)
    }

    func testTheTextPartShowsOnTheReadingPage() {
        let message = F.message("m1")
        let payload = build([message], bodies: [message.id: styled(text: "Text words\n\nAlex", plain: "Design words")], reader: ReaderModeRender())
        let card = payload.messages[0]
        XCTAssertEqual(card.reader, .text)
        XCTAssertEqual(card.html, plainHTML("Text words\n\nAlex"))
        XCTAssertFalse(card.html.contains("data-ss-src"), "no HTML, so nothing remote, reaches the page")
        XCTAssertEqual(card.typesetting, .plain)
        XCTAssertFalse(card.declaresColors, "Quire's inks, never the sender's colours")
        XCTAssertEqual(card.blockedRemoteImageCount, 0, "no banner offers to load an image the text never names")
        XCTAssertFalse(card.hasQuotedContent)
        XCTAssertTrue(card.hasBody)
        XCTAssertEqual(card.bodyState, .ready)
        XCTAssertEqual(card.attachments.map(\.id), ["a1"], "attachments keep their chips; an inline picture is not one")
    }

    func testTheExtractedTextFoldsItsHistory() {
        let message = F.message("m1")
        let plain = "Per account.\n\nFrom: Me <me@example.com>\nSent: Tuesday\nSubject: Re: Engines\n\nPer device?"
        let payload = build([message], bodies: [message.id: styled(text: nil, plain: plain)], reader: ReaderModeRender())
        let card = payload.messages[0]
        XCTAssertEqual(card.reader, .extracted)
        XCTAssertEqual(card.html, plainHTML(plain))
        XCTAssertTrue(card.hasQuotedContent, "the history sits behind the elision mark")
        XCTAssertTrue(card.coveredByNewYork, "the stored coverage describes exactly the extracted text")
    }

    /// A text/plain message has nothing to replace: its stored page shows as without reader mode, set at sync time, so no
    /// line of its own words folds and nothing is set again on open, however long it is.
    func testATextPlainMessageShowsItsStoredPage() {
        let message = F.message("m1")
        let text = "Your booking is confirmed.\n\nFrom: London Kings Cross\nTo: Edinburgh\nDate: 12 December 2026\nSubject: Ticket\n\nSeat 42A"
        let sanitized = HTMLSanitizer().sanitize(MessageBody(html: nil, text: text), messageID: message.id)
        let body = StoredBody(body: MessageBody(html: nil, text: text), renderedHTML: sanitized.html, plainText: sanitized.plainText,
                              hasQuotedContent: sanitized.hasQuotedContent, blockedRemoteImageCount: 0, typesetting: .plain,
                              declaresColors: false, coveredByNewYork: sanitized.coveredByNewYork)
        let cache = ReaderTextCache()
        let card = build([message], bodies: [message.id: body], reader: ReaderModeRender(cache: cache)).messages[0]
        let off = build([message], bodies: [message.id: body], reader: nil).messages[0]
        XCTAssertEqual(card.reader, .text, "its line says it is the text version")
        XCTAssertEqual(card.html, off.html, "the very page it shows without reader mode")
        XCTAssertEqual(card.html, sanitized.html)
        XCTAssertFalse(card.hasQuotedContent, "nothing folds that reader mode off would show")
        XCTAssertEqual(card.typesetting, .plain)
        XCTAssertEqual(cache.count, 0, "no pass over its words")

        // Evicted, its kept text is set as the sanitizer set it: nothing folds there either.
        var kept = body
        kept.body.text = nil
        kept.renderedHTML = ""
        let evicted = build([message], bodies: [:], reader: ReaderModeRender(kept: [message.id: kept])).messages[0]
        XCTAssertEqual(evicted.reader, .text)
        XCTAssertEqual(evicted.html, RenderPayloadBuilder.plainBodyPrefix + PlainTextRenderer.render(sanitized.plainText).html + "</div>")
        XCTAssertFalse(evicted.hasQuotedContent)
    }

    /// A design of pictures has no words in either version: the snippet shows, and its line says so.
    func testADesignWithoutWordsShowsItsSnippetAsPreviewText() {
        let message = F.message("m1", snippet: "Black Friday, inside")
        let card = build([message], bodies: [message.id: styled(text: nil, plain: "")], reader: ReaderModeRender()).messages[0]
        XCTAssertEqual(card.reader, .snippet)
        XCTAssertEqual(card.html, plainHTML("Black Friday, inside"))
        XCTAssertEqual(card.blockedRemoteImageCount, 0)
        XCTAssertTrue(ConversationShellAssets.js.contains("snippet: ['Preview text', 'Show original', 'Show Original']"))
    }

    /// Keep mail on this Mac evicted the body: its kept text and attachment list show at once, as a body.
    func testAnEvictedBodyShowsItsKeptText() {
        let message = F.message("m1", hasAttachments: true)
        var kept = styled(text: nil, plain: "Kept design words")
        kept.body.html = nil
        kept.renderedHTML = ""
        let payload = build([message], bodies: [:], reader: ReaderModeRender(kept: [message.id: kept]))
        let card = payload.messages[0]
        XCTAssertTrue(card.hasBody)
        XCTAssertEqual(card.bodyState, .ready)
        XCTAssertEqual(card.reader, .extracted)
        XCTAssertEqual(card.html, plainHTML("Kept design words"))
        XCTAssertEqual(card.attachments.map(\.id), ["a1"])
        let off = build([message], bodies: [:], reader: nil).messages[0]
        XCTAssertFalse(off.hasBody, "without reader mode an evicted body waits for its download as ever")
    }

    /// No body yet: the snippet stands in, waiting for the body, as without reader mode.
    func testWithoutABodyTheSnippetStandsIn() {
        let message = F.message("m1", snippet: "A snippet")
        let card = build([message], bodies: [:], reader: ReaderModeRender()).messages[0]
        XCTAssertFalse(card.hasBody)
        XCTAssertNil(card.reader)
        XCTAssertEqual(card.html, RenderPayloadBuilder.html(for: message, body: nil))
    }

    func testAMessageShownAsSentKeepsItsHTML() {
        let message = F.message("m1")
        let body = styled(text: "Text words", plain: "Design words")
        let card = build([message], bodies: [message.id: body], reader: ReaderModeRender(originals: [message.id])).messages[0]
        XCTAssertEqual(card.reader, .original)
        XCTAssertEqual(card.html, html)
        XCTAssertEqual(card.typesetting, .styled)
        XCTAssertEqual(card.blockedRemoteImageCount, 1, "its images wait for Load images as ever")
        var evicted = body
        evicted.body.html = nil
        evicted.body.text = nil
        evicted.renderedHTML = ""
        let waiting = build([message], bodies: [:], reader: ReaderModeRender(originals: [message.id], kept: [message.id: evicted])).messages[0]
        XCTAssertFalse(waiting.hasBody, "an evicted original waits for the HTML its download brings back")
        XCTAssertNil(waiting.reader)
    }

    /// Drafts and replies on their way are the user's own words in the app's own setting: reader mode leaves them alone.
    func testDraftsAndPendingRepliesAreLeftAlone() {
        let draft = F.message("d1", roles: [.drafts])
        let reply = F.message("p1")
        let bodies = [draft.id: styled(text: "Draft text", plain: "Draft"), reply.id: styled(text: "Reply text", plain: "Reply")]
        let payload = build([draft, reply], bodies: bodies, reader: ReaderModeRender(), pending: [reply.id])
        XCTAssertEqual(payload.messages.map(\.reader), [nil, nil])
        XCTAssertEqual(payload.messages.map(\.html), [html, html])
    }

    func testTheViewTravelsByNameAndOnlyWhenSet() throws {
        let message = F.message("m1")
        let on = build([message], bodies: [message.id: styled(text: "Text", plain: "Design")], reader: ReaderModeRender())
        let off = build([message], bodies: [message.id: styled(text: "Text", plain: "Design")], reader: nil)
        func card(_ payload: RenderPayload) throws -> [String: Any] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try payload.jsonString().utf8)) as? [String: Any])
            return try XCTUnwrap((object["messages"] as? [[String: Any]])?.first)
        }
        XCTAssertEqual(try card(on)["reader"] as? String, "text")
        XCTAssertNil(try card(off)["reader"], "absent while reader mode is off")
        XCTAssertEqual([RenderPayload.ReaderView.text, .extracted, .snippet, .original].map(\.rawValue), ["text", "extracted", "snippet", "original"])
        for view in ["text", "extracted", "snippet", "original"] {
            XCTAssertTrue(ConversationShellAssets.js.contains(view + ": ["), "the shell has a line for `\(view)`")
        }
        XCTAssertTrue(ConversationShellAssets.js.contains("m.reader"))
    }

    // MARK: Inputs

    /// A slot rendered under the other reader mode, or before a message was switched, is stale; reader mode never passes
    /// for a flag patch.
    func testReaderModeIsPartOfTheInputs() {
        let message = F.message("m1", isRead: false)
        let off = RenderInputs(messages: [message]) { _ in true }
        let on = RenderInputs(messages: [message], readerMode: []) { _ in true }
        let original = RenderInputs(messages: [message], readerMode: [message.id]) { _ in true }
        XCTAssertNotEqual(off, on)
        XCTAssertNotEqual(on, original)
        var read = message
        read.isRead = true
        XCTAssertNil(off.flagPatches(to: RenderInputs(messages: [read], readerMode: []) { _ in true }), "a switch needs a payload")
        XCTAssertNotNil(on.flagPatches(to: RenderInputs(messages: [read], readerMode: []) { _ in true }))
        XCTAssertEqual(on.refreshed(with: [message]) { _ in false }.readerMode, [], "a refresh keeps the mode it rendered under")
    }

    /// An evicted body shown from its kept text counts as no body, so its download refreshes the slot.
    func testAKeptTextCountsAsNoBodyForTheRefresh() {
        let message = F.message("m1")
        let rendered = RenderInputs(messages: [message], readerMode: []) { _ in false }
        XCTAssertFalse(rendered.hasBody(message.id))
        XCTAssertNotEqual(rendered.refreshed(with: [message]) { _ in true }, rendered, "the downloaded body renders again")
    }
}
