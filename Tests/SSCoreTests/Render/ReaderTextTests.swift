import XCTest
@testable import SSCore

/// Reader mode's text (spec §5.59): which version it shows (the sender's text part, else the text taken from the HTML,
/// else the snippet), when a text part is only a placeholder, and the text set on the reading page with its quoted history
/// folded. The fixtures are the shapes real mailers send.
final class ReaderTextTests: XCTestCase {
    // MARK: Fixtures

    /// A newsletter's words as the sanitizer extracts them: long, with link targets and image names.
    private static let newsletterWords = (1...12).map { index in
        "Story \(index): the long read about local-first software, sync engines and the people who build them (https://news.test/\(index)). [image: Figure \(index)]"
    }.joined(separator: "\n\n")

    private func html(_ html: String, text: String?, plain: String, typesetting: BodyTypesetting = .styled) -> StoredBody {
        StoredBody(body: MessageBody(html: html, text: text), renderedHTML: html, plainText: plain, typesetting: typesetting)
    }

    // MARK: Choosing

    func testTheSendersTextPartComesFirst() {
        let part = "Hi Alex,\n\nThe flat is booked for March.\n\nPriya"
        let body = html("<div>Hi Alex,</div><div>The flat is booked for March.</div><div>Priya</div>", text: part,
                        plain: "Hi Alex,\nThe flat is booked for March.\nPriya")
        XCTAssertEqual(ReaderText.choose(body, snippet: "Hi Alex"), ReaderText.Choice(source: .text, text: part))
    }

    /// A mailer that writes its alternative from the HTML: about as long as the extracted words, so it is the message.
    func testAGeneratedAlternativeAsLongAsTheDesignIsTheMessage() {
        let part = Self.newsletterWords.replacingOccurrences(of: " (https://news.test/", with: " https://news.test/")
        let body = html("<table>…</table>", text: part, plain: Self.newsletterWords)
        XCTAssertEqual(ReaderText.choose(body, snippet: "").source, .text)
    }

    func testAPlainTextMessageIsItsText() {
        let body = StoredBody(body: MessageBody(html: nil, text: "Short note.\n— Theo"), renderedHTML: "<div class=\"ss-body ss-plain\"><p>Short note.</p></div>",
                              plainText: "Short note.\n— Theo", typesetting: .plain)
        XCTAssertEqual(ReaderText.choose(body, snippet: "Short"), ReaderText.Choice(source: .text, text: "Short note.\n— Theo"))
    }

    /// Mailchimp's “View this email in your browser”, a common placeholder alternative: the extracted words show instead.
    func testAPlaceholderLineGivesWayToTheExtractedText() {
        for part in ["View this email in your browser\nhttps://us1.campaign-archive.test/?u=1&id=2",
                     "Your email client does not support HTML. Please use an HTML-compatible email viewer.",
                     "This is a multi-part message in MIME format.",
                     "If you’re having trouble viewing this email, view it online: https://news.test/web",
                     "To view this message, please use an HTML compatible email viewer!",
                     "Having trouble viewing this e-mail? Open it in your browser."] {
            let body = html("<table>…</table>", text: part, plain: "Spring sale. Everything 20% off this week.")
            XCTAssertEqual(ReaderText.choose(body, snippet: ""), ReaderText.Choice(source: .extracted, text: "Spring sale. Everything 20% off this week."),
                           part)
        }
    }

    /// A text part under a quarter of the design's words, once those run past 400 bytes, is a stand-in however it is worded.
    func testATextPartFarShorterThanTheDesignIsAPlaceholder() {
        let body = html("<table>…</table>", text: "Our November issue is out. Read it at https://news.test/11", plain: Self.newsletterWords)
        XCTAssertGreaterThan(Self.newsletterWords.utf8.count, ReaderText.shortFloor)
        XCTAssertEqual(ReaderText.choose(body, snippet: "").source, .extracted)
    }

    /// Below the floor the two versions of a short note may differ by a greeting or a signature: the text part stays.
    func testAShortNoteKeepsItsTextPartBelowTheFloor() {
        let body = html("<div>See you at 7.</div><div>Sent from my phone, with a long footer the HTML adds</div>", text: "See you at 7.",
                        plain: "See you at 7.\nSent from my phone, with a long footer the HTML adds")
        XCTAssertEqual(ReaderText.choose(body, snippet: "").source, .text)
    }

