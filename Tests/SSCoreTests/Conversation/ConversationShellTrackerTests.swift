import WebKit
import XCTest
@testable import SSCore

/// Block trackers in the real shell (spec §5.60): while it is on, Load images and the preference leave marked trackers
/// parked, the images banner leaves them out of its count, and the card says how many were blocked; while it is off they
/// load like any image and nothing is said. A change reaches a shown conversation in place. A scheme of the test's own
/// stands in for the network. Gated behind `SS_UI_TESTS=1`, as `ConversationShellWebViewTests` is.
@MainActor
final class ConversationShellTrackerTests: XCTestCase {
    @MainActor
    private final class Ready: NSObject, WKScriptMessageHandler {
        private(set) var isReady = false
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == ConversationShellAssets.readyHandlerName { isReady = true }
        }
    }

    /// WebKit stalls a `loadHTMLString` whose base scheme has no handler, so the test registers one as the app does.
    @MainActor
    private final class ShellStub: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])
            else { return }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    /// Stands in for the network: counts what bodies fetch, answering with a one-pixel image.
    @MainActor
    private final class Remote: NSObject, WKURLSchemeHandler {
        static let scheme = "ss-remote"
        private(set) var paths: [String] = []

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
            else { return }
            paths.append(url.path)
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/gif", expectedContentLength: gif.count, textEncodingName: nil))
            urlSchemeTask.didReceive(gif)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    private typealias F = ConversationFixtures
    private let remote = Remote()
    private var configuration: WKWebViewConfiguration?

    override func tearDown() {
        configuration?.userContentController.removeAllScriptMessageHandlers()
        configuration = nil
        super.tearDown()
    }

    /// A body as the sanitizer stores it: a picture parked, and two trackers parked and marked.
    private func payload(trackers: Bool = true, picture: Bool = true, loadRemoteImages: Bool, blocksTrackers: Bool) -> RenderPayload {
        let parked = { (path: String, mark: String?) in
            "<img src=\"\(HTMLSanitizer.placeholderImage)\" data-ss-src=\"ss-remote://cdn\(path)\""
                + (mark.map { " \(HTMLSanitizer.trackerAttribute)=\"\($0)\"" } ?? "") + " width=\"20\" height=\"20\" alt=\"\">"
        }
        var html = "<div class=\"ss-body\"><p>Fall gear</p>"
        if picture { html += parked("/hero.gif", nil) }
        if trackers { html += parked("/open.gif", "tiny") + parked("/known.gif", "known") }
        html += "</div>"
        let message = F.message("m1")
        var body = F.body(html: html)
        body.blockedRemoteImageCount = (picture ? 1 : 0) + (trackers ? 2 : 0)
        body.trackerImageCount = trackers ? 2 : 0
        return F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts, loadRemoteImages: loadRemoteImages,
                               blocksTrackers: blocksTrackers)
    }

    func testTrackersStayParkedWhenImagesLoadWhileBlocking() async throws {
        let webView = try await loadedShell()
        try await render(payload(loadRemoteImages: true, blocksTrackers: true), in: webView)
        try await waitForPaths(1)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(remote.paths, ["/hero.gif"], "the picture loads; the trackers never do")
        let value1 = try await text(".ss-trackers .ss-btxt", in: webView)
        XCTAssertEqual(value1, "2 trackers blocked")
        let value2 = try await count(".ss-load-images", in: webView)
        XCTAssertEqual(value2, 0)
        let value3 = try await frameCount("img[data-ss-tracker][data-ss-src]", in: webView)
        XCTAssertEqual(value3, 2, "still parked in the frame")
        let states = try await evaluate("JSON.stringify(window.ss.cardStates()[0])", in: webView) as? String ?? ""
        XCTAssertTrue(states.contains("\"trackers\":2"), states)
    }

    func testTrackersLoadLikeAnyImageWithBlockingOff() async throws {
        let webView = try await loadedShell()
        try await render(payload(loadRemoteImages: true, blocksTrackers: false), in: webView)
        try await waitForPaths(3)
        XCTAssertEqual(Set(remote.paths), ["/hero.gif", "/open.gif", "/known.gif"])
        let value4 = try await count(".ss-trackers", in: webView)
        XCTAssertEqual(value4, 0, "nothing is said while blocking is off")
    }

    /// With images held back the banner counts only what Load images would bring in, and the note shows beside it, since
    /// the sender meant to track either way; Load images then leaves the trackers parked.
    func testTheBannerLeavesTrackersOutAndLoadImagesHoldsThemBack() async throws {
        let webView = try await loadedShell()
        let built = payload(loadRemoteImages: false, blocksTrackers: true)
        try await render(built, in: webView)
        let value5 = try await text(".ss-banner .ss-wide", in: webView)
        XCTAssertEqual(value5, "1 remote image hidden to protect your privacy.")
        let value6 = try await text(".ss-trackers .ss-btxt", in: webView)
        XCTAssertEqual(value6, "2 trackers blocked")
        let target = try await evaluate("JSON.stringify(window.ss.targetState())", in: webView) as? String ?? ""
        XCTAssertTrue(target.contains("\"imagesBlocked\":true"), target)
        XCTAssertEqual(remote.paths, [])

        let key = ConversationShellAssets.jsStringLiteral(built.messages[0].id)
        let loading = try await evaluate("window.ss.loadImages(\(key)); document.querySelector('.ss-banner .ss-btxt').textContent",
                                         in: webView) as? String
        XCTAssertEqual(loading, "Loading 1 image\u{2026}", "the trackers are not waited for")
        try await waitForPaths(1)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(remote.paths, ["/hero.gif"])
        let value7 = try await text(".ss-trackers .ss-btxt", in: webView)
        XCTAssertEqual(value7, "2 trackers blocked", "still said once images load")
    }

    /// A message whose only remote images are trackers offers nothing to load while blocking is on.
    func testOnlyTrackersOfferNoLoadImages() async throws {
        let webView = try await loadedShell()
        try await render(payload(picture: false, loadRemoteImages: false, blocksTrackers: true), in: webView)
        let value8 = try await count(".ss-load-images", in: webView)
        XCTAssertEqual(value8, 0)
        let value9 = try await text(".ss-trackers .ss-btxt", in: webView)
        XCTAssertEqual(value9, "2 trackers blocked")
        let target = try await evaluate("JSON.stringify(window.ss.targetState())", in: webView) as? String ?? ""
        XCTAssertTrue(target.contains("\"imagesBlocked\":false"), "View › Load Images has nothing to do: \(target)")

        try await render(payload(picture: false, loadRemoteImages: false, blocksTrackers: false), in: webView)
        let value10 = try await text(".ss-banner .ss-wide", in: webView)
        XCTAssertEqual(value10, "2 remote images hidden to protect your privacy.")
        let value11 = try await count(".ss-trackers", in: webView)
        XCTAssertEqual(value11, 0)
    }

    /// Turning blocking on or off reaches the conversation on screen in place (`ss.preferences`, as the reader broadcasts
    /// it): the note comes and goes, and a frame showing its images is built again, its trackers held back or put back.
    func testAChangeReachesTheShownConversationInPlace() async throws {
        let webView = try await loadedShell()
        try await render(payload(loadRemoteImages: true, blocksTrackers: false), in: webView)
        try await waitForPaths(3)
        let cards = try await count(".ss-card", in: webView)

        _ = try await evaluate("window.ss.preferences({readingSans: false, textSize: 'default', colorsNoticeDismissed: false, "
                               + "adaptsColours: true, blocksTrackers: true})", in: webView)
        let value12 = try await text(".ss-trackers .ss-btxt", in: webView)
        XCTAssertEqual(value12, "2 trackers blocked")
        try await waitForFrame(in: webView)
        let value13 = try await frameCount("img[data-ss-tracker][data-ss-src]", in: webView)
        XCTAssertEqual(value13, 2, "the rebuilt frame holds them back")
        let value14 = try await count(".ss-card", in: webView)
        XCTAssertEqual(value14, cards, "the same cards, not a new render")

        _ = try await evaluate("window.ss.preferences({readingSans: false, textSize: 'default', colorsNoticeDismissed: false, "
                               + "adaptsColours: true, blocksTrackers: false})", in: webView)
        let value15 = try await count(".ss-trackers", in: webView)
        XCTAssertEqual(value15, 0)
        // WebKit answers the second asking of each source from its memory cache, so the frame is read rather than the
        // network: every source is put back.
        var restored: Int?
        for _ in 0..<60 {
            restored = try await frameCount("img[data-ss-tracker][src^='ss-remote:']", in: webView)
            if restored == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(restored, 2, "the rebuilt frame puts the trackers back")
        let parked = try await frameCount("img[data-ss-src]", in: webView)
        XCTAssertEqual(parked, 0)
    }

    // MARK: Support

    private func loadedShell() async throws -> WKWebView {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else { throw XCTSkip("Set SS_UI_TESTS=1 to drive WebKit") }
        let ready = Ready()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ShellStub(), forURLScheme: ConversationShellAssets.scheme)
        configuration.setURLSchemeHandler(remote, forURLScheme: Remote.scheme)
        configuration.userContentController.add(ready, name: ConversationShellAssets.readyHandlerName)
        self.configuration = configuration
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString(ConversationShellAssets.html, baseURL: ConversationShellAssets.baseURL)
        for _ in 0..<200 where !ready.isReady { try await Task.sleep(nanoseconds: 100_000_000) }
        guard ready.isReady else {
            XCTFail("shell never signalled ready")
            throw XCTSkip("no shell")
        }
        return webView
    }

    private func render(_ payload: RenderPayload, in webView: WKWebView) async throws {
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrame(in: webView)
    }

    /// The card's frame has loaded its document and been measured.
    private func waitForFrame(in webView: WKWebView) async throws {
        for _ in 0..<100 {
            let loaded = try await evaluate("""
                (function () { var f = document.querySelector('.ss-card iframe'); var d = f && f.contentDocument;
                return !!(d && d.body && d.URL === 'about:srcdoc' && d.body.childElementCount > 0); })()
                """, in: webView) as? Bool
            if loaded == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the frame never loaded")
    }

    private func waitForPaths(_ count: Int) async throws {
        for _ in 0..<60 where remote.paths.count < count { try await Task.sleep(nanoseconds: 100_000_000) }
    }

    private func text(_ selector: String, in webView: WKWebView) async throws -> String? {
        try await evaluate("(document.querySelector(\(ConversationShellAssets.jsStringLiteral(selector))) || {}).textContent", in: webView)
            as? String
    }

    private func count(_ selector: String, in webView: WKWebView) async throws -> Int? {
        (try await evaluate("document.querySelectorAll(\(ConversationShellAssets.jsStringLiteral(selector))).length", in: webView)
            as? NSNumber)?.intValue
    }

    private func frameCount(_ selector: String, in webView: WKWebView) async throws -> Int? {
        (try await evaluate("""
            (function () { var f = document.querySelector('.ss-card iframe'); var d = f && f.contentDocument;
            return d ? d.querySelectorAll(\(ConversationShellAssets.jsStringLiteral(selector))).length : -1; })()
            """, in: webView) as? NSNumber)?.intValue
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: result) }
            }
        }
    }
}
