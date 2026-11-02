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
        _ = try await evaluate("window.ss.loadImages(\(key))", in: webView)
        for _ in 0..<50 where remote.paths.count < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(Set(remote.paths), ["/live.png", "/parked.png"])
        let buttons = try await count(".ss-load-images", in: webView)
        XCTAssertEqual(buttons, 0)
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

    /// A styled newsletter wider than its sheet is zoomed to fit, never below 0.74 (spec §5.14).
    func testWideHTMLIsZoomedToFit() async throws {
        let (webView, _) = try await loadedShell()
        typealias F = ConversationFixtures
        let message = F.message("m1")
        var body = F.body(html: "<table width=\"900\" style=\"width:900px\"><tr><td>Wide</td></tr></table>")
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

    /// The shell in a web view, once it has signalled ready. Skips unless `SS_UI_TESTS=1`.
    private func loadedShell() async throws -> (WKWebView, ShellMessages) {
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

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
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