    /// The phrases count only in a short part: a real letter that mentions a browser is still the letter.
    func testAPhraseInALongTextPartDoesNotMakeItAPlaceholder() {
        let letter = String(repeating: "We rebuilt the reader this quarter and measured every step. ", count: 12)
            + "If you cannot see this email properly, tell us; we read every reply."
        XCTAssertGreaterThan(letter.utf8.count, ReaderText.phraseCeiling)
        XCTAssertFalse(ReaderText.isPlaceholder(letter, extracted: letter))
        XCTAssertTrue(ReaderText.isPlaceholder("If you cannot see this email, open it on the web.", extracted: "Hello"))
    }

    func testABlankTextPartIsAPlaceholder() {
        XCTAssertTrue(ReaderText.isPlaceholder(" \n\t\n", extracted: "anything"))
        XCTAssertTrue(ReaderText.isPlaceholder("", extracted: ""))
        let body = html("<p>Words</p>", text: "\n\n", plain: "Words")
        XCTAssertEqual(ReaderText.choose(body, snippet: "").source, .extracted)
        XCTAssertEqual(ReaderText.choose(html("<p>Words</p>", text: nil, plain: "Words"), snippet: "").source, .extracted,
                       "HTML alone: the extracted text")
    }

    /// An evicted body has no source left: its kept plain text shows, the text part's own for a text/plain message.
    func testAnEvictedBodyShowsItsKeptText() {
        let plain = StoredBody(body: MessageBody(html: nil, text: nil), renderedHTML: "", plainText: "Kept words", typesetting: .plain)
        XCTAssertEqual(ReaderText.choose(plain, snippet: "s"), ReaderText.Choice(source: .text, text: "Kept words"))
        let styled = StoredBody(body: MessageBody(html: nil, text: nil), renderedHTML: "", plainText: "Kept design words", typesetting: .styled)
        XCTAssertEqual(ReaderText.choose(styled, snippet: "s"), ReaderText.Choice(source: .extracted, text: "Kept design words"))
        let unknown = StoredBody(body: MessageBody(html: nil, text: nil), renderedHTML: "", plainText: "Old body")
        XCTAssertEqual(ReaderText.choose(unknown, snippet: "s").source, .extracted, "no facts: not known to be plain")
    }

    func testWithoutWordsTheSnippetStandsIn() {
        XCTAssertEqual(ReaderText.choose(nil, snippet: "Snippet"), ReaderText.Choice(source: .snippet, text: "Snippet"))
        let pictures = html("<img src=\"cid:a\">", text: nil, plain: "")
        XCTAssertEqual(ReaderText.choose(pictures, snippet: "From the provider"), ReaderText.Choice(source: .snippet, text: "From the provider"))
    }

    // MARK: Setting

    /// Outlook's text has no “>”: the history under its From:/Sent: header folds, the reply's own words show.
    func testOutlooksHistoryFoldsUnderItsHeader() {
        let text = "Per account, as we said.\n\nTheo\n\nFrom: Alex Morgan <alex@demo.test>\nSent: Wednesday, 18 November 2026 09:52\nTo: Theo\nSubject: Re: Sync\n\nKeep them per device?"
        let set = ReaderText.render(text)
        XCTAssertTrue(set.hasQuotedContent)
        XCTAssertTrue(set.html.hasPrefix("<p>Per account, as we said.</p><p>Theo</p><div class=\"ss-quote\" data-ss-collapsed=\"true\"><blockquote>"),
                      set.html)
        XCTAssertTrue(set.html.contains("From: Alex Morgan &lt;<a href=\"mailto:alex@demo.test\">alex@demo.test</a>&gt;<br>Sent: Wednesday"))
        XCTAssertTrue(set.html.hasSuffix("<p>Keep them per device?</p></blockquote></div>"))
        XCTAssertEqual(set.html.components(separatedBy: "ss-quote").count, 2, "one fold for the whole history")
    }

    /// An attribution line sits above the fold's quote, as `PlainTextRenderer` sets one, inside the fold.
    func testAnAttributionLineOpensTheFold() {
        let text = "Thursday works.\n\nOn Tue, 17 Nov 2026 at 15:12, Priya Raman <priya@demo.test> wrote:\nCould we meet on Thursday?\n\nAnd bring the plan."
        let set = ReaderText.render(text)
        XCTAssertEqual(set.html, "<p>Thursday works.</p><div class=\"ss-quote\" data-ss-collapsed=\"true\"><p>On Tue, 17 Nov 2026 at 15:12, Priya Raman "
                       + "&lt;<a href=\"mailto:priya@demo.test\">priya@demo.test</a>&gt; wrote:</p><blockquote><p>Could we meet on Thursday?</p>"
                       + "<p>And bring the plan.</p></blockquote></div>")
    }

