import JavaScriptCore
import XCTest
@testable import PaperCore

/// The payload to the print document (spec §5.48): every message open in order, its header written out for paper, the
/// date in full, each body inert in a template with what the reader shows of it, the notes for what the reader folds or
/// holds back, and the invitation card without its buttons. What WebKit then makes of it is `PrintConversationTests`'.
final class PrintDocumentBuilderTests: XCTestCase {
    private typealias F = ConversationFixtures
    private let now = F.utc(2025, 3, 7, 15, 0)
    private let printer = PrintDocumentBuilder(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!,
                                               calendar: Calendar(identifier: .gregorian), imageWait: 3)

    private func payload(_ messages: [MessageMetadata], bodies: [MessageID: StoredBody], loadRemoteImages: Bool = false,
                         readingSans: Bool = false, pending: Set<MessageID> = [],
                         bodyStates: [MessageID: RenderPayload.BodyState] = [:]) -> RenderPayload {
        F.builder.build(messages: messages, bodies: bodies, accounts: F.accounts, bodyStates: bodyStates, loadRemoteImages: loadRemoteImages,
                        readingSans: readingSans, pending: pending, now: now)
    }

    private func key(_ message: MessageMetadata) -> String { RenderPayload.messageKey(for: message.id) }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The printed sheets alone, without the stylesheet and script, for what must not be printed.
    private func sheets(of html: String) -> String {
        html.components(separatedBy: "<main class=\"ss-pdoc\">").last?.components(separatedBy: "</main>").first ?? ""
    }

    // MARK: Sheets

    func testEveryMessagePrintsOpenInOrderWithItsHeaderWrittenOut() {
        let first = F.message("m1", from: F.ada, to: [F.me, F.bob], cc: [F.carol], date: F.utc(2025, 1, 3, 14, 5), isRead: true)
        let second = F.message("m2", from: F.bob, to: [F.ada], date: F.utc(2025, 3, 6, 9, 30), isRead: false, isStarred: true)
        let bodies = [first.id: F.body(html: "<p>First body</p>"), second.id: F.body(html: "<p>Second body</p>")]
        let html = printer.document(for: payload([second, first], bodies: bodies))

        XCTAssertEqual(occurrences(of: "<article class=\"ss-pmsg\"", in: html), 2, "one sheet per message, collapsed or not")
        let firstAt = try! XCTUnwrap(html.range(of: "First body"))
        let secondAt = try! XCTUnwrap(html.range(of: "Second body"))
        XCTAssertLessThan(firstAt.lowerBound, secondAt.lowerBound, "oldest first, as the reader stacks them")
        // The address beside the name, since paper has no hover; every recipient written out with their address.
        XCTAssertTrue(html.contains("<span class=\"ss-pname\">Ada Lovelace</span><span class=\"ss-paddr\">ada@example.com</span>"))
        XCTAssertTrue(html.contains("<span class=\"ss-plabel\">To</span>"))
        XCTAssertTrue(html.contains("<span class=\"ss-plabel\">Cc</span>"))
        XCTAssertTrue(html.contains("Carol <span class=\"ss-pad\">&lt;carol@example.com&gt;</span>"))
        // The date in full (en_GB, UTC), never the reader's “Yesterday 09:30”.
        XCTAssertTrue(html.contains(">Fri, 3 Jan 2025 at 14:05</time>"), sheets(of: html))
        XCTAssertTrue(html.contains(">Thu, 6 Mar 2025 at 09:30</time>"))
        XCTAssertFalse(html.contains("Yesterday"))
        // The reader's controls are not the message: no pip, star, Unsubscribe or footer buttons.
        let printed = sheets(of: html)
        XCTAssertFalse(printed.contains("pip"))
        XCTAssertFalse(printed.contains("star"))
        XCTAssertFalse(printed.contains("Unsubscribe"))
        XCTAssertFalse(html.contains("<button"))
    }

