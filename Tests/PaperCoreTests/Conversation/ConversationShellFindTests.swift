import WebKit
import XCTest
@testable import PaperCore

/// Find in conversation (spec §5.50) in the real shell inside a `WKWebView`: what counts as a match, the marks in the
/// open frames, stepping, what a step opens (a collapsed message, a folded run, quoted text), refreshes from the store,
/// and the content rules still holding. Gated behind `PAPER_UI_TESTS=1` like the shell's other web view tests.
@MainActor
final class ConversationShellFindTests: XCTestCase {
    @MainActor
    private final class ShellMessages: NSObject, WKScriptMessageHandler {
        private(set) var isReady = false
        private(set) var received: [[String: Any]] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { received.append(body) }
            if message.name == ConversationShellAssets.readyHandlerName { isReady = true }
        }

        var finds: [[String: Any]] { received.filter { ($0["kind"] as? String) == "find" } }
    }

    @MainActor
    private final class SchemeStub: NSObject, WKURLSchemeHandler {
        private(set) var paths: [String] = []

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])
            else { return }
            if url.scheme == "ss-remote" { paths.append(url.path) }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    private typealias F = ConversationFixtures
    private var configuration: WKWebViewConfiguration?
    private let schemes = SchemeStub()

    override func tearDown() {
        configuration?.userContentController.removeAllScriptMessageHandlers()
        configuration = nil
        super.tearDown()
    }

    // MARK: What matches

    func testEveryMessageCountsAndOnlyOpenFramesAreMarked() async throws {
        let (webView, handler) = try await loadedShell()
        let messages = [
            F.message("m1", date: F.utc(2025, 3, 1, 9, 0)),
            F.message("m2", date: F.utc(2025, 3, 2, 9, 0)),
            F.message("m3", date: F.utc(2025, 3, 3, 9, 0)),
        ]
        let bodies = [
            messages[0].id: F.body(html: "<p>The engine is ready.</p>"),
            messages[1].id: F.body(html: "<p>Engine two.</p><div class=\"ss-quote\"><p>An old engine.</p></div>"),
            messages[2].id: F.body(html: "<p>Nothing but an ENGINE here.</p>"),
        ]
        try await render(messages, bodies: bodies, in: webView)
        try await waitForFrames(in: webView)

        let result = try await state("window.ss.find('engine')", in: webView)
        XCTAssertEqual(result["count"] as? Int, 4, "collapsed messages and quoted text count too: \(result)")
        XCTAssertEqual(result["index"] as? Int, 0, "nothing is scrolled past: the first match is the current one")
        // The first message opens for its match and is marked once its frame loads; the second, collapsed, has its two
        // matches counted but no frame to mark.
        try await waitUntil("window.ss.findState().marks === 2", in: webView)
        let second = try await cardState(messages[1], in: webView)
        XCTAssertEqual(second["expanded"] as? Bool, false)
        XCTAssertEqual(handler.finds.last?["count"] as? Int, 4, "the count is posted for the bar")
        XCTAssertEqual(handler.finds.last?["query"] as? String, "engine")

        let none = try await state("window.ss.find('turbine')", in: webView)
        XCTAssertEqual(none["count"] as? Int, 0)
        XCTAssertEqual(none["index"] as? Int, -1)
        let marks = try await findState(in: webView)["marks"] as? Int
        XCTAssertEqual(marks, 0, "the last search's marks go")
    }

    func testCaseAccentsAndWhiteSpaceFoldButBlocksDoNot() async throws {
        let (webView, _) = try await loadedShell()
        // The same body open in a frame (the first, unread) and collapsed (the second, read through DOMParser, whose plain
        // text folds a node at a time): both must read alike.
        let messages = [
            F.message("m1", date: F.utc(2025, 3, 1, 9, 0), isRead: false),
            F.message("m2", date: F.utc(2025, 3, 2, 9, 0)),
            F.message("m3", date: F.utc(2025, 3, 3, 9, 0)),
        ]
        let html = "<p>Caf\u{E9}   au&nbsp;lait,\n  please.</p><p>The end</p><p>start of the next</p>"
            + "<span style=\"display: none\">hidden preheader</span><p>Hello <b>wor</b>ld</p><p>stra\u{DF}e</p>"
            + "<div>\n\t  Tabs\tand\r\nbreaks  </div><div>  Lead<i> in</i>  </div>"
        let bodies = [messages[0].id: F.body(html: html), messages[1].id: F.body(html: html), messages[2].id: F.body(html: "<p>Thanks.</p>")]
        try await render(messages, bodies: bodies, in: webView)
        try await waitForFrames(in: webView)
        _ = try await evaluate("window.scrollTo(0, 0)", in: webView)

        for (query, expected) in [("cafe au lait", 1), ("CAFÉ AU", 1), ("lait, please", 1), ("end start", 0), ("preheader", 0),
                                  ("hello world", 1), ("straße", 1), ("   ", 0), ("tabs and breaks", 1), ("breaks lead", 0),
                                  ("lead in", 1)] {
            let result = try await state("window.ss.find(\(ConversationShellAssets.jsStringLiteral(query)))", in: webView)
            XCTAssertEqual(result["count"] as? Int, expected * 2, "“\(query)”, open and collapsed")
        }
        // A fresh search from the top, so the current match is the open copy's.
        _ = try await evaluate("window.ss.findClear(); window.scrollTo(0, 0)", in: webView)
        _ = try await evaluate("window.ss.find('hello world')", in: webView)
        let frame = "document.querySelector('.ss-card[data-id=\"\(RenderPayload.messageKey(for: messages[0].id))\"] iframe').contentDocument"
        let pieces = try await evaluate("""
            Array.prototype.map.call(\(frame).querySelectorAll('mark.ss-find'), function (m) { return m.textContent; }).join('|')
            """, in: webView) as? String
        XCTAssertEqual(pieces, "Hello |wor|ld", "a match across elements is marked piece by piece")
        let current = try await evaluate("\(frame).querySelectorAll('mark.ss-find.ss-find-now').length", in: webView) as? Int
        XCTAssertEqual(current, 3, "every piece of the current match carries the ring")
    }

    /// MJML and hybrid templates set a zero font size on column wrappers and size the text inside: that text is found,
    /// in a frame and in a body read through DOMParser alike, while a preheader hidden by a zero size alone is not.
    func testTextHiddenByItsOwnStyleIsLeftOutAndTextShownAgainCounts() async throws {
        let (webView, _) = try await loadedShell()
        // The first is collapsed and read through DOMParser; the second, the last, opens in a frame.
        let messages = (1...2).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0)) }
        let html = """
            <div style="display:none;font-size:1px;color:#ffffff;line-height:1px;max-height:0px;max-width:0px;opacity:0;\
            overflow:hidden;">Preheader one</div>
            <div style="font-size:0px;color:#ffffff;line-height:0">Preheader two</div>
            <div class="mj-column-per-100" style="font-size:0px;text-align:left;direction:ltr;display:inline-block;\
            vertical-align:top;width:100%;"><table border="0" cellpadding="0" cellspacing="0" role="presentation" width="100%">\
            <tbody><tr><td align="left" style="font-size:0px;padding:10px 25px;word-break:break-word;">\
            <div style="font-family:Ubuntu, Helvetica, Arial, sans-serif;font-size:13px;line-height:1;color:#000000;">\
            Your order has shipped</div></td></tr>\
            <tr><td style="font-size:0"><div style="font-size:150%">Relative tiny</div>\
            <span style="font: 14px/20px Arial">Shorthand sized</span></td></tr></tbody></table></div>
            <div style="visibility:hidden">Ghost words <span style="visibility:visible">Shown again</span></div>
            <div style="font-size:0 !important"><p style="font-size:16px !important">Important size</p></div>
            """
        try await render(messages, bodies: [messages[0].id: F.body(html: html), messages[1].id: F.body(html: html)], in: webView)
        try await waitForFrames(in: webView)
        for (query, expected) in [("your order has shipped", 2), ("shorthand sized", 2), ("shown again", 2), ("important size", 2),
                                  ("preheader", 0), ("relative tiny", 0), ("ghost", 0)] {
            let result = try await state("window.ss.find(\(ConversationShellAssets.jsStringLiteral(query)))", in: webView)
            XCTAssertEqual(result["count"] as? Int, expected, "“\(query)”")
        }
        _ = try await evaluate("window.ss.find('shipped')", in: webView)
        let marked = try await evaluate("""
            document.querySelector('.ss-card[data-id="\(RenderPayload.messageKey(for: messages[1].id))"] iframe')
              .contentDocument.querySelectorAll('mark.ss-find').length
            """, in: webView) as? Int
        XCTAssertEqual(marked, 1, "the open frame marks the column's text")
    }

    func testClearingPutsTheBodyBackAsItWas() async throws {
        let (webView, handler) = try await loadedShell()
        let message = F.message("m1")
        let html = "<p>One <a href=\"https://example.com\">engine</a>, two engines, <i>en</i>gine.</p><table><tr><td>engine</td></tr></table>"
        try await render([message], bodies: [message.id: F.body(html: html)], in: webView)
        try await waitForFrames(in: webView)
        let body = "document.querySelector('.ss-card iframe').contentDocument.body"
        let before = try await evaluate("\(body).innerHTML", in: webView) as? String
        let found = try await state("window.ss.find('engine')", in: webView)
        XCTAssertEqual(found["count"] as? Int, 4)
        let marked = try await evaluate("\(body).innerHTML", in: webView) as? String
        XCTAssertNotEqual(marked, before)
        _ = try await evaluate("window.ss.findClear()", in: webView)
        let after = try await evaluate("\(body).innerHTML", in: webView) as? String
        XCTAssertEqual(after, before, "the marks come out and the text nodes join up again")
        let nodes = try await evaluate("\(body).querySelector('p').childNodes.length", in: webView) as? Int
        XCTAssertEqual(nodes, 5, "“One ”, the link, “, two engines, ”, the italic and “gine.” put back as parsed")
        XCTAssertEqual(handler.finds.last?["query"] as? String, "")
        XCTAssertEqual(handler.finds.last?["count"] as? Int, 0)
    }

    // MARK: Stepping and what it opens

    func testSteppingWrapsAndOpensWhatHidesTheMatch() async throws {
        let (webView, handler) = try await loadedShell()
        let messages = (1...3).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0)) }
        let bodies = [
            messages[0].id: F.body(html: "<p>First word.</p>"),
            messages[1].id: F.body(html: "<p>Reply.</p><div class=\"ss-quote\"><p>On Monday you wrote: word.</p></div>"),
            messages[2].id: F.body(html: "<p>Last word.</p>"),
        ]
        try await render(messages, bodies: bodies, in: webView)
        try await waitForFrames(in: webView)
        _ = try await evaluate("window.scrollTo(0, 0)", in: webView)

        let first = try await state("window.ss.find('word')", in: webView)
        XCTAssertEqual(first["count"] as? Int, 3)
        XCTAssertEqual(first["index"] as? Int, 0, "the page is at the top: the first match")
        var current = try await currentMatch(in: webView)
        XCTAssertEqual(current["id"] as? String, RenderPayload.messageKey(for: messages[0].id))
        let typed = try await cardState(messages[0], in: webView)
        XCTAssertEqual(typed["expanded"] as? Bool, false, "nothing opens while the words may still be typing")
        try await waitUntil(expanded(messages[0]), in: webView)
        let target = try await evaluate("window.ss.selectedMessageID()", in: webView) as? String
        XCTAssertEqual(target, RenderPayload.messageKey(for: messages[0].id), "and becomes the target")

        let second = try await state("window.ss.findStep(1)", in: webView)
        XCTAssertEqual(second["index"] as? Int, 1)
        current = try await currentMatch(in: webView)
        XCTAssertEqual(current["quoted"] as? Bool, true)
        let quoted = try await cardState(messages[1], in: webView)
        XCTAssertEqual(quoted["expanded"] as? Bool, true)
        XCTAssertEqual(quoted["quotesShown"] as? Bool, true, "quoted text holding the current match unfolds")
        try await waitUntil("window.ss.findState().current.marked === true", in: webView)
        let label = try await evaluate("""
            document.querySelector('.ss-card[data-id="\(RenderPayload.messageKey(for: messages[1].id))"] .ss-toggle-quote').textContent
            """, in: webView) as? String
        XCTAssertEqual(label, "Hide quoted text", "the mark says the quote is open, and “.” folds it again")

        let third = try await state("window.ss.findStep(1)", in: webView)
        XCTAssertEqual(third["index"] as? Int, 2)
        let wrapped = try await state("window.ss.findStep(1)", in: webView)
        XCTAssertEqual(wrapped["index"] as? Int, 0, "after the last match comes the first")
        let back = try await state("window.ss.findStep(-1)", in: webView)
        XCTAssertEqual(back["index"] as? Int, 2, "and before the first, the last")

        _ = try await evaluate("window.ss.findClear()", in: webView)
        let stillOpen = try await cardState(messages[1], in: webView)
        XCTAssertEqual(stillOpen["quotesShown"] as? Bool, true, "what the find opened stays open")
        XCTAssertEqual(handler.finds.map { $0["index"] as? Int }, [0, 1, 2, 0, 2, -1])
    }

    func testAMatchInAFoldedRunUnfoldsOnlyThatRun() async throws {
        let (webView, _) = try await loadedShell()
        // Two runs of eight read messages, an unread one between them and the last open: two “5 more messages” rows.
        let messages = (1...18).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0), isRead: $0 != 9) }
        var bodies: [MessageID: StoredBody] = [:]
        for (index, message) in messages.enumerated() {
            bodies[message.id] = F.body(html: index == 4 ? "<p>The needle.</p>" : "<p>Hay.</p>")
        }
        try await render(messages, bodies: bodies, in: webView)
        let folds = try await count(".ss-fold", in: webView)
        XCTAssertEqual(folds, 2)
        let result = try await state("window.ss.find('needle')", in: webView)
        XCTAssertEqual(result["count"] as? Int, 1)
        _ = try await evaluate("window.ss.findStep(1)", in: webView)
        let after = try await count(".ss-fold", in: webView)
        XCTAssertEqual(after, 1, "the run holding the match opens, and only that one")
        let open = try await cardState(messages[4], in: webView)
        XCTAssertEqual(open["expanded"] as? Bool, true)
        let other = try await cardState(messages[12], in: webView)
        XCTAssertEqual(other["folded"] as? Bool, true, "the other run stays folded")
        try await waitUntil("window.ss.findState().marks === 1", in: webView)
    }

    /// The prefixes typed on the way to the words wanted open nothing: what hides the current match opens only once
    /// typing has rested, and only for the match current by then.
    func testTypingOpensNothingUntilItRests() async throws {
        let (webView, _) = try await loadedShell()
        let messages = (1...3).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0)) }
        let bodies = [
            messages[0].id: F.body(html: "<p>Hello all.</p>"),
            messages[1].id: F.body(html: "<p>Notes from Monday.</p>"),
            messages[2].id: F.body(html: "<p>The offsite is on.</p>"),
        ]
        try await render(messages, bodies: bodies, in: webView)
        try await waitForFrames(in: webView)
        _ = try await evaluate("window.scrollTo(0, 0)", in: webView)
        let prefix = try await state("window.ss.find('o')", in: webView)
        XCTAssertEqual(prefix["index"] as? Int, 0, "the first match in view, in the first, collapsed message")
        _ = try await evaluate("window.ss.find('of')", in: webView)
        _ = try await evaluate("window.ss.find('offsite')", in: webView)
        try await Task.sleep(nanoseconds: 600_000_000)
        for message in messages.prefix(2) {
            let card = try await cardState(message, in: webView)
            XCTAssertEqual(card["expanded"] as? Bool, false, "a prefix's match never opened its message")
        }
        let target = try await evaluate("window.ss.selectedMessageID()", in: webView) as? String
        XCTAssertEqual(target, RenderPayload.messageKey(for: messages[2].id))
        _ = try await evaluate("window.ss.find('hello')", in: webView)
        try await waitUntil(expanded(messages[0]), in: webView)
    }

    func testAMatchUnderAnInvitationCardUnfoldsTheMessage() async throws {
        let (webView, _) = try await loadedShell()
        let message = F.message("m1", isRead: false)
        var body = F.body(html: "<p>Agenda: the quarterly figures.</p>")
        body.invitation = CalendarInvitation(
            method: .request, uid: "uid-1", title: "Design review", start: F.utc(2025, 3, 11, 15), end: F.utc(2025, 3, 11, 16),
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@example.com"),
            attendees: [CalendarInvitation.Person(address: "me@example.com", response: .needsAction)],
            userAddress: "me@example.com", userResponse: .needsAction, calendarText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
        try await render([message], bodies: [message.id: body], in: webView)
        try await waitForFrames(in: webView)
        let folded = try await cardState(message, in: webView)
        XCTAssertEqual(folded["foldsMessage"] as? Bool, true)
        XCTAssertEqual(folded["messageShown"] as? Bool, false, "the message starts folded under its card")
        let result = try await state("window.ss.find('quarterly')", in: webView)
        XCTAssertEqual(result["count"] as? Int, 1)
        try await waitUntil("window.ss.cardStates()[0].messageShown === true", in: webView)
        let shown = try await cardState(message, in: webView)
        XCTAssertEqual(shown["messageShown"] as? Bool, true, "the message holding the current match unfolds")
        let card = try await state("window.ss.find('design review')", in: webView)
        XCTAssertEqual(card["count"] as? Int, 0, "the card's own words are the header's, not the message's")
    }

    /// The find keystroke's budget row (docs/ARCHITECTURE.md): a common word over a long conversation, most of it
    /// collapsed, with the open messages marked. The first find in a conversation is the dear one: it reads every
    /// collapsed body through DOMParser before it marks anything, and every conversation shown, or rendered afresh, pays
    /// it again (⌘G in the next conversation is always one). Every keystroke, the first ones included, is asserted
    /// against the budget; the timings are printed for the record.
    func testAFindOverALongConversationStaysInsideItsBudget() async throws {
        let (webView, _) = try await loadedShell()
        let paragraph = "<p>The quarterly figures for the northern region are attached, and the team will review them on Monday.</p>"
        // About 20 KB of text each, half of it quoted.
        let text = String(repeating: paragraph, count: 90)
        var first: [Double] = []
        var later: [Double] = []
        // Three conversations in turn, each rendered afresh: none of them has been read for finding before.
        for round in 1...3 {
            let messages = (1...30).map { F.message("r\(round)m\($0)", date: F.utc(2025, 3, round, 9, $0), isRead: $0 < 28) }
            var bodies: [MessageID: StoredBody] = [:]
            for message in messages {
                bodies[message.id] = F.body(html: "<div>" + text + "</div><div class=\"ss-quote\">" + text + "</div>")
            }
            try await render(messages, bodies: bodies, in: webView)
            try await waitForFrames(in: webView)
            first.append(try await timedFind("t", in: webView))
            for query in ["th", "the", "the ", "the q", "the qu"] { later.append(try await timedFind(query, in: webView)) }
            let found = try await findState(in: webView)
            XCTAssertEqual(found["count"] as? Int, 30 * 180, "every paragraph of every message, quoted text included")
            _ = try await evaluate("window.ss.findClear()", in: webView)
        }
        func line(_ timings: [Double]) -> String { timings.map { String(format: "%.1f", $0) }.joined(separator: ", ") }
        print("Find over 30 messages (ms): first in a conversation \(line(first)); typing on \(line(later))")
        let budget: Double = 50
        XCTAssertLessThan(first.max() ?? .infinity, budget, "the first find in a conversation: \(first)")
        XCTAssertLessThan(later.max() ?? .infinity, budget, "every later keystroke: \(later)")
    }

    func testTheCurrentMatchIsScrolledIntoView() async throws {
        let (webView, _) = try await loadedShell()
        let messages = (1...3).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0), isRead: false) }
        var bodies: [MessageID: StoredBody] = [:]
        for (index, message) in messages.enumerated() {
            bodies[message.id] = F.body(html: "<div style=\"height:900px\">Filler \(index)</div><p>Marker \(index)</p>")
        }
        try await render(messages, bodies: bodies, in: webView)
        try await waitForFrames(in: webView)
        _ = try await evaluate("window.scrollTo(0, 0)", in: webView)
        _ = try await evaluate("window.ss.find('marker 2')", in: webView)
        let place = numbers(try await evaluate("""
            (function () {
              var frame = document.querySelector('.ss-card[data-id="\(RenderPayload.messageKey(for: messages[2].id))"] iframe');
              var mark = frame.contentDocument.querySelector('mark.ss-find');
              return [frame.getBoundingClientRect().top + mark.getBoundingClientRect().top, window.innerHeight, window.scrollY,
                      frame.contentDocument.scrollingElement.scrollTop];
            })()
            """, in: webView))
        XCTAssertEqual(place.count, 4)
        XCTAssertGreaterThan(place[2], 0, "the page scrolled")
        XCTAssertGreaterThanOrEqual(place[0], 0, "the match is on screen: \(place)")
        XCTAssertLessThan(place[0], place[1], "the match is on screen: \(place)")
        XCTAssertEqual(place[3], 0, "the frame itself never scrolls")
    }

    // MARK: Refreshes

    func testAStoreRefreshKeepsTheSearchAndTheCurrentMatch() async throws {
        let (webView, handler) = try await loadedShell()
        let messages = (1...2).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0), isRead: false) }
        var bodies: [MessageID: StoredBody] = [
            messages[0].id: F.body(html: "<p>alpha beta alpha</p>"),
            messages[1].id: F.body(html: "<p>alpha</p>"),
        ]
        try await render(messages, bodies: bodies, in: webView)
        try await waitForFrames(in: webView)
        _ = try await evaluate("window.scrollTo(0, 0)", in: webView)
        _ = try await evaluate("window.ss.find('alpha')", in: webView)
        _ = try await evaluate("window.ss.findStep(1)", in: webView)
        let scrolled = try await evaluate("window.scrollY", in: webView)

        let third = F.message("m3", date: F.utc(2025, 3, 3, 9, 0), isRead: false)
        bodies[third.id] = F.body(html: "<p>alpha again</p>")
        let payload = F.builder.build(messages: messages.map { var m = $0; m.isRead = true; return m } + [third], bodies: bodies,
                                      accounts: F.accounts, now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.update(\(try payload.jsonString()))", in: webView)
        let after = try await findState(in: webView)
        XCTAssertEqual(after["count"] as? Int, 4, "the new message's match counts")
        XCTAssertEqual(after["index"] as? Int, 1, "the current match stays where it was")
        let stayed = try await evaluate("window.scrollY", in: webView) as? Double
        XCTAssertEqual(stayed, scrolled as? Double, "a refresh never scrolls")
        XCTAssertEqual(handler.finds.last?["count"] as? Int, 4, "the bar hears of it")

        let other = F.message("x1", subject: "Another")
        let elsewhere = F.builder.build(messages: [other], bodies: [other.id: F.body(html: "<p>alpha</p>")], accounts: F.accounts,
                                        now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try elsewhere.jsonString()))", in: webView)
        let gone = try await findState(in: webView)
        XCTAssertEqual(gone["query"] as? String, "", "another conversation starts with no search")
        XCTAssertEqual(handler.finds.last?["count"] as? Int, 0)
    }

    // MARK: Content rules

    func testFindingLoadsNothingAndBodiesKeepTheirPolicy() async throws {
        let (webView, _) = try await loadedShell()
        let messages = (1...2).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0)) }
        let bodies = [
            // Collapsed: read through DOMParser, whose document fetches nothing.
            messages[0].id: F.body(html: "<p>Remote <img src=\"ss-remote://host/collapsed.png\"> picture</p>"),
            messages[1].id: F.body(html: "<p>Remote <img src=\"ss-remote://host/open.png\"> picture</p>"),
        ]
        try await render(messages, bodies: bodies, in: webView)
        try await waitForFrames(in: webView)
        let result = try await state("window.ss.find('picture')", in: webView)
        XCTAssertEqual(result["count"] as? Int, 2)
        try await waitUntil(expanded(messages[0]), in: webView)
        _ = try await evaluate("window.ss.findStep(-1)", in: webView)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(schemes.paths, [], "no image is fetched, by the parse or by a frame the find opened")
        let policies = try await evaluate("""
            Array.prototype.map.call(document.querySelectorAll('.ss-card iframe'), function (f) {
              return !!f.contentDocument.querySelector('meta[http-equiv="Content-Security-Policy"]');
            }).join(',')
            """, in: webView) as? String
        XCTAssertEqual(policies, "true,true", "every frame, the one the find opened too, keeps the blocking policy")
        let scripts = try await evaluate("document.querySelectorAll('.ss-card iframe[sandbox=\"allow-same-origin\"]').length", in: webView) as? Int
        XCTAssertEqual(scripts, 2, "the frames stay sandboxed with no scripts")
    }

    // MARK: Helpers

    private func loadedShell() async throws -> (WKWebView, ShellMessages) {
        guard ProcessInfo.processInfo.environment["PAPER_UI_TESTS"] == "1" else {
            throw XCTSkip("Set PAPER_UI_TESTS=1 to drive WebKit")
        }
        let handler = ShellMessages()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemes, forURLScheme: ConversationShellAssets.scheme)
        configuration.setURLSchemeHandler(schemes, forURLScheme: "ss-remote")
        configuration.userContentController.add(handler, name: ConversationShellAssets.readyHandlerName)
        configuration.userContentController.add(handler, name: ConversationShellAssets.messageHandlerName)
        self.configuration = configuration
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString(ConversationShellAssets.html, baseURL: ConversationShellAssets.baseURL)
        var attempts = 0
        while !handler.isReady, attempts < 200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        guard handler.isReady else { throw XCTSkip("no shell") }
        return (webView, handler)
    }

    private func render(_ messages: [MessageMetadata], bodies: [MessageID: StoredBody], in webView: WKWebView) async throws {
        let payload = F.builder.build(messages: messages, bodies: bodies, accounts: F.accounts, now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
    }

    /// Every frame built so far has loaded and been measured.
    private func waitForFrames(in webView: WKWebView) async throws {
        for _ in 0..<100 {
            let heights = numbers(try await evaluate("window.ss.measureAll(); window.ss.iframeHeights()", in: webView)).filter { $0 >= 0 }
            if !heights.isEmpty, heights.allSatisfy({ $0 > 0 }) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("frames never measured")
    }

    private func waitUntil(_ condition: String, in webView: WKWebView) async throws {
        for _ in 0..<50 {
            if try await evaluate("!!(\(condition))", in: webView) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("never: \(condition)")
    }

    private func state(_ script: String, in webView: WKWebView) async throws -> [String: Any] {
        try await evaluate(script, in: webView) as? [String: Any] ?? [:]
    }

    /// How long one `ss.find` takes in the page, in milliseconds.
    private func timedFind(_ query: String, in webView: WKWebView) async throws -> Double {
        try await evaluate("""
            (function () { var t = performance.now(); window.ss.find(\(ConversationShellAssets.jsStringLiteral(query)));
              return performance.now() - t; })()
            """, in: webView) as? Double ?? .infinity
    }

    private func findState(in webView: WKWebView) async throws -> [String: Any] {
        try await state("window.ss.findState()", in: webView)
    }

    private func currentMatch(in webView: WKWebView) async throws -> [String: Any] {
        try await findState(in: webView)["current"] as? [String: Any] ?? [:]
    }

    private func cardState(_ message: MessageMetadata, in webView: WKWebView) async throws -> [String: Any] {
        let key = RenderPayload.messageKey(for: message.id)
        let states = try await evaluate("window.ss.cardStates()", in: webView) as? [[String: Any]] ?? []
        return states.first { ($0["id"] as? String) == key } ?? [:]
    }

    /// A condition for `waitUntil`: the message's card is open.
    private func expanded(_ message: MessageMetadata) -> String {
        let key = ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: message.id))
        return "window.ss.cardStates().some(function (c) { return c.id === \(key) && c.expanded; })"
    }

    private func count(_ selector: String, in webView: WKWebView) async throws -> Int? {
        try await evaluate("document.querySelectorAll(\(ConversationShellAssets.jsStringLiteral(selector))).length", in: webView) as? Int
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func numbers(_ value: Any?) -> [Double] {
        (value as? [NSNumber])?.map(\.doubleValue) ?? []
    }
}