    func testTheOriginalMessageSeparatorOpensTheFold() {
        let set = ReaderText.render("Done.\n-----Original Message-----\nFrom: Ben\nPlease sign.")
        XCTAssertEqual(set.html, "<p>Done.</p><div class=\"ss-quote\" data-ss-collapsed=\"true\"><blockquote><p>-----Original Message-----<br>"
                       + "From: Ben<br>Please sign.</p></blockquote></div>")
    }

    /// “>” quotes are a text/plain body's own: they fold exactly as `PlainTextRenderer` folds them anywhere.
    func testQuoteMarkedTextFoldsAsAnyPlainBody() {
        let text = "Yes.\n\nOn Mon, 16 Nov 2026 at 10:00, Sam <sam@demo.test> wrote:\n> Climbing Thursday?\n> At 7."
        XCTAssertEqual(ReaderText.render(text).html, PlainTextRenderer.render(text).html)
        XCTAssertTrue(ReaderText.render(text).hasQuotedContent)
    }

    /// A signature is the sender's own card: it stays in sight, and so does a message whose every line is history.
    func testSignaturesAndAllHistoryMessagesShowWhole() {
        let signed = "See you then.\n--\nTheo Nakamura\nNakamura Labs"
        XCTAssertEqual(ReaderText.render(signed).html, PlainTextRenderer.render(signed).html)
        XCTAssertFalse(ReaderText.render(signed).hasQuotedContent)
        let forwardedWhole = "-----Original Message-----\nFrom: Ben\nThe whole thing."
        XCTAssertEqual(ReaderText.render(forwardedWhole).html, PlainTextRenderer.render(forwardedWhole).html)
        XCTAssertFalse(ReaderText.render(forwardedWhole).hasQuotedContent)
    }

    func testEveryCharacterIsEscaped() {
        let set = ReaderText.render("<script>alert(1)</script>\n\nFrom: x\nSent: y\n<img src=x onerror=alert(2)>")
        XCTAssertFalse(set.html.contains("<script"))
        XCTAssertFalse(set.html.contains("<img"))
        XCTAssertTrue(set.html.contains("&lt;img src=x onerror=alert(2)&gt;"))
    }

    func testTheHistoryStartLeavesSignaturesAndQuoteMarksToOthers() {
        func start(_ text: String) -> Int? { QuotedHistory.historyStart(in: text.split(separator: "\n", omittingEmptySubsequences: false)) }
        XCTAssertNil(start("Hi\n--\nTheo"))
        XCTAssertNil(start("Hi\n> On Mon, 16 Nov 2026 at 10:00, Sam wrote:"))
        XCTAssertEqual(start("Hi\n\nFrom: Ada\nSent: Monday\nSubject: x"), 2)
        XCTAssertEqual(start("Hi\n________________________________\nFrom: Ada"), 1)
        XCTAssertEqual(QuotedHistory.ownWords(of: "Hi\n--\nTheo", limit: 100), "Hi", "own words still stop at the signature")
    }

    // MARK: Cache

    /// The reader keeps what it set, by the text itself, within a byte limit, the oldest going first.
    func testTheCacheSetsATextOnceWithinItsLimit() {
        let cache = ReaderTextCache(byteLimit: 400)
        let first = "Per account.\n\nFrom: Ada\nSent: Monday\nOld words"
        XCTAssertTrue(cache.render(first) == ReaderText.render(first))
        XCTAssertTrue(cache.render(first) == ReaderText.render(first), "the same answer from the cache")
        XCTAssertEqual(cache.count, 1)
        _ = cache.render("Another short note.")
        XCTAssertEqual(cache.count, 2)
        let long = String(repeating: "word ", count: 30)
        _ = cache.render(long)
        XCTAssertLessThan(cache.count, 3, "past the limit the oldest go")
        _ = cache.render(String(repeating: "x", count: 500))
        XCTAssertLessThanOrEqual(cache.count, 2, "a text over the whole limit is set but not kept")
    }
}