    func testTheMastheadNamesTheSubjectTheParticipantsAndTheCount() {
        let messages = [F.message("m1", from: F.ada), F.message("m2", from: F.bob, date: F.utc(2025, 1, 4))]
        let built = payload(messages, bodies: [:])
        let html = printer.document(for: built)
        XCTAssertTrue(html.contains("<h1 class=\"ss-psubject\">Engines</h1>"))
        XCTAssertTrue(html.contains("<p class=\"ss-pparts\">" + built.participants + " · 2 messages</p>"), sheets(of: html))
        XCTAssertTrue(html.contains("<title>Engines</title>"))
        XCTAssertEqual(PrintDocumentBuilder.title(of: built), "Engines")

        let untitled = payload([F.message("m1", subject: "  ")], bodies: [:])
        let blank = printer.document(for: untitled)
        XCTAssertTrue(blank.contains("<h1 class=\"ss-psubject ss-ph\">No subject</h1>"))
        XCTAssertTrue(blank.contains("· 1 message</p>"))
        XCTAssertEqual(PrintDocumentBuilder.title(of: untitled), "No subject", "Save as PDF offers the placeholder, never an empty name")
    }

    func testTextFromTheMessageIsEscapedOutsideTheBody() {
        let sneaky = EmailAddress(name: "<b>Eve</b> & co", address: "eve@example.com")
        let message = F.message("m1", from: sneaky, subject: "</title><script>alert(1)</script>")
        let html = printer.document(for: payload([message], bodies: [:]))
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&lt;b&gt;Eve&lt;/b&gt; &amp; co"))
        XCTAssertEqual(occurrences(of: "<script", in: html), 1, "the document's own script only")
    }

    func testDraftsAndRepliesOnTheirWaySayWhatTheyAre() {
        let draft = F.message("d1", from: F.me, date: F.utc(2025, 3, 7, 9, 12), roles: [.drafts])
        let reply = F.message("p1", from: F.me, date: F.utc(2025, 3, 7, 14, 0), roles: [.sent])
        let html = printer.document(for: payload([draft, reply], bodies: [draft.id: F.body(html: "<p>Draft</p>"), reply.id: F.body(html: "<p>Reply</p>")],
                                                 pending: [reply.id]))
        XCTAssertTrue(html.contains(">Draft · edited Fri, 7 Mar 2025 at 09:12</time>"), sheets(of: html))
        XCTAssertTrue(html.contains("<span class=\"ss-pdate\">Sending…</span>"))
    }

    func testAttachmentsAreListedWithTheirKindAndSize() {
        let file = AttachmentInfo(id: "a1", filename: "Plan.pdf", mimeType: "application/pdf", sizeBytes: 240_000, isInline: false)
        let logo = AttachmentInfo(id: "a2", filename: "logo.png", mimeType: "image/png", sizeBytes: 100, contentID: "logo", isInline: true)
        let message = F.message("m1", hasAttachments: true)
        let html = printer.document(for: payload([message], bodies: [message.id: F.body(html: "<p>See attached</p>", attachments: [file, logo])]))
        XCTAssertTrue(html.contains("<li><span class=\"ss-pattname\">Plan.pdf</span><span class=\"ss-pattmeta\">PDF · 240 KB</span></li>"), sheets(of: html))
        XCTAssertFalse(html.contains("logo.png"), "an inline image is part of the body, not an attachment")
    }

    // MARK: Bodies

