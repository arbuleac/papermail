import WebKit
import XCTest
@testable import SSCore

/// Drives the real shell inside a `WKWebView`. Gated behind `SS_UI_TESTS=1` because WebKit needs a
/// window-server session; everything else in the suite stays headless.
@MainActor
final class ConversationShellWebViewTests: XCTestCase {
    /// Collects what the shell posts and anything WebKit reports, so a readiness miss names its cause.
    @MainActor
    private final class ShellMessages: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private(set) var isReady = false
        private(set) var received: [[String: Any]] = []
        private(set) var failures: [String] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { received.append(body) }
            if message.name == ConversationShellAssets.readyHandlerName { isReady = true }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failures.append("didFail: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failures.append("didFailProvisionalNavigation: \(error)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            failures.append("web content process terminated")
        }
    }

    /// WebKit stalls a `loadHTMLString` whose base scheme has no handler, so the test registers one as the app does.
    @MainActor
    private final class ShellSchemeStub: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])
            else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    /// Stands in for the network: counts what message bodies try to fetch.
    @MainActor
    private final class RemoteSchemeRecorder: NSObject, WKURLSchemeHandler {
        static let scheme = "ss-remote"
        private(set) var paths: [String] = []

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])
            else { return }
            paths.append(url.path)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    private var configuration: WKWebViewConfiguration?
    private let remote = RemoteSchemeRecorder()

    override func tearDown() {
        configuration?.userContentController.removeAllScriptMessageHandlers()
        configuration = nil
        super.tearDown()
    }

    func testShellRendersTwoCardsWithMeasuredFrames() async throws {
        let (webView, handler) = try await loadedShell()
        let payload = twoMessagePayload()
        let rendered = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        XCTAssertEqual((rendered as? NSNumber)?.intValue, 2)
        let cards = try await evaluate("document.querySelectorAll('.ss-card').length", in: webView)
        XCTAssertEqual((cards as? NSNumber)?.intValue, 2)
        let collapsed = try await evaluate("document.querySelectorAll('.ss-card.ss-collapsed').length", in: webView)
        XCTAssertEqual((collapsed as? NSNumber)?.intValue, 1, "only the last message starts expanded")

        _ = try await evaluate("window.ss.expandAll(); window.ss.cardCount()", in: webView)
        var heights: [Double] = []
        for _ in 0..<100 {
            heights = numbers(try await evaluate("window.ss.measureAll()", in: webView))
            if heights.count == 2, heights.allSatisfy({ $0 > 0 }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(heights.count, 2)
        XCTAssertTrue(heights.allSatisfy { $0 > 0 }, "measured iframe heights: \(heights)")
        let styled = numbers(try await evaluate("window.ss.iframeHeights()", in: webView))
        XCTAssertEqual(styled.count, 2)
        XCTAssertTrue(styled.allSatisfy { $0 > 0 }, "styled iframe heights: \(styled)")

        let quoteButtons = try await evaluate("document.querySelectorAll('.ss-toggle-quote').length", in: webView)
        XCTAssertEqual((quoteButtons as? NSNumber)?.intValue, 1)
        let imageButtons = try await evaluate("document.querySelectorAll('.ss-load-images').length", in: webView)
        XCTAssertEqual((imageButtons as? NSNumber)?.intValue, 1)
        XCTAssertTrue(handler.received.contains { ($0["kind"] as? String) == "ready" }, "ready is also posted on the ss handler")
    }

    /// Reading a thread marks it read half a second after it opens; the store change that follows must
    /// not fold the cards the user is looking at, jump to the top, or re-block the images they loaded.
    func testUpdateKeepsWhatTheReaderIsLookingAt() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let messages = (1...3).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0), isRead: false) }
        var bodies: [MessageID: StoredBody] = [:]
        for (index, message) in messages.enumerated() {
            // Tall enough that the page scrolls; the middle one carries a blocked remote image.
            let image = index == 1 ? "<img data-ss-src=\"https://example.com/a.png\" alt=\"\">" : ""
            bodies[message.id] = F.body(html: "<div style=\"height:700px\">Message \(index + 1)</div>" + image)
        }
        let now = F.utc(2025, 3, 7, 15, 0)
        let unread = F.builder.build(messages: messages, bodies: bodies, accounts: F.accounts, now: now)
        _ = try await evaluate("window.ss.render(\(try unread.jsonString()))", in: webView)
        let collapsedBefore = try await count(".ss-card.ss-collapsed", in: webView)
        XCTAssertEqual(collapsedBefore, 0, "unread cards open expanded")
        let buttonsBefore = try await count(".ss-load-images", in: webView)
        XCTAssertEqual(buttonsBefore, 1)
        try await waitForFrames(count: 3, in: webView)

        let middle = ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: messages[1].id))
        _ = try await evaluate("window.ss.loadImages(\(middle))", in: webView)
        let buttonsAfterLoad = try await count(".ss-load-images", in: webView)
        XCTAssertEqual(buttonsAfterLoad, 0)
        _ = try await evaluate("document.querySelector('.ss-card iframe').dataset.marker = 'kept'", in: webView)
        let scrolled = int(try await evaluate("window.scrollTo(0, 300); window.scrollY", in: webView))
        XCTAssertEqual(scrolled, 300, "the page is tall enough to scroll")

        let read = F.builder.build(messages: messages.map { var m = $0; m.isRead = true; return m }, bodies: bodies, accounts: F.accounts, now: now)
        let updated = int(try await evaluate("window.ss.update(\(try read.jsonString()))", in: webView))
        XCTAssertEqual(updated, 3)
        let dots = try await count(".ss-card.ss-unread", in: webView)
        XCTAssertEqual(dots, 0, "the dots go")
        let collapsedAfter = try await count(".ss-card.ss-collapsed", in: webView)
        XCTAssertEqual(collapsedAfter, 0, "nothing folds")
        let buttonsAfter = try await count(".ss-load-images", in: webView)
        XCTAssertEqual(buttonsAfter, 0, "loaded images stay loaded")
        let scrollAfter = int(try await evaluate("window.scrollY", in: webView))
        XCTAssertEqual(scrollAfter, 300, "the page does not jump")
        let marker = try await evaluate("document.querySelector('.ss-card iframe').dataset.marker", in: webView) as? String
        XCTAssertEqual(marker, "kept", "the frames are the same elements")
        let frames = try await count(".ss-card iframe", in: webView)
        XCTAssertEqual(frames, 3)
    }

    /// Hydration and a reply arriving are the other store changes a shown thread sees: the new body
    /// replaces its snippet fallback and the new card appends, while the untouched card keeps its frame.
    func testUpdateHydratesBodiesAndAppendsNewMessages() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let first = F.message("m1", date: F.utc(2025, 3, 1, 9, 0))
        let second = F.message("m2", from: F.bob, date: F.utc(2025, 3, 2, 9, 0))
        let now = F.utc(2025, 3, 7, 15, 0)
        let partial = F.builder.build(messages: [first, second], bodies: [second.id: F.body(html: "<p>Two</p>")], accounts: F.accounts, now: now)
        _ = try await evaluate("window.ss.render(\(try partial.jsonString()))", in: webView)
        // A body still downloading stands as skeleton bars, never a faded snippet (spec §8.4).
        let skeletonsBefore = try await count(".ss-card .ss-skels.ss-delayed", in: webView)
        XCTAssertEqual(skeletonsBefore, 1)
        let framesBefore = try await count(".ss-card iframe", in: webView)
        XCTAssertEqual(framesBefore, 1, "no frame for a body that is not there")
        _ = try await evaluate("window.ss.expandAll()", in: webView)
        try await waitForFramedCards(in: webView)
        _ = try await evaluate("document.querySelector('.ss-card iframe').dataset.marker = 'kept'", in: webView)

        let third = F.message("m3", from: F.carol, date: F.utc(2025, 3, 3, 9, 0), isRead: false)
        let bodies: [MessageID: StoredBody] = [
            first.id: F.body(html: "<p>One</p>"),
            second.id: F.body(html: "<p>Two</p>"),
            third.id: F.body(html: "<p>Three</p>"),
        ]
        let full = F.builder.build(messages: [first, second, third], bodies: bodies, accounts: F.accounts, now: now)
        let updated = int(try await evaluate("window.ss.update(\(try full.jsonString()))", in: webView))
        XCTAssertEqual(updated, 3)
        let ids = try await evaluate("Array.from(document.querySelectorAll('.ss-card')).map(function (c) { return c.dataset.id; })", in: webView) as? [String]
        XCTAssertEqual(ids, full.messages.map(\.id), "cards follow payload order")
        let skeletonsAfter = try await count(".ss-card .ss-skels.ss-delayed", in: webView)
        XCTAssertEqual(skeletonsAfter, 0, "the skeleton is gone")
        let marker = try await evaluate("document.querySelectorAll('.ss-card iframe')[1].dataset.marker", in: webView) as? String
        XCTAssertEqual(marker, "kept", "an unchanged body keeps its frame")
        let collapsed = try await count(".ss-card.ss-collapsed", in: webView)
        XCTAssertEqual(collapsed, 0, "the new unread card opens expanded")
        try await waitForFrames(count: 3, in: webView)
        let hydrated = try await evaluate("document.querySelector('.ss-card iframe').contentDocument.body.textContent", in: webView) as? String
        XCTAssertEqual(hydrated, "One")
        let selected = try await evaluate("window.ss.selectedMessageID()", in: webView) as? String
        XCTAssertEqual(selected, full.messages[1].id, "the selection is not moved by an update")
    }

    // MARK: Remote images

    /// A body stored while "Load remote images" was on keeps live remote sources. Once the setting is
    /// off they must not load (trackers included) until the user asks, and then parked ones load too.
    func testRemoteImagesStayBlockedUntilTheUserLoadsThem() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1")
        let html = "<p>Hi</p><img src=\"ss-remote://cdn/live.png\" alt=\"\"><img src=\"\(HTMLSanitizer.placeholderImage)\" data-ss-src=\"ss-remote://cdn/parked.png\" alt=\"\">"
        let payload = F.builder.build(messages: [message], bodies: [message.id: F.body(html: html)], accounts: F.accounts)
        XCTAssertFalse(payload.loadRemoteImages)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(remote.paths, [], "nothing remote loads while images are blocked")
        let button = try await evaluate("(document.querySelector('.ss-load-images') || {}).textContent", in: webView) as? String
        XCTAssertEqual(button, "Load images")
        let banner = try await evaluate("document.querySelector('.ss-banner .ss-wide').textContent", in: webView) as? String
        XCTAssertEqual(banner, "2 remote images hidden to protect your privacy.", "live sources count as blocked images too")

        let key = ConversationShellAssets.jsStringLiteral(payload.messages[0].id)
        // "Loading 2 images…" stands while they load (spec §5.16): read in the same turn as the click.
        let loadingCopy = try await evaluate("window.ss.loadImages(\(key)); document.querySelector('.ss-banner .ss-btxt').textContent", in: webView) as? String
        XCTAssertEqual(loadingCopy, "Loading 2 images\u{2026}")
        for _ in 0..<50 where remote.paths.count < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(Set(remote.paths), ["/live.png", "/parked.png"])
        // Then it goes; the stand-in network answers 404, so both report as failed, warning-coloured.
        var loading: Int? = 1
        for _ in 0..<40 {
            loading = int(try await evaluate("document.querySelectorAll('.ss-banner .ss-spin').length", in: webView))
            if loading == 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(loading, 0)
        let buttons = try await count(".ss-load-images", in: webView)
        XCTAssertEqual(buttons, 0)
        let failed = try await evaluate("(document.querySelector('.ss-banner .ss-btxt') || {}).textContent", in: webView) as? String
        XCTAssertEqual(failed, "2 images couldn\u{2019}t load.")
    }

    func testLoadImagesRestoresParkedBackgrounds() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1")
        let html = "<table><tr><td data-ss-background=\"ss-remote://cdn/hero.png\">Hi</td></tr></table>"
        let payload = F.builder.build(messages: [message], bodies: [message.id: F.body(html: html)], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        let button = try await evaluate("(document.querySelector('.ss-load-images') || {}).textContent", in: webView) as? String
        XCTAssertEqual(button, "Load images")
        let banner = try await evaluate("document.querySelector('.ss-banner .ss-wide').textContent", in: webView) as? String
        XCTAssertEqual(banner, "1 remote image hidden to protect your privacy.")

        let key = ConversationShellAssets.jsStringLiteral(payload.messages[0].id)
        _ = try await evaluate("window.ss.loadImages(\(key))", in: webView)
        for _ in 0..<50 where remote.paths.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(remote.paths, ["/hero.png"])
    }

    func testRemoteImagesLoadAtOnceWhenTheSettingIsOn() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1")
        let html = "<p>Hi</p><img src=\"\(HTMLSanitizer.placeholderImage)\" data-ss-src=\"ss-remote://cdn/parked.png\" alt=\"\">"
        let payload = F.builder.build(messages: [message], bodies: [message.id: F.body(html: html)], accounts: F.accounts, loadRemoteImages: true)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        for _ in 0..<50 where remote.paths.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(remote.paths, ["/parked.png"], "mail stored while the setting was off follows it once it is on")
        let buttons = try await count(".ss-load-images", in: webView)
        XCTAssertEqual(buttons, 0)
    }

    // MARK: Flags

    func testFlagPatchesTouchOnlyTheHeaders() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1", isRead: false)
        let payload = F.builder.build(messages: [message], bodies: [message.id: F.body(html: "<p>Body</p>")], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        _ = try await evaluate("document.querySelector('.ss-card iframe').dataset.marker = 'kept'", in: webView)
        let unreadBefore = try await count(".ss-card.ss-unread", in: webView)
        XCTAssertEqual(unreadBefore, 1)

        let patch = [RenderPayload.FlagPatch(id: payload.messages[0].id, isUnread: false, isStarred: true)]
        let json = String(decoding: try JSONEncoder().encode(patch), as: UTF8.self)
        let patched = int(try await evaluate("window.ss.flags(\(json))", in: webView))
        XCTAssertEqual(patched, 1)
        let unreadAfter = try await count(".ss-card.ss-unread", in: webView)
        XCTAssertEqual(unreadAfter, 0)
        let marker = try await evaluate("document.querySelector('.ss-card iframe').dataset.marker", in: webView) as? String
        XCTAssertEqual(marker, "kept", "the body frame is left alone")
    }

    // MARK: Unsubscribe (spec §5.14)

    /// The link shows beside the sender of a message that offers it, after the name and before the address, and on no
    /// other sheet; a click asks the app, naming the message; a store change that takes the headers away removes it.
    func testTheUnsubscribeLinkShowsBesideTheSenderOnlyWhereItIsOffered() async throws {
        let (webView, handler) = try await loadedShell()
        typealias F = ConversationFixtures
        var newsletter = F.message("m1", date: F.utc(2025, 3, 6, 9, 0), isRead: false)
        newsletter.listUnsubscribe = "<https://news.example.com/u/1>"
        newsletter.listUnsubscribePost = "List-Unsubscribe=One-Click"
        let plain = F.message("m2", from: F.bob, date: F.utc(2025, 3, 7, 9, 0), isRead: false)
        let bodies = [newsletter.id: F.body(html: "<p>Issue</p>"), plain.id: F.body(html: "<p>Hi</p>")]
        let now = F.utc(2025, 3, 20, 9, 0)
        let payload = F.builder.build(messages: [newsletter, plain], bodies: bodies, accounts: F.accounts, now: now)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrames(count: 2, in: webView)

        let links = try await count(".ss-unsub", in: webView)
        XCTAssertEqual(links, 1, "only the message that offers it")
        let owner = try await evaluate("document.querySelector('.ss-unsub').closest('.ss-card').dataset.id", in: webView) as? String
        XCTAssertEqual(owner, payload.messages[0].id)
        let line = try await evaluate(
            "Array.prototype.map.call(document.querySelector('.ss-unsub').parentNode.children, function (n) { return n.className; }).join(',')",
            in: webView) as? String
        XCTAssertEqual(line, "ss-pip7,ss-name,ss-unsub,ss-addr", "beside the sender: after the name, before the address")
        let text = try await evaluate("document.querySelector('.ss-unsub').textContent", in: webView) as? String
        XCTAssertEqual(text, "Unsubscribe")
        let tag = try await evaluate("document.querySelector('.ss-unsub').tagName", in: webView) as? String
        XCTAssertEqual(tag, "BUTTON", "a control VoiceOver reads as a button, drawn as a link")
        let title = try await evaluate("document.querySelector('.ss-unsub').title", in: webView) as? String
        XCTAssertEqual(title, "Unsubscribe  \u{21E7}\u{2318}U")
        let underline = try await evaluate("getComputedStyle(document.querySelector('.ss-unsub')).textDecorationLine", in: webView) as? String
        XCTAssertEqual(underline, "underline")

        // A double-click's second click (detail 2) asks nothing: it may land on the next conversation's link.
        _ = try await evaluate("document.querySelector('.ss-unsub').dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 2 }))",
                               in: webView)
        _ = try await evaluate("document.querySelector('.ss-unsub').click()", in: webView)
        var asked = false
        for _ in 0..<50 where !asked {
            asked = handler.received.contains {
                ($0["kind"] as? String) == "action" && ($0["type"] as? String) == "unsubscribe" && ($0["messageID"] as? String) == payload.messages[0].id
            }
            if !asked { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(asked, "a click asks the app to unsubscribe from that message")
        let asks = handler.received.filter { ($0["kind"] as? String) == "action" && ($0["type"] as? String) == "unsubscribe" }
        XCTAssertEqual(asks.count, 1, "the second click of a double-click is not a second request")

        newsletter.listUnsubscribe = nil
        let without = F.builder.build(messages: [newsletter, plain], bodies: bodies, accounts: F.accounts, now: now)
        _ = try await evaluate("window.ss.update(\(try without.jsonString()))", in: webView)
        let after = try await count(".ss-unsub", in: webView)
        XCTAssertEqual(after, 0, "an update redraws the header")
    }

    /// At the minimum window's reader (520 pt) the link takes its room from the address, which shows nothing at rest,
    /// before the name gives any; in a wider reader the name is whole and the address keeps what is left for hover
    /// (spec §5.14).
    func testTheLinkTakesItsRoomFromTheHiddenAddressBeforeTheName() async throws {
        let (webView, _) = try await loadedShell(width: 520)
        typealias F = ConversationFixtures
        var newsletter = F.message("m1", from: EmailAddress(name: "The New York Times Opinion Today", address: "nytdirect@nytimes.com"),
                                   date: F.utc(2025, 3, 6, 9, 0), isRead: false)
        newsletter.listUnsubscribe = "<https://news.example.com/u/1>"
        let payload = F.builder.build(messages: [newsletter], bodies: [newsletter.id: F.body(html: "<p>Issue</p>")], accounts: F.accounts,
                                      now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        let measure = """
            (function () { var n = document.querySelector('.ss-name'), a = document.querySelector('.ss-addr');
              return [n.clientWidth, n.scrollWidth, a.clientWidth, a.scrollWidth, document.querySelector('.ss-nl').clientWidth]; })()
            """
        let narrow = numbers(try await evaluate(measure, in: webView))
        XCTAssertEqual(narrow.count, 5)
        guard narrow.count == 5 else { return }
        XCTAssertGreaterThan(narrow[1], narrow[0], "the name is cut at this width: \(narrow)")
        XCTAssertEqual(narrow[2], 0, "so the hidden address holds no room beside the link: \(narrow)")

        webView.setFrameSize(NSSize(width: 800, height: 600))
        var wide: [Double] = []
        for _ in 0..<50 {
            wide = numbers(try await evaluate(measure, in: webView))
            if wide.count == 5, wide[4] > narrow[4] { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(wide.count, 5)
        guard wide.count == 5 else { return }
        XCTAssertGreaterThan(wide[4], narrow[4], "the line widened with the reader: \(wide)")
        XCTAssertEqual(wide[0], wide[1], "the name whole: \(wide)")
        XCTAssertGreaterThan(wide[2], 0, "and the address keeps what is left, for hover: \(wide)")
    }

    // MARK: Quire reader (spec §5.13–5.19)

    /// More than six collapsed messages keep the first and the last two and fold the rest into one row.
    func testLongStacksFoldTheirMiddle() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let messages = (1...9).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0)) }
        let payload = F.builder.build(messages: messages, bodies: [:], accounts: F.accounts, now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let fold = try await evaluate("(document.querySelector('.ss-fold') || {}).textContent", in: webView) as? String
        XCTAssertEqual(fold, "5 more messages", "eight collapsed: one kept, five folded, two kept")
        let visibleRows = try await count(".ss-card.ss-collapsed:not(.ss-folded)", in: webView)
        XCTAssertEqual(visibleRows, 3)
        let runEnds = try await count(".ss-run-start", in: webView)
        XCTAssertEqual(runEnds, 1, "one stack")
        _ = try await evaluate("document.querySelector('.ss-fold').click()", in: webView)
        let folds = try await count(".ss-fold", in: webView)
        XCTAssertEqual(folds, 0)
        let unfolded = try await count(".ss-card.ss-collapsed:not(.ss-folded)", in: webView)
        XCTAssertEqual(unfolded, 8)
    }

    /// The target carries the R · A · F keycaps; several open sheets give it the strong edge; N moves it.
    func testTargetMessageAndStepping() async throws {
        let (webView, handler) = try await loadedShell()
        typealias F = ConversationFixtures
        let messages = (1...3).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0), isRead: $0 != 2) }
        let bodies = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, F.body(html: "<p>Body \($0.id.providerID)</p>")) })
        let payload = F.builder.build(messages: messages, bodies: bodies, accounts: F.accounts, now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let target = try await evaluate("window.ss.selectedMessageID()", in: webView) as? String
        XCTAssertEqual(target, payload.messages[2].id, "the last expanded message is the target on open")
        let multi = try await count("#ss-root.ss-multi", in: webView)
        XCTAssertEqual(multi, 1, "the unread middle message and the last one are open")
        let stepped = try await evaluate("window.ss.step(-1)", in: webView) as? String
        XCTAssertEqual(stepped, payload.messages[1].id)
        let ring = try await count(".ss-card.ss-focus", in: webView)
        XCTAssertEqual(ring, 1, "N and P draw the keyboard ring")
        XCTAssertTrue(handler.received.contains { ($0["kind"] as? String) == "select" && ($0["messageID"] as? String) == payload.messages[1].id })

        // A click inside a body runs no listener there; focus moving into its frame makes that message the target.
        // The web view has no window, so the page stands in for one with focus.
        try await waitForFramedCards(in: webView)
        _ = try await evaluate("document.hasFocus = function () { return true; }; true", in: webView)
        _ = try await evaluate("document.querySelectorAll('.ss-card iframe')[1].focus(); window.dispatchEvent(new Event('blur'))", in: webView)
        var clicked: String?
        for _ in 0..<20 {
            clicked = try await evaluate("window.ss.selectedMessageID()", in: webView) as? String
            if clicked == payload.messages[2].id { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(clicked, payload.messages[2].id)

        // From one body straight into another: the shell hears no blur, so it watches while focus is in a body.
        _ = try await evaluate("document.querySelectorAll('.ss-card iframe')[0].focus()", in: webView)
        var next: String?
        for _ in 0..<20 {
            next = try await evaluate("window.ss.selectedMessageID()", in: webView) as? String
            if next == payload.messages[1].id { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(next, payload.messages[1].id)
    }

    /// The watch for focus moving between bodies runs only while the page has focus: once the window or the web
    /// view loses it, the body stays the active element, and an interval left running would tick every 300 ms for as
    /// long as the conversation stays open (Q1.7d). The app's `focusChanged` starts it again when focus may be back.
    func testTheFocusWatchStopsWhenThePageLosesFocus() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let messages = (1...3).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0), isRead: $0 != 2) }
        let bodies = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, F.body(html: "<p>Body \($0.id.providerID)</p>")) })
        let payload = F.builder.build(messages: messages, bodies: bodies, accounts: F.accounts, now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFramedCards(in: webView)
        // The open bodies are the second and third messages. The web view has no window, so the page's focus is the
        // test's, and every look the watch takes is counted.
        let looks = { [self] in int(try await evaluate("window.ssLooks", in: webView)) ?? 0 }
        _ = try await evaluate("""
            window.ssPageFocused = true; window.ssLooks = 0;
            document.hasFocus = function () { window.ssLooks++; return window.ssPageFocused; };
            document.querySelectorAll('.ss-card iframe')[0].focus(); window.dispatchEvent(new Event('blur'))
            """, in: webView)
        let clicked = try await waitForTarget(payload.messages[1].id, in: webView)
        XCTAssertEqual(clicked, payload.messages[1].id)
        let first = try await looks()
        let watching = try await waitForLooks(above: first + 1, in: webView)
        XCTAssertGreaterThan(watching, first + 1, "watching while the page has focus")

        // The window resigns key, or the list takes first responder: the body is still the active element. The next
        // look stops the watch; after it nothing looks, however long the machine takes.
        let atBlur = int(try await evaluate("window.ssPageFocused = false; window.ssLooks", in: webView)) ?? 0
        let stopped = try await waitForLooks(above: atBlur, in: webView)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let idle = try await looks()
        XCTAssertEqual(idle, stopped, "no watch while the page has no focus")

        // Focus is back (the app calls focusChanged): the watch looks again, and keeps looking.
        _ = try await evaluate("window.ssPageFocused = true; window.ss.focusChanged(); true", in: webView)
        let resumed = try await waitForLooks(above: idle + 1, in: webView)
        XCTAssertGreaterThan(resumed, idle + 1, "watching again")

        // The window became key with focus elsewhere: one look, and the watch stops again.
        let atLoss = int(try await evaluate("window.ssPageFocused = false; window.ssLooks", in: webView)) ?? 0
        let stoppedAgain = try await waitForLooks(above: atLoss, in: webView)
        let atKey = int(try await evaluate("window.ss.focusChanged(); window.ssLooks", in: webView)) ?? 0
        XCTAssertEqual(atKey, stoppedAgain)
        let once = try await waitForLooks(above: atKey, in: webView)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let after = try await looks()
        XCTAssertEqual(once, atKey + 1)
        XCTAssertEqual(after, once, "stopped after one look")
    }

    private func waitForTarget(_ id: String, in webView: WKWebView) async throws -> String? {
        var target: String?
        for _ in 0..<50 {
            target = try await evaluate("window.ss.selectedMessageID()", in: webView) as? String
            if target == id { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return target
    }

    /// The count of the watch's looks once it has passed `count`, or as it stands after 5 s.
    private func waitForLooks(above count: Int, in webView: WKWebView) async throws -> Int {
        var looks = 0
        for _ in 0..<50 {
            looks = int(try await evaluate("window.ssLooks", in: webView)) ?? 0
            if looks > count { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return looks
    }

    /// Plain and unstyled bodies are set on the Quire reading page; styled ones keep their own design (§8.4).
    func testTypesetBodiesAreSetLikeAPage() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let plain = F.message("m1", date: F.utc(2025, 3, 1, 9, 0))
        let styled = F.message("m2", date: F.utc(2025, 3, 2, 9, 0))
        var plainBody = F.body(html: "<p>Plain</p>")
        plainBody.typesetting = .unstyled
        plainBody.coveredByNewYork = true
        var styledBody = F.body(html: "<p style=\"color:#123456\">Styled</p>")
        styledBody.typesetting = .styled
        styledBody.declaresColors = true
        let payload = F.builder.build(messages: [plain, styled], bodies: [plain.id: plainBody, styled.id: styledBody], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString())); window.ss.expandAll()", in: webView)
        try await waitForFramedCards(in: webView)
        let classes = try await evaluate("Array.from(document.querySelectorAll('.ss-card iframe')).map(function (f) { return f.contentDocument.body.className; })", in: webView) as? [String]
        XCTAssertEqual(classes, ["ss-set", ""])
        let typeset = try await count(".ss-card.ss-typeset", in: webView)
        XCTAssertEqual(typeset, 1)
        _ = try await evaluate("window.ss.preferences({readingSans: true, colorsNoticeDismissed: false})", in: webView)
        let sans = try await evaluate("document.querySelector('.ss-card iframe').contentDocument.body.className", in: webView) as? String
        XCTAssertEqual(sans, "ss-set ss-sans")
    }

    /// The Font setting reaches the shell's own New York too (spec §4.4): `readingSans` puts `html.ss-sf` on the
    /// root, which sets the avatar initials in SF Pro at the twin's size, live through `ss.preferences` and from
    /// any payload built afterwards.
    func testTheSFProFontSetsTheAvatarInitialsInTheTwin() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        _ = try await evaluate("window.ss.render(\(try twoMessagePayload().jsonString())); window.ss.expandAll()", in: webView)
        try await waitForFramedCards(in: webView)
        let probe = "(function () { var a = document.querySelector('.ss-av36'); var s = getComputedStyle(a);"
            + " return [document.documentElement.classList.contains('ss-sf'), s.fontFamily, s.fontSize]; })()"
        let serif = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertEqual(serif?.first as? Bool, false)
        XCTAssertTrue((serif?[1] as? String ?? "").contains("serif"), "\(String(describing: serif))")
        XCTAssertEqual(serif?[2] as? String, "15px", "0.42 × 36")
        _ = try await evaluate("window.ss.preferences({readingSans: true, colorsNoticeDismissed: false})", in: webView)
        let sans = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertEqual(sans?.first as? Bool, true)
        XCTAssertFalse((sans?[1] as? String ?? "").contains("ui-serif"), "\(String(describing: sans))")
        XCTAssertEqual(sans?[2] as? String, "14px", "monogramSans: 0.39 × 36")
        // A payload carries the choice: rendering one built under New York takes the class off again.
        let payload = F.builder.build(messages: [F.message("m1")], bodies: [:], accounts: F.accounts, readingSans: false)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let again = try await evaluate("document.documentElement.classList.contains('ss-sf')", in: webView) as? Bool
        XCTAssertEqual(again, false)
    }

    /// The reader's Text size (spec §4.15): `ss.preferences({textSize})` puts the class on the shell and on every body
    /// document, live, so a plain body's text and the sheet's header grow by the step, the bodies are measured again
    /// and the sheets take their new heights; a styled body keeps its own size; a payload carries the size.
    func testTheReadersTextSizeStepsSheetsAndPlainBodiesLive() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let plain = F.message("m1", date: F.utc(2025, 3, 1, 9, 0))
        let styled = F.message("m2", date: F.utc(2025, 3, 2, 9, 0))
        var plainBody = F.body(html: "<p>Plain words that wrap over a few lines when the reader is narrow enough for them to.</p>")
        plainBody.typesetting = .unstyled
        plainBody.coveredByNewYork = true
        var styledBody = F.body(html: "<p style=\"font-size:13px;color:#123456\">Styled</p>")
        styledBody.typesetting = .styled
        styledBody.declaresColors = true
        let payload = F.builder.build(messages: [plain, styled], bodies: [plain.id: plainBody, styled.id: styledBody], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString())); window.ss.expandAll()", in: webView)
        try await waitForFramedCards(in: webView)
        let probe = "(function () { var f = document.querySelectorAll('.ss-card iframe'); var name = document.querySelector('.ss-name');"
            + " var nl = document.querySelector('.ss-nl'), rc = document.querySelector('.ss-rc'), meta = document.querySelector('.ss-meta');"
            + " return [document.documentElement.className, f[0].contentDocument.documentElement.className,"
            + " getComputedStyle(f[0].contentDocument.body).fontSize, getComputedStyle(f[0].contentDocument.body).lineHeight,"
            + " getComputedStyle(f[1].contentDocument.querySelector('p')).fontSize, name ? getComputedStyle(name).fontSize : '',"
            + " f[0].getBoundingClientRect().height, nl ? getComputedStyle(nl).height : '', rc ? getComputedStyle(rc).lineHeight : '',"
            + " meta ? getComputedStyle(meta).height : '']; })()"
        let before = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertFalse((before?[0] as? String ?? "").contains("ss-text-"), "Default has no class")
        XCTAssertEqual(before?[2] as? String, "15px")
        XCTAssertEqual(before?[3] as? String, "24px")
        XCTAssertEqual(before?[4] as? String, "13px")
        XCTAssertEqual(before?[7] as? String, "18px", "the name line's box at Default")
        XCTAssertEqual(before?[8] as? String, "16px", "the recipients line at Default")
        XCTAssertEqual(before?[9] as? String, "18px", "the date's box at Default")

        _ = try await evaluate("window.ss.preferences({readingSans: false, textSize: 'larger', colorsNoticeDismissed: false})", in: webView)
        try await Task.sleep(nanoseconds: 150_000_000)
        let larger = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertTrue((larger?[0] as? String ?? "").contains("ss-text-larger"), "\(String(describing: larger))")
        XCTAssertTrue((larger?[1] as? String ?? "").contains("ss-text-larger"), "the body document takes the class")
        XCTAssertEqual(larger?[2] as? String, "17px", "reading 15 + 2")
        XCTAssertEqual(larger?[3] as? String, "26px", "its line 24 + 2")
        XCTAssertEqual(larger?[4] as? String, "13px", "styled HTML keeps its own size")
        if let a = before?[5] as? String, let b = larger?[5] as? String, !a.isEmpty {
            XCTAssertEqual((Double(b.dropLast(2)) ?? 0) - (Double(a.dropLast(2)) ?? 0), 2, "the sheet's header steps too")
        }
        XCTAssertEqual(larger?[7] as? String, "20px", "the name line's box grows with bodyStrong, so the name fits it")
        XCTAssertEqual(larger?[8] as? String, "18px", "the recipients line grows with snippet")
        XCTAssertEqual(larger?[9] as? String, "20px", "and the date's box")
        let grew = (larger?[6] as? Double ?? 0) > (before?[6] as? Double ?? 0)
        XCTAssertTrue(grew, "the plain body was measured again: \(String(describing: before?[6])) → \(String(describing: larger?[6]))")

        _ = try await evaluate("window.ss.preferences({readingSans: false, textSize: 'small', colorsNoticeDismissed: false})", in: webView)
        let small = try await evaluate(probe, in: webView) as? [Any]
        XCTAssertTrue((small?[0] as? String ?? "").contains("ss-text-small"))
        XCTAssertFalse((small?[0] as? String ?? "").contains("ss-text-larger"), "one size at a time")
        XCTAssertEqual(small?[2] as? String, "14px")
        XCTAssertEqual(small?[7] as? String, "17px", "the boxes shrink by the step at Small")
        XCTAssertEqual(small?[8] as? String, "15px")

        // A payload carries the size: rendering one built at Default takes the class off again.
        let plainOnly = F.builder.build(messages: [plain], bodies: [plain.id: plainBody], accounts: F.accounts, textSize: "default")
        _ = try await evaluate("window.ss.render(\(try plainOnly.jsonString()))", in: webView)
        let again = try await evaluate("document.documentElement.className", in: webView) as? String
        XCTAssertFalse((again ?? "").contains("ss-text-"))
    }

    /// A Gmail reply ends its new text with a <br> before the quote; folded, that break must not leave an empty
    /// line between the body and the elision mark, and unfolded the reply reads as sent (spec §5.14, §5.15).
    func testAFoldedQuoteLeavesNoEmptyLine() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1")
        let html = "<div dir=\"ltr\"><div>Green for the 14th.</div></div><br><div class=\"ss-quote\"><p>Earlier</p></div>"
        let without = F.message("m2", date: F.utc(2025, 1, 4, 9, 0))
        let payload = F.builder.build(
            messages: [message, without],
            bodies: [message.id: F.body(html: html), without.id: F.body(html: "<div dir=\"ltr\"><div>Green for the 14th.</div></div>")],
            accounts: F.accounts
        )
        _ = try await evaluate("window.ss.render(\(try payload.jsonString())); window.ss.expandAll()", in: webView)
        try await waitForFramedCards(in: webView)
        let heightsScript = "Array.from(document.querySelectorAll('.ss-card iframe')).map(function (f) { return f.contentDocument.body.scrollHeight; })"
        let folded = numbers(try await evaluate(heightsScript, in: webView))
        XCTAssertEqual(folded.count, 2)
        XCTAssertEqual(folded.first, folded.last, "the folded quote adds nothing, not even its <br>")
        let tooltip = try await evaluate("document.querySelector('.ss-toggle-quote').title", in: webView) as? String
        XCTAssertEqual(tooltip, "Show Quoted Text  .")
        _ = try await evaluate("document.querySelector('.ss-toggle-quote').click()", in: webView)
        let unfolded = numbers(try await evaluate(heightsScript, in: webView))
        XCTAssertGreaterThan(unfolded.first ?? 0, (folded.first ?? 0) + 20, "the break and the quote come back together")
        let open = try await evaluate("document.querySelector('.ss-toggle-quote').title", in: webView) as? String
        XCTAssertEqual(open, "Hide Quoted Text  .")
    }

    /// A draft is set from the sheet's edge, and so are its chips and footer (spec §5.19); a frame still loading
    /// under its provisional height holds delayed bars, never bars that flash on every expand (spec §5.14).
    func testDraftsStartAtTheSheetEdgeAndLoadingFramesHoldDelayedBars() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let draft = F.message("d1", roles: [.drafts])
        let payload = F.builder.build(messages: [draft], bodies: [draft.id: F.body(html: "<p>Unsent</p>")], accounts: F.accounts)
        // Counted in the same turn as the render: the frame's load, which removes the bars, can land before a second call.
        let held = int(try await evaluate("window.ss.render(\(try payload.jsonString())); document.querySelectorAll('.ss-card .ss-skels.ss-held').length", in: webView))
        XCTAssertEqual(held, 1, "the loading frame's bars wait for skeletonDelay")
        let margins = try await evaluate("Array.from(document.querySelectorAll('.ss-card.ss-draft .ss-ind')).map(function (n) { return getComputedStyle(n).marginLeft; })", in: webView) as? [String]
        // The message's elision mark (never shown on a draft, which has no invitation card), the quoted-text toggle,
        // the chips and the footer.
        XCTAssertEqual(margins, ["0px", "0px", "0px", "0px"])
    }

    /// Downloading (spec §5.17): the chip's meta gives way to the 120 pt contrail, sweeping until a fraction is
    /// known, and comes back when the fetch ends.
    func testADownloadingChipShowsItsContrail() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1")
        let file = AttachmentInfo(id: "att-1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 240_000, isInline: false)
        let payload = F.builder.build(messages: [message], bodies: [message.id: F.body(html: "<p>Plan</p>", attachments: [file])], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let key = ConversationShellAssets.jsStringLiteral(payload.messages[0].id)
        _ = try await evaluate("window.ss.attachmentProgress(\(key), 'att-1', null)", in: webView)
        let sweeping = try await count(".ss-chip.ss-loading .ss-dl.ss-sweep", in: webView)
        XCTAssertEqual(sweeping, 1)
        let metaShown = try await evaluate("getComputedStyle(document.querySelector('.ss-chip .ss-chip-meta')).display", in: webView) as? String
        XCTAssertEqual(metaShown, "none", "the meta gives way")
        let barWidth = try await evaluate("getComputedStyle(document.querySelector('.ss-chip .ss-dl')).width", in: webView) as? String
        XCTAssertEqual(barWidth, "120px")
        _ = try await evaluate("window.ss.attachmentProgress(\(key), 'att-1', 0.5)", in: webView)
        let fill = try await evaluate("document.querySelector('.ss-chip .ss-dl-fill').style.width", in: webView) as? String
        XCTAssertEqual(fill, "60px")
        _ = try await evaluate("window.ss.attachmentProgress(\(key), 'att-1', -1)", in: webView)
        let loading = try await count(".ss-chip.ss-loading", in: webView)
        XCTAssertEqual(loading, 0, "the meta comes back")
    }

    /// A reply still in the outbox is the last sheet, dated “Sending…” with the spinner and offering no actions
    /// (spec §5.14).
    func testAPendingReplyReadsSending() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let original = F.message("m1")
        let outgoing = OutgoingMessage(accountID: original.id.accountID, to: [EmailAddress(name: "Ada", address: "ada@example.com")],
                                       subject: "Re: Engines", html: "<p>On my way</p>", text: "On my way", inReplyTo: original.id)
        let sheet = try XCTUnwrap(PendingSheet.sheets(for: [PendingSendSummary(PendingSend(id: "s1", message: outgoing, sendAfter: Date()))],
                                                      answering: [original], accounts: F.accounts).first)
        let payload = F.builder.build(messages: [original, sheet.metadata],
                                      bodies: [original.id: F.body(html: "<p>Engines</p>"), sheet.metadata.id: sheet.body],
                                      accounts: F.accounts, pending: [sheet.metadata.id])
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let last = "document.querySelectorAll('.ss-card')[1]"
        let date = try await evaluate("\(last).querySelector('.ss-meta .ss-date').textContent", in: webView) as? String
        XCTAssertEqual(date, "Sending\u{2026}")
        let spinners = int(try await evaluate("\(last).querySelectorAll('.ss-meta .ss-spin').length", in: webView))
        XCTAssertEqual(spinners, 1)
        let buttons = int(try await evaluate("\(last).querySelectorAll('.ss-hacts button, .ss-foot button').length", in: webView))
        XCTAssertEqual(buttons, 0)
    }

    /// A chip whose file could not be fetched says so and offers the retry (spec §5.17); opening it again clears it.
    func testAFailedAttachmentChipOffersRetry() async throws {
        let (webView, handler) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1")
        let file = AttachmentInfo(id: "att-1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 240_000, isInline: false)
        let payload = F.builder.build(messages: [message], bodies: [message.id: F.body(html: "<p>Plan</p>", attachments: [file])], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let key = ConversationShellAssets.jsStringLiteral(payload.messages[0].id)
        _ = try await evaluate("window.ss.attachmentFailed(\(key), 'att-1', true)", in: webView)
        let meta = try await evaluate("document.querySelector('.ss-chip.ss-failed .ss-rest-meta').textContent", in: webView) as? String
        XCTAssertEqual(meta, "Couldn\u{2019}t download \u{00b7} Retry")
        _ = try await evaluate("window.ss.attachmentFailed(\(key), 'att-1', false)", in: webView)
        let failed = try await count(".ss-chip.ss-failed", in: webView)
        XCTAssertEqual(failed, 0)
        let rest = try await evaluate("document.querySelector('.ss-chip .ss-rest-meta').textContent", in: webView) as? String
        XCTAssertEqual(rest, "PDF \u{00b7} 240 KB")

        // Double click opens with the default app and the context menu is the app's (spec §5.17).
        _ = try await evaluate("""
            var chip = document.querySelector('.ss-chip');
            chip.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
            chip.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 40, clientY: 50 }));
            """, in: webView)
        for _ in 0..<20 where !handler.received.contains(where: { ($0["type"] as? String) == "attachmentMenu" }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(handler.received.contains { ($0["type"] as? String) == "openAttachmentWithApp" && ($0["attachmentID"] as? String) == "att-1" })
        let menu = handler.received.first { ($0["type"] as? String) == "attachmentMenu" }
        XCTAssertEqual(menu?["attachmentID"] as? String, "att-1")
        XCTAssertEqual((menu?["x"] as? NSNumber)?.doubleValue, 40)
    }

    /// The bottom inset pads the conversation by the quick reply's height + 12, the frame never moves (§8.4).
    func testBottomInsetPadsTheConversation() async throws {
        let (webView, _) = try await loadedShell()
        _ = try await evaluate("window.ss.setBottomInset(60)", in: webView)
        let padding = try await evaluate("getComputedStyle(document.getElementById('ss-root')).paddingBottom", in: webView) as? String
        XCTAssertEqual(padding, "72px")
    }

    /// A body that never arrived shows the snippet and the offline notice; a failed fetch offers Retry.
    func testMissingBodiesShowTheirState() async throws {
        let (webView, handler) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1", snippet: "Booked the flat")
        let payload = F.builder.build(messages: [message], bodies: [:], accounts: F.accounts, bodyStates: [message.id: .offline])
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let preview = try await evaluate("document.querySelector('.ss-preview').textContent", in: webView) as? String
        XCTAssertEqual(preview, "Booked the flat\u{2026}")
        let notice = try await evaluate("document.querySelector('.ss-frame .ss-banner').textContent", in: webView) as? String
        XCTAssertEqual(notice, "The full message will load when you\u{2019}re back online.")
        let patch = [RenderPayload.BodyStatePatch(id: payload.messages[0].id, bodyState: .failed)]
        let json = String(decoding: try JSONEncoder().encode(patch), as: UTF8.self)
        _ = try await evaluate("window.ss.bodyStates(\(json))", in: webView)
        let failed = try await count(".ss-banner.ss-bad", in: webView)
        XCTAssertEqual(failed, 1)
        _ = try await evaluate("document.querySelector('.ss-banner.ss-bad .ss-link').click()", in: webView)
        XCTAssertTrue(handler.received.contains { ($0["type"] as? String) == "retryBody" })
    }

    /// A draft open in a composer window reads “Open in a composer window” in place of its body (spec §5.19).
    func testADraftOpenInAComposerSaysSo() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let draft = F.message("d1", roles: [.drafts])
        let payload = F.builder.build(messages: [draft], bodies: [:], accounts: F.accounts, bodyStates: [draft.id: .inComposer])
        XCTAssertEqual(payload.messages[0].bodyState, .inComposer)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let line = try await evaluate("document.querySelector('.ss-incomposer').textContent", in: webView) as? String
        XCTAssertEqual(line, "Open in a composer window")
        let frames = try await count("iframe", in: webView)
        XCTAssertEqual(frames, 0, "no body is shown while the composer holds it")
    }

    /// A styled newsletter wider than its sheet is zoomed to fit, never below 0.74 (spec §5.14).
    func testWideHTMLIsZoomedToFit() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1")
        var body = F.body(html: "<table width=\"900\" style=\"width:900px\"><tr><td style=\"height:600px\">Wide</td></tr></table>")
        body.typesetting = .styled
        let payload = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFramedCards(in: webView)
        // The fit runs on the frame's load event, which can follow the first measurement.
        var value = 0.0
        for _ in 0..<40 {
            let zoom = try await evaluate("Number(document.querySelector('.ss-card iframe').contentDocument.body.style.zoom || 0)", in: webView) as? NSNumber
            value = zoom?.doubleValue ?? 0
            if value > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertLessThan(value, 1)
        XCTAssertGreaterThanOrEqual(value, 0.74)
        // The frame is as tall as the zoomed content: nothing clipped, no gap.
        _ = try await evaluate("window.ss.measureAll()", in: webView)
        let sizes = numbers(try await evaluate("""
            (function () { var f = document.querySelector('.ss-card iframe'); var d = f.contentDocument;
              return [f.clientHeight, d.body.getBoundingClientRect().height * \(value), d.documentElement.scrollHeight]; })()
            """, in: webView))
        XCTAssertEqual(sizes.count, 3)
        if sizes.count == 3 {
            XCTAssertGreaterThanOrEqual(sizes[0] + 1, sizes[2], "frame \(sizes[0]) vs document \(sizes[2])")
            XCTAssertLessThanOrEqual(sizes[0], sizes[2] + 2, "frame \(sizes[0]) vs document \(sizes[2])")
        }
    }

    /// Dark appearances adapt styled mail that declares colours and offer Original colors, which puts the body
    /// as sent on the white inset (spec §5.14, §5.16). Light appearances show it as sent with neither.
    func testDarkAdaptationAndOriginalColors() async throws {
        let (webView, handler) = try await loadedShell(dark: true)
        typealias F = ConversationFixtures
        let message = F.message("m1")
        var body = F.body(html: "<table bgcolor=\"#B91C1C\"><tr><td style=\"color:#ffffff\">Northwind</td></tr></table>")
        body.typesetting = .styled
        body.declaresColors = true
        let payload = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFramedCards(in: webView)
        var root = try await evaluate("document.querySelector('.ss-card iframe').contentDocument.documentElement.className", in: webView) as? String
        XCTAssertEqual(root, "ss-adapt", "adapted by default")
        let notice = try await evaluate("document.querySelector('.ss-banner.ss-warn .ss-btxt').textContent", in: webView) as? String
        XCTAssertEqual(notice, "This message uses its own colours.")
        let key = ConversationShellAssets.jsStringLiteral(payload.messages[0].id)
        _ = try await evaluate("window.ss.originalColors(\(key), true)", in: webView)
        try await waitForFramedCards(in: webView)
        root = try await evaluate("document.querySelector('.ss-card iframe').contentDocument.documentElement.className", in: webView) as? String
        XCTAssertEqual(root, "ss-original")
        let inset = try await count(".ss-original iframe", in: webView)
        XCTAssertEqual(inset, 1, "the body sits on the originalPage inset")
        let shown = try await evaluate("document.querySelector('.ss-banner.ss-warn .ss-btxt').textContent", in: webView) as? String
        XCTAssertEqual(shown, "Showing the sender\u{2019}s colours.")
        XCTAssertTrue(handler.received.contains { ($0["kind"] as? String) == "originalColors" && ($0["on"] as? Bool) == true })
        _ = try await evaluate("window.ss.preferences({readingSans: false, colorsNoticeDismissed: true})", in: webView)
        let notices = try await count(".ss-banner.ss-warn", in: webView)
        XCTAssertEqual(notices, 0, "dismissed everywhere")
        let action = try await count(".ss-hact.ss-qon", in: webView)
        XCTAssertEqual(action, 1, "the hover action stays one step away, on")
    }

    // MARK: Helpers

    /// Every card that has a frame has measured it.
    private func waitForFramedCards(in webView: WKWebView) async throws {
        var heights: [Double] = []
        for _ in 0..<100 {
            heights = numbers(try await evaluate("window.ss.measureAll(); window.ss.iframeHeights()", in: webView)).filter { $0 >= 0 }
            if !heights.isEmpty, heights.allSatisfy({ $0 > 0 }) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("frames never measured: \(heights)")
    }

    /// The invitation card (spec §5.14, `layout.invitation`): at the body indent inside the measure, above the body;
    /// small answer buttons with the chosen one marked; a click posts the answer and marks it at once; cancelled and
    /// waiting-for-permission states; and a patch that changes only the card.
    func testTheInvitationCardSitsAboveTheBodyAndShowsItsStates() async throws {
        typealias F = ConversationFixtures
        let (webView, handler) = try await loadedShell()
        var message = F.message("m1", date: F.utc(2025, 3, 7, 14, 5))
        var body = F.body(html: "<p>Ben has invited you.</p>")
        // Teams links run to hundreds of characters.
        let teams = "https://teams.microsoft.com/l/meetup-join/" + String(repeating: "19%3ameeting_NjE2ZDk", count: 16)
        body.invitation = CalendarInvitation(
            method: .request, uid: "uid-1", title: "Design review", start: F.utc(2025, 3, 11, 15), end: F.utc(2025, 3, 11, 16),
            location: "https://meet.example.com/abc", conferenceURL: teams,
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@example.com"),
            attendees: [CalendarInvitation.Person(address: "me@example.com", response: .needsAction)], repeats: "Every week on Tuesday",
            userAddress: "me@example.com", userResponse: .needsAction, calendarText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
        func payload(reply: InvitationResponse?, waiting: Bool = false, cancelled: Bool = false) throws -> String {
            message.invitationReply = reply
            var stored = body
            if cancelled { stored.invitation?.method = .cancel }
            return try F.builder.build(messages: [message], bodies: [message.id: stored], accounts: F.accounts,
                                       invitationPermissionNeeded: waiting ? [F.accountID] : [], now: F.utc(2025, 3, 7, 15)).jsonString()
        }
        _ = try await evaluate("window.ss.render(\(try payload(reply: nil)))", in: webView)
        try await waitForFrames(count: 1, in: webView)

        let geometryScript = """
            (function () {
              var card = document.querySelector('.ss-invite'), head = document.querySelector('.ss-head');
              var mark = document.querySelector('.ss-mrow .ss-elide'), button = document.querySelector('.ss-ans');
              var body = document.querySelector('.ss-body');
              var c = card.getBoundingClientRect(), h = head.getBoundingClientRect(), k = mark.getBoundingClientRect();
              var b = body.getBoundingClientRect();
              return [c.left - h.left, c.width, c.top - h.bottom, k.top - c.bottom, button.getBoundingClientRect().height,
                      k.left - h.left, k.height, b.height, b.top - k.bottom];
            })()
            """
        let geometry = numbers(try await evaluate(geometryScript, in: webView))
        XCTAssertEqual(geometry.count, 9)
        XCTAssertEqual(geometry[0], 48, accuracy: 0.5, "at the body indent")
        XCTAssertLessThanOrEqual(geometry[1], 576.5, "inside the measure")
        XCTAssertEqual(geometry[2], 18, accuracy: 0.5, "where the body would start")
        XCTAssertEqual(geometry[3], 16, accuracy: 0.5, "the message's elision mark 16 below it, where the body would start")
        XCTAssertEqual(geometry[4], 22, accuracy: 0.5, "small buttons")
        XCTAssertEqual(geometry[5], 48, accuracy: 0.5, "the mark at the indent")
        XCTAssertEqual(geometry[6], 24, accuracy: 0.5)
        XCTAssertEqual(geometry[7], 0, accuracy: 0.5, "the body folded under it")
        _ = try await evaluate("document.querySelector('.ss-mrow .ss-elide').click()", in: webView)
        let unfolded = numbers(try await evaluate(geometryScript, in: webView))
        XCTAssertEqual(unfolded.count, 9)
        XCTAssertEqual(unfolded[3], 16, accuracy: 0.5, "the mark stays put")
        XCTAssertGreaterThan(unfolded[7], 0, "the body unfolds")
        XCTAssertEqual(unfolded[8], 12, accuracy: 0.5, "12 below the mark")
        let answers = try await count(".ss-invite .ss-ans", in: webView)
        XCTAssertEqual(answers, 3)
        let links = try await count(".ss-invite .ss-ilink", in: webView)
        XCTAssertEqual(links, 2, "a web address is a link: the location and the meeting link")
        let teamsLink = numbers(try await evaluate("""
            (function () {
              var link = document.querySelectorAll('.ss-invite .ss-ilink')[1];
              return [link.getBoundingClientRect().height, link.scrollWidth - link.clientWidth, link.title.length];
            })()
            """, in: webView))
        XCTAssertEqual(teamsLink.count, 3)
        XCTAssertLessThanOrEqual(teamsLink[0], 17, "a long link keeps to one line")
        XCTAssertGreaterThan(teamsLink[1], 0, "cut with an ellipsis")
        XCTAssertEqual(teamsLink[2], Double(teams.count), "the whole address is its tooltip")
        let when = try await evaluate("document.querySelector('.ss-invite .ss-iwhen').textContent", in: webView) as? String
        XCTAssertEqual(when, "Tue 11 Mar · 15:00 – 16:00")

        _ = try await evaluate("document.querySelector('.ss-ans[data-response=\"declined\"]').click()", in: webView)
        let chosen = try await evaluate("document.querySelector('.ss-ans.ss-chosen').dataset.response", in: webView) as? String
        XCTAssertEqual(chosen, "declined", "marked at once, before the store answers")
        let posted = handler.received.last { ($0["type"] as? String) == "answerInvitation" }
        XCTAssertEqual(posted?["value"] as? String, "declined")
        XCTAssertEqual(posted?["messageID"] as? String, RenderPayload.messageKey(for: message.id))

        _ = try await evaluate("window.ss.update(\(try payload(reply: .declined, waiting: true)))", in: webView)
        let notices = try await count(".ss-invite .ss-banner.ss-info", in: webView)
        XCTAssertEqual(notices, 1, "the card asks for permission")
        let stillChosen = try await evaluate("document.querySelector('.ss-ans.ss-chosen').dataset.response", in: webView) as? String
        XCTAssertEqual(stillChosen, "declined")

        _ = try await evaluate("window.ss.update(\(try payload(reply: .declined, cancelled: true)))", in: webView)
        let cancelledCards = try await count(".ss-invite.ss-cancelled", in: webView)
        XCTAssertEqual(cancelledCards, 1)
        let answersOnCancelled = try await count(".ss-invite .ss-ans", in: webView)
        XCTAssertEqual(answersOnCancelled, 0, "nothing to answer")
        let openLinks = try await count(".ss-invite .ss-iopen", in: webView)
        XCTAssertEqual(openLinks, 1)
        let decoration = try await evaluate("getComputedStyle(document.querySelector('.ss-ititle')).textDecorationLine", in: webView) as? String
        XCTAssertEqual(decoration, "line-through", "the title is struck through, not only greyed")
    }

    /// One sheet can carry both: an invitation sent through a mailing list shows the Unsubscribe link beside its sender
    /// and the card above its body, each posting its own action; an update that changes the one leaves the other.
    func testTheUnsubscribeLinkAndTheInvitationCardShareASheet() async throws {
        typealias F = ConversationFixtures
        let (webView, handler) = try await loadedShell()
        var message = F.message("m1", date: F.utc(2025, 3, 7, 14, 5))
        message.listUnsubscribe = "<https://club.example.com/u/1>"
        var body = F.body(html: "<p>Club night is on.</p>")
        body.invitation = CalendarInvitation(
            method: .request, uid: "uid-club", title: "Club night", start: F.utc(2025, 3, 11, 19), end: F.utc(2025, 3, 11, 21),
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@example.com"),
            attendees: [CalendarInvitation.Person(address: "me@example.com", response: .needsAction)],
            userAddress: "me@example.com", userResponse: .needsAction, calendarText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
        func payload(listed: Bool, invited: Bool) throws -> RenderPayload {
            var shown = message
            if !listed { shown.listUnsubscribe = nil }
            var stored = body
            if !invited { stored.invitation = nil }
            return F.builder.build(messages: [shown], bodies: [shown.id: stored], accounts: F.accounts, now: F.utc(2025, 3, 7, 15))
        }
        let both = try payload(listed: true, invited: true)
        _ = try await evaluate("window.ss.render(\(try both.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)

        let links = try await count(".ss-head .ss-unsub", in: webView)
        XCTAssertEqual(links, 1, "the link beside the sender")
        let cards = try await count(".ss-invite:not([hidden])", in: webView)
        XCTAssertEqual(cards, 1, "the card above the body")
        let order = try await evaluate("""
            (function () { var c = document.querySelector('.ss-card'); var u = c.querySelector('.ss-unsub'), i = c.querySelector('.ss-invite');
              var b = c.querySelector('.ss-body');
              return [u.compareDocumentPosition(i) & Node.DOCUMENT_POSITION_FOLLOWING ? 1 : 0,
                      i.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? 1 : 0].join(','); })()
            """, in: webView) as? String
        XCTAssertEqual(order, "1,1", "the header's link, then the card, then the body")

        _ = try await evaluate("document.querySelector('.ss-ans[data-response=\"accepted\"]').click()", in: webView)
        _ = try await evaluate("document.querySelector('.ss-unsub').click()", in: webView)
        var types: [String] = []
        for _ in 0..<50 {
            types = handler.received.compactMap { ($0["kind"] as? String) == "action" ? $0["type"] as? String : nil }
            if types.contains("unsubscribe"), types.contains("answerInvitation") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(types.filter { $0 == "answerInvitation" }.count, 1, "the answer posts once: \(types)")
        XCTAssertEqual(types.filter { $0 == "unsubscribe" }.count, 1, "and the link its own action: \(types)")

        _ = try await evaluate("window.ss.update(\(try payload(listed: true, invited: false).jsonString()))", in: webView)
        let linksWithoutCard = try await count(".ss-head .ss-unsub", in: webView)
        XCTAssertEqual(linksWithoutCard, 1, "the card going leaves the link")
        let hidden = try await evaluate("document.querySelector('.ss-invite').hidden", in: webView) as? Bool
        XCTAssertEqual(hidden, true)

        _ = try await evaluate("window.ss.update(\(try payload(listed: false, invited: true).jsonString()))", in: webView)
        let linksGone = try await count(".ss-head .ss-unsub", in: webView)
        XCTAssertEqual(linksGone, 0, "the headers going take the link")
        let cardBack = try await count(".ss-invite:not([hidden]) .ss-ans", in: webView)
        XCTAssertEqual(cardBack, 3, "and leave the card answerable")
    }

    /// Every state of the card folds its message (spec §5.14): to answer, answered, waiting for permission, the user's own
    /// event, an earlier revision a later message updates, cancelled. A message without a card in the same
    /// conversation shows its body as before. Nothing reads the HTML: the fold follows the payload's card.
    func testEveryCardStateFoldsItsMessage() async throws {
        typealias F = ConversationFixtures
        let (webView, _) = try await loadedShell()
        func invitation(_ uid: String, sequence: Int = 0, method: CalendarInvitation.Method = .request,
                        own: Bool = false) -> CalendarInvitation {
            CalendarInvitation(
                method: method, uid: uid, sequence: sequence, title: "Design review", start: F.utc(2025, 3, 11, 15), end: F.utc(2025, 3, 11, 16),
                organizer: CalendarInvitation.Person(name: own ? "Me" : "Ben Carter", address: own ? F.account.email : "ben@example.com"),
                attendees: [CalendarInvitation.Person(address: "me@example.com", response: .needsAction)],
                userAddress: "me@example.com", userResponse: .needsAction, userIsOrganizer: own,
                calendarText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
        }
        // Oldest first: open, answered and waiting, own event, the earlier revision, its update, cancelled, no card.
        var messages = (0..<7).map { F.message("m\($0)", date: F.utc(2025, 3, 1 + $0, 9, 0), isRead: false) }
        messages[1].invitationReply = .accepted
        var bodies: [MessageID: StoredBody] = [:]
        let cards: [CalendarInvitation?] = [
            invitation("open"), invitation("answered"), invitation("own", own: true),
            invitation("revised", sequence: 0), invitation("revised", sequence: 1), invitation("gone", method: .cancel), nil,
        ]
        for (message, card) in zip(messages, cards) {
            var body = F.body(html: "<p>Body of \(message.id.providerID)</p>")
            body.invitation = card
            bodies[message.id] = body
        }
        let payload = F.builder.build(messages: messages, bodies: bodies, accounts: F.accounts,
                                      invitationPermissionNeeded: [F.accountID], now: F.utc(2025, 3, 8, 9))
        XCTAssertEqual(payload.messages[1].invitation?.needsPermission, true, "the answered card waits for permission")
        XCTAssertEqual(payload.messages[2].invitation?.organizer, "You", "the user's own event")
        XCTAssertEqual(payload.messages[3].invitation?.canAnswer, false, "the earlier revision is updated")
        XCTAssertEqual(payload.messages[5].invitation?.isCancelled, true)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString())); window.ss.expandAll()", in: webView)
        try await waitForFrames(count: 7, in: webView)
        let folded = try await evaluate("""
            JSON.stringify(Array.from(document.querySelectorAll('.ss-card')).map(function (c) {
              return [c.classList.contains('ss-mfolded'), getComputedStyle(c.querySelector('.ss-mrow')).display !== 'none',
                      c.querySelector('.ss-body').getBoundingClientRect().height > 0];
            }))
            """, in: webView) as? String
        XCTAssertEqual(folded, "[[true,true,false],[true,true,false],[true,true,false],[true,true,false],[true,true,false],"
                       + "[true,true,false],[false,false,true]]")
    }

    /// The fold moves like the quoted-text toggle (spec §4.10): unfolding animates the sheet's height, and the app hears
    /// that something moves; under Reduce Motion the sheet takes its new height at once, and nothing is said to move.
    func testTheFoldMovesLikeQuotedText() async throws {
        typealias F = ConversationFixtures
        let (webView, handler) = try await loadedShell()
        let message = F.message("m1")
        var body = F.body(html: "<p>Ben has invited you.</p>" + String(repeating: "<p>Line</p>", count: 20))
        body.invitation = CalendarInvitation(
            method: .request, uid: "uid-1", title: "Design review", start: F.utc(2025, 3, 11, 15), end: F.utc(2025, 3, 11, 16),
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@example.com"),
            attendees: [CalendarInvitation.Person(address: "me@example.com", response: .needsAction)],
            userAddress: "me@example.com", userResponse: .needsAction, calendarText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
        let payload = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts)
        let heights = """
            (function () { var c = document.querySelector('.ss-card');
              return [parseFloat(c.style.height), Math.ceil(c.querySelector('.ss-inner').getBoundingClientRect().height),
                      c.getBoundingClientRect().height]; })()
            """
        func motions() -> Int { handler.received.filter { ($0["kind"] as? String) == "motion" }.count }

        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = motions()
        _ = try await evaluate("document.querySelector('.ss-mrow .ss-elide').click()", in: webView)
        let animating = numbers(try await evaluate(heights, in: webView))
        XCTAssertEqual(animating.count, 3)
        XCTAssertEqual(animating[0], animating[1], accuracy: 0.5, "the sheet heads straight for the unfolded height")
        XCTAssertLessThan(animating[2], animating[0] - 1, "and gets there by animating")
        XCTAssertGreaterThan(motions(), before, "the app hears that something moves")

        _ = try await evaluate("window.ss.setModes({rm: true})", in: webView)
        try await Task.sleep(nanoseconds: 300_000_000)
        let still = motions()
        _ = try await evaluate("document.querySelector('.ss-mrow .ss-elide').click()", in: webView)
        let reduced = numbers(try await evaluate(heights, in: webView))
        XCTAssertEqual(reduced.count, 3)
        XCTAssertEqual(reduced[0], reduced[1], accuracy: 0.5)
        XCTAssertEqual(reduced[2], reduced[0], accuracy: 0.5, "Reduce Motion: folded at once")
        XCTAssertEqual(motions(), still, "nothing moves")
    }

    /// Original colors work on a folded message (spec §5.16): its notice stays in view over the folded body, as over folded
    /// quoted text, and says when the switch is made; the body is rebuilt on the inset out of sight and shows so once
    /// unfolded.
    func testOriginalColorsWorkUnderTheFold() async throws {
        typealias F = ConversationFixtures
        let (webView, _) = try await loadedShell(dark: true)
        let message = F.message("m1")
        var body = F.body(html: "<table bgcolor=\"#B91C1C\"><tr><td style=\"color:#ffffff\">Join with Meet</td></tr></table>")
        body.typesetting = .styled
        body.declaresColors = true
        body.invitation = CalendarInvitation(
            method: .request, uid: "uid-1", title: "Design review", start: F.utc(2025, 3, 11, 15), end: F.utc(2025, 3, 11, 16),
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@example.com"),
            attendees: [CalendarInvitation.Person(address: "me@example.com", response: .needsAction)],
            userAddress: "me@example.com", userResponse: .needsAction, calendarText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
        let payload = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFramedCards(in: webView)
        let notice = "(function () { var b = document.querySelector('.ss-banners .ss-banner.ss-warn');"
            + " return b.querySelector('.ss-btxt').textContent + ' | ' + getComputedStyle(b).visibility; })()"
        let before = try await evaluate(notice, in: webView) as? String
        XCTAssertEqual(before, "This message uses its own colours. | visible", "the notice stays in view, as over folded quoted text")
        let state = try await evaluate("JSON.stringify(window.ss.targetState())", in: webView) as? String
        XCTAssertTrue(state?.contains("\"offersOriginal\":true") == true, "the hover action, More and ⇧⌘O still offer it: \(state ?? "")")
        let on = try await evaluate("window.ss.toggleOriginal()", in: webView) as? Bool
        XCTAssertEqual(on, true)
        try await waitForFramedCards(in: webView)
        let after = try await evaluate(notice, in: webView) as? String
        XCTAssertEqual(after, "Showing the sender\u{2019}s colours. | visible", "the switch shows where it can be seen")
        let inset = try await count(".ss-original iframe", in: webView)
        XCTAssertEqual(inset, 1, "rebuilt on the inset under the fold")
        let stillFolded = try await evaluate("document.querySelector('.ss-card').classList.contains('ss-mfolded')", in: webView) as? Bool
        XCTAssertEqual(stillFolded, true, "and left folded, as quoted text is")
        _ = try await evaluate("document.querySelector('.ss-mrow .ss-elide').click()", in: webView)
        let shown = numbers(try await evaluate("[document.querySelector('.ss-original').getBoundingClientRect().height]", in: webView))
        XCTAssertGreaterThan(shown.first ?? 0, 24, "the inset shows once unfolded")
    }

    /// The shell in a web view, once it has signalled ready. Skips unless `SS_UI_TESTS=1`.
    private func loadedShell(dark: Bool = false, width: CGFloat = 800) async throws -> (WKWebView, ShellMessages) {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("Set SS_UI_TESTS=1 to drive WebKit")
        }
        let handler = ShellMessages()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ShellSchemeStub(), forURLScheme: ConversationShellAssets.scheme)
        configuration.setURLSchemeHandler(remote, forURLScheme: RemoteSchemeRecorder.scheme)
        configuration.userContentController.add(handler, name: ConversationShellAssets.readyHandlerName)
        configuration.userContentController.add(handler, name: ConversationShellAssets.messageHandlerName)
        self.configuration = configuration

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 600), configuration: configuration)
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        webView.navigationDelegate = handler
        webView.loadHTMLString(ConversationShellAssets.html, baseURL: ConversationShellAssets.baseURL)
        // Sleeping on the main actor keeps the run loop turning, which is what delivers WebKit's callbacks.
        var attempts = 0
        while !handler.isReady, attempts < 200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        guard handler.isReady else {
            XCTFail("shell never signalled ready; WebKit reported: \(handler.failures)")
            throw XCTSkip("no shell")
        }
        return (webView, handler)
    }

    /// Frames size themselves after their documents load; the page cannot scroll until they have.
    private func waitForFrames(count: Int, in webView: WKWebView) async throws {
        var heights: [Double] = []
        for _ in 0..<100 {
            heights = numbers(try await evaluate("window.ss.measureAll()", in: webView))
            if heights.count == count, heights.allSatisfy({ $0 > 0 }) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("frames never measured: \(heights)")
    }

    private func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func count(_ selector: String, in webView: WKWebView) async throws -> Int? {
        int(try await evaluate("document.querySelectorAll(\(ConversationShellAssets.jsStringLiteral(selector))).length", in: webView))
    }

    private func twoMessagePayload() -> RenderPayload {
        typealias F = ConversationFixtures
        let first = F.message("m1", date: F.utc(2025, 1, 3, 14, 5))
        let second = F.message("m2", from: F.bob, date: F.utc(2025, 3, 7, 14, 5), isRead: false)
        let bodies: [MessageID: StoredBody] = [
            first.id: F.body(html: "<p>Hello <b>world</b></p><div class=\"ss-quote\"><p>Earlier</p></div>"),
            second.id: F.body(html: "<p>Reply</p><img data-ss-src=\"https://example.com/a.png\" alt=\"\">"),
        ]
        return F.builder.build(messages: [first, second], bodies: bodies, accounts: F.accounts, now: F.utc(2025, 3, 7, 15, 0))
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