    func testABodyWaitsInertInItsTemplateWithWhatTheReaderShows() {
        let plain = F.message("m1")
        let styled = F.message("m2", date: F.utc(2025, 1, 4))
        var plainBody = F.body(html: "<div class=\"ss-body ss-plain\"><p>Plain words</p></div>")
        plainBody.typesetting = .plain
        plainBody.coveredByNewYork = true
        var styledBody = F.body(html: "<div class=\"ss-body\"><table><tr><td style=\"color:red\">Styled</td></tr></table></div>")
        styledBody.typesetting = .styled
        let built = payload([plain, styled], bodies: [plain.id: plainBody, styled.id: styledBody])
        let html = printer.document(for: built, sheets: [key(styled): PrintSheetState(imagesShown: true, quotesShown: true)])

        // The stored HTML goes in exactly as the reader got it, inside a template, so nothing in it loads or runs yet.
        XCTAssertTrue(html.contains("<template id=\"ss-pb-0\"><div class=\"ss-body ss-plain\"><p>Plain words</p></div></template>"))
        XCTAssertTrue(html.contains("<template id=\"ss-pb-1\">" + styledBody.renderedHTML + "</template>"))
        // A plain body is set on the reading page at the indent; a styled one keeps the sender's design across the page.
        XCTAssertTrue(html.contains("<div class=\"ss-pbody ss-pind\" data-body=\"0\" data-images=\"hidden\" data-classes=\"ss-set\"></div>"), sheets(of: html))
        XCTAssertTrue(html.contains("<div class=\"ss-pbody\" data-body=\"1\" data-images=\"shown\" data-classes=\"ss-show-quotes\"></div>"))
    }

    func testTheReadingFaceFollowsTheFontSettingAndTheScript() {
        let message = F.message("m1")
        var body = F.body(html: "<div class=\"ss-body\"><p>Hello</p></div>")
        body.typesetting = .unstyled
        body.coveredByNewYork = true
        let serif = printer.document(for: payload([message], bodies: [message.id: body]))
        XCTAssertTrue(serif.contains("data-classes=\"ss-set\""))
        XCTAssertTrue(serif.hasPrefix("<!DOCTYPE html><html class=\"ss-print\""))
        let sans = printer.document(for: payload([message], bodies: [message.id: body], readingSans: true))
        XCTAssertTrue(sans.contains("data-classes=\"ss-set ss-sans\""))
        XCTAssertTrue(sans.hasPrefix("<!DOCTYPE html><html class=\"ss-print ss-sf\""), "the masthead and avatars switch face too")
        body.coveredByNewYork = false
        XCTAssertTrue(printer.document(for: payload([message], bodies: [message.id: body])).contains("data-classes=\"ss-set ss-sans\""),
                      "a script New York lacks is set in the sans twin, as in the reader")
    }

    func testUnknownMessagesPrintAsAFreshRenderShowsThem() {
        let message = F.message("m1")
        let body = F.body(html: "<p>Hi <img src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\" data-ss-src=\"https://example.com/a.png\"></p>")
        XCTAssertTrue(printer.document(for: payload([message], bodies: [message.id: body])).contains("data-images=\"hidden\""))
        XCTAssertTrue(printer.document(for: payload([message], bodies: [message.id: body], loadRemoteImages: true)).contains("data-images=\"shown\""),
                      "with Load remote images on, a message the shell never drew shows its images")
    }

    // MARK: What the reader folds or holds back

    func testHeldBackImagesAreCountedAsTheBannerCountsThem() {
        let message = F.message("m1")
        var body = F.body(html: "<p>News <img src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\" data-ss-src=\"https://example.com/a.png\"></p>")
        body.blockedRemoteImageCount = 2
        let built = payload([message], bodies: [message.id: body])
        let held = printer.document(for: built, sheets: [key(message): PrintSheetState(imagesShown: false, liveRemoteImages: 1)])
        XCTAssertTrue(held.contains("<span>3 remote images hidden</span>"), "the parked images and the live ones the reader holds back")
        let one = printer.document(for: built, sheets: [key(message): PrintSheetState(imagesShown: false, liveRemoteImages: -1)])
        XCTAssertTrue(one.contains("<span>2 remote images hidden</span>"), "a count the shell got wrong never lowers the stored one")
        let shown = printer.document(for: built, sheets: [key(message): PrintSheetState(imagesShown: true)])
        XCTAssertFalse(sheets(of: shown).contains("remote image"))
        XCTAssertTrue(shown.contains("data-images=\"shown\""))

        var single = body
        single.blockedRemoteImageCount = 1
        XCTAssertTrue(printer.document(for: payload([message], bodies: [message.id: single])).contains("<span>1 remote image hidden</span>"))
        var none = body
        none.blockedRemoteImageCount = 0
        XCTAssertFalse(sheets(of: printer.document(for: payload([message], bodies: [message.id: none]))).contains("remote image"),
                       "nothing held back, nothing to say")
    }

    func testFoldedQuotedTextIsLeftOutAndSaysSo() {
        let message = F.message("m1")
        var body = F.body(html: "<p>Yes.</p><div class=\"ss-quote\"><p>Earlier words</p></div>")
        body.hasQuotedContent = true
        let built = payload([message], bodies: [message.id: body])
        let folded = printer.document(for: built)
        XCTAssertTrue(folded.contains(PrintDocumentAssets.elideSVG + "<span>Quoted text hidden</span>"), "the note carries the reader's mark")
        XCTAssertTrue(folded.contains("data-classes=\"\""), "the body's own CSS folds the quote, as in the reader")
        let unfolded = printer.document(for: built, sheets: [key(message): PrintSheetState(imagesShown: false, quotesShown: true)])
        XCTAssertFalse(sheets(of: unfolded).contains("Quoted text hidden"))
        XCTAssertTrue(unfolded.contains("data-classes=\"ss-show-quotes\""))
    }

    func testAMessageUnderAnInvitationCardPrintsAsTheReaderShowsIt() throws {
        let message = F.message("m1")
        var body = F.body(html: "<p>Ada has invited you</p><div class=\"ss-quote\"><p>old</p></div>")
        body.hasQuotedContent = true
        body.invitation = CalendarInvitation(
            method: .request, uid: "uid-1", title: "Design review", start: F.utc(2025, 3, 11, 15, 0), end: F.utc(2025, 3, 11, 16, 0),
            location: "Room 4", conferenceURL: "https://meet.example.com/abc",
            organizer: CalendarInvitation.Person(name: "Ada Lovelace", address: "ada@example.com"),
            attendees: [CalendarInvitation.Person(name: nil, address: "me@example.com", response: .accepted)],
            userAddress: "me@example.com", userResponse: .accepted, calendarText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
        )
        let built = payload([message], bodies: [message.id: body])
        let card = try XCTUnwrap(built.messages.first?.invitation)

        let folded = printer.document(for: built)
        XCTAssertTrue(folded.contains("<div class=\"ss-pikick\">Invitation</div><div class=\"ss-pititle\">Design review</div>"), sheets(of: folded))
        XCTAssertTrue(folded.contains("<div class=\"ss-piwhen\">" + PrintDocumentBuilder.escape(card.when) + "</div>"))
        XCTAssertTrue(folded.contains("<dt>Where</dt><dd>Room 4</dd><dt></dt><dd>https://meet.example.com/abc</dd>"), "a link written out in full")
        XCTAssertTrue(folded.contains("<dt>Your answer</dt><dd>Accepted</dd>"))
        XCTAssertFalse(folded.contains("Open in Calendar"))
        XCTAssertFalse(folded.contains("Tentative"))
        XCTAssertTrue(folded.contains(PrintDocumentAssets.elideSVG + "<span>Message hidden</span>"))
        XCTAssertFalse(folded.contains("<template"), "a folded message is not printed at all")
        XCTAssertFalse(folded.contains("Quoted text hidden"), "its quoted text folds with it")

        let shown = printer.document(for: built, sheets: [key(message): PrintSheetState(imagesShown: false, messageShown: true)])
        XCTAssertFalse(shown.contains("Message hidden"))
        XCTAssertTrue(shown.contains("Ada has invited you"))
        XCTAssertTrue(shown.contains("Quoted text hidden"), "its own quoted text keeps its own fold")
    }

    func testACancelledCardIsMarkedAndAnsweredWithNothing() {
        var invitation = RenderPayload.Invitation(title: "", when: "Tue 11 Mar · 15:00 - 16:00", organizer: "Ada Lovelace", isCancelled: true,
                                                  response: .declined)
        let html = PrintDocumentBuilder.invitationCard(invitation)
        XCTAssertTrue(html.hasPrefix("<section class=\"ss-pinvite ss-pind ss-cancelled\"><div class=\"ss-pikick\">Cancelled</div>"))
        XCTAssertTrue(html.contains("<div class=\"ss-pititle ss-ph\">No title</div>"))
        XCTAssertFalse(html.contains("Your answer"), "a cancelled event has nothing to answer")
        invitation.isCancelled = false
        invitation.response = .needsAction
        XCTAssertFalse(PrintDocumentBuilder.invitationCard(invitation).contains("Your answer"), "no answer given, none written")
        XCTAssertEqual(PrintDocumentBuilder.answerWords(.tentative), "Tentative")
        XCTAssertEqual(PrintDocumentBuilder.answerWords(.declined), "Declined")
    }

    func testAMessageWithoutItsBodyPrintsItsPreviewAndSaysSo() {
        let message = F.message("m1", snippet: "Can we move the review to Thursday...")
        let html = printer.document(for: payload([message], bodies: [:], bodyStates: [message.id: .offline]))
        XCTAssertTrue(html.contains(">Can we move the review to Thursday…</p>"), sheets(of: html))
        XCTAssertTrue(html.contains("<span>Only the preview has downloaded</span>"))
        XCTAssertFalse(html.contains("<template"))

        let draft = F.message("d1", from: F.me, roles: [.drafts])
        let open = printer.document(for: payload([draft], bodies: [:], bodyStates: [draft.id: .inComposer]))
        XCTAssertTrue(open.contains("<span>Open in a composer window</span>"))
        XCTAssertFalse(open.contains("Only the preview"))
    }

    // MARK: The document's machinery

    func testThePrintoutHoldsBackWhatTheReaderHoldsBack() {
        // The reader's own policy and mark, not copies that could drift from them.
        XCTAssertTrue(ConversationShellAssets.js.contains("var BLOCKING_CSP = \"" + PrintDocumentAssets.blockingPolicy + "\";"))
        XCTAssertTrue(ConversationShellAssets.js.contains("var ELIDE_SVG = '" + PrintDocumentAssets.elideSVG + "';"))
        let html = printer.document(for: payload([F.message("m1")], bodies: [:]))
        XCTAssertTrue(html.contains("var SS_PRINT_POLICY = " + ConversationShellAssets.jsStringLiteral(PrintDocumentAssets.blockingPolicy) + ";"))
        XCTAssertTrue(html.contains("var SS_PRINT_WAIT = 3000;"))
        XCTAssertTrue(html.contains("window.webkit.messageHandlers." + PrintDocumentBuilder.readyHandlerName + ".postMessage('ready')"))
        // Light whatever the app shows, with the Quire variables the page and the bodies draw with.
        XCTAssertTrue(html.contains("<meta name=\"color-scheme\" content=\"light\">"))
        XCTAssertTrue(html.contains(QuireCSS.head))
        XCTAssertFalse(html.contains("content=\"" + PrintDocumentAssets.blockingPolicy), "the blocking policy is added by the script, after the shown bodies")
        XCTAssertFalse(sheets(of: html).contains("<meta"))
    }

    /// The reader's frames run none of a body's script; on paper the page's own policy keeps it so from the first byte:
    /// only the script carrying the document's nonce runs, and nothing in the policy holds back an image.
    func testOnlyTheDocumentsOwnScriptMayRun() throws {
        let message = F.message("m1")
        let html = printer.document(for: payload([message], bodies: [message.id: F.body(html: "<p>Words</p>")]), nonce: "n0Nce+/=")
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'nonce-n0Nce+/='; object-src 'none'\">"
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html><html class=\"ss-print\" lang=\"en\"><head><meta charset=\"utf-8\">" + policy),
                      "the policy comes first in the head, before any style or body")
        XCTAssertTrue(html.contains("<script nonce=\"n0Nce+/=\">var SS_PRINT_WAIT"), "the document's script carries the nonce")
        XCTAssertEqual(occurrences(of: "<script", in: html), 1)
        XCTAssertEqual(occurrences(of: "<meta http-equiv=\"Content-Security-Policy\"", in: html), 1, "the blocking policy is the script's to add")
        for directive in ["default-src", "img-src", "style-src", "font-src"] {
            XCTAssertFalse(PrintDocumentAssets.scriptPolicy(nonce: "x").contains(directive), "images and styles are the reader's policies' to decide")
        }
        // A new nonce for every document, which no stored body can know.
        let nonces = Set((0..<4).map { _ in PrintDocumentBuilder.makeNonce() })
        XCTAssertEqual(nonces.count, 4)
        XCTAssertTrue(nonces.allSatisfy { Data(base64Encoded: $0)?.count == 16 })
        let fresh = printer.document(for: payload([message], bodies: [:]))
        let nonce = try XCTUnwrap(fresh.components(separatedBy: "'nonce-").dropFirst().first?.components(separatedBy: "'").first)
        XCTAssertTrue(fresh.contains("<script nonce=\"" + nonce + "\">"))
    }

    func testTheScriptAndItsBodyStylesheetParse() throws {
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        // Compiled, not run: there is no document here.
        context.evaluateScript("new Function(" + ConversationShellAssets.jsStringLiteral(PrintDocumentAssets.script(imageWait: 3)) + ");")
        XCTAssertNil(failure)
        XCTAssertTrue(PrintDocumentAssets.script(imageWait: 0.25).hasPrefix("var SS_PRINT_WAIT = 250;"))
        XCTAssertTrue(PrintDocumentAssets.script(imageWait: 3).contains(ConversationShellAssets.jsStringLiteral(PrintDocumentAssets.bodyCSS)))
        // A held-back image takes no room on paper, whatever display the sender gave it.
        XCTAssertTrue(PrintDocumentAssets.bodyCSS.contains("img[data-ss-src] { display: none !important; }"))
    }

    // MARK: The shell's card states

    func testTheShellsCardStatesBecomeSheetStates() {
        let reply: [[String: Any]] = [
            ["id": "a|1", "expanded": true, "imagesLoaded": true, "quotesShown": false, "messageShown": false, "liveRemote": 0],
            ["id": "a|2", "expanded": false, "imagesLoaded": false, "quotesShown": true, "messageShown": true, "liveRemote": 4],
            ["id": "a|3"],
            ["expanded": true],
        ]
        let states = PrintSheetState.states(fromShell: reply, loadRemoteImages: false)
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states["a|1"], PrintSheetState(imagesShown: true))
        XCTAssertEqual(states["a|2"], PrintSheetState(imagesShown: false, quotesShown: true, messageShown: true, liveRemoteImages: 4))
        XCTAssertEqual(states["a|3"], PrintSheetState.fresh(loadRemoteImages: false), "what the shell does not say reads as a fresh render")
        XCTAssertEqual(PrintSheetState.states(fromShell: [["id": "a|3"]], loadRemoteImages: true)["a|3"]?.imagesShown, true)
        XCTAssertTrue(PrintSheetState.states(fromShell: nil, loadRemoteImages: true).isEmpty)
        XCTAssertTrue(PrintSheetState.states(fromShell: "nope", loadRemoteImages: true).isEmpty)
        XCTAssertTrue(ConversationShellAssets.js.contains("liveRemote: card.liveRemote || 0"), "the shell reports what its banner counts")
    }
}
