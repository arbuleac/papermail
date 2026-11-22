import AppKit
@testable import SSCore
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Block trackers' network layer in WebKit (spec §5.60): the rules compile as a content blocker, the compiled list stops a
/// known pixel at the moment WebKit would fetch it and lets content through, it takes effect and goes in a page already
/// loaded when it is added to or removed from the user content controller, and a pool shares it among its views and
/// follows the setting. A scheme of the test's own stands in for the network (rules compiled for it), and each test
/// compiles into a store of its own, so the app's store is never touched. Gated behind `SS_UI_TESTS=1`, as every WebKit
/// render is.
@MainActor
final class TrackerContentRulesTests: XCTestCase {
    /// Counts what a page fetches, answering each request with a one-pixel image.
    @MainActor
    private final class RemoteRecorder: NSObject, WKURLSchemeHandler {
        static let scheme = "ss-remote"
        private(set) var paths: [String] = []

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
            else { return }
            paths.append((url.host ?? "") + url.path)
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/gif", expectedContentLength: gif.count, textEncodingName: nil))
            urlSchemeTask.didReceive(gif)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    private var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1", "WebKit runs with SS_UI_TESTS=1")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TrackerContentRules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func rules(scheme: String) throws -> TrackerContentRules {
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder.appendingPathComponent(UUID().uuidString, isDirectory: true)))
        return TrackerContentRules(store: store, scheme: scheme)
    }

    private func compiled(_ rules: TrackerContentRules) -> WKContentRuleList? {
        var result: WKContentRuleList??
        rules.list { result = .some($0) }
        XCTAssertTrue(ListTestSupport.spin(until: { result != nil }, timeout: 20), "WebKit answered")
        return result ?? nil
    }

    /// The app's own rules, for http and https, compile: every expression is in WebKit's subset.
    func testTheAppsRulesCompile() throws {
        let rules = try rules(scheme: "https?")
        let list = compiled(rules)
        XCTAssertNotNil(list, "the rules compile")
        XCTAssertEqual(list?.identifier, TrackerRules.contentRuleListIdentifier())
        XCTAssertTrue(rules.current === list, "kept for every later asker")
        var again: WKContentRuleList?
        rules.list { again = $0 }
        XCTAssertTrue(again === list, "answered at once, not compiled twice")
    }

    /// A second instance over the same store finds the compilation WebKit kept, as a later launch does.
    func testALaterLaunchFindsTheCompilation() throws {
        let url = folder.appendingPathComponent("shared", isDirectory: true)
        let first = TrackerContentRules(store: try XCTUnwrap(WKContentRuleListStore(url: url)), scheme: "https?")
        XCTAssertNotNil(compiled(first))
        let second = TrackerContentRules(store: try XCTUnwrap(WKContentRuleListStore(url: url)), scheme: "https?")
        XCTAssertNotNil(compiled(second))
    }

    /// The compiled list stops known pixels and lets content load; added to a loaded page's controller it holds from the
    /// next fetch, and removed it stops holding.
    func testTheListBlocksKnownPixelsLiveAndGoesWhenRemoved() throws {
        let list = try XCTUnwrap(compiled(try rules(scheme: RemoteRecorder.scheme)))
        let recorder = RemoteRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(recorder, forURLScheme: RemoteRecorder.scheme)
        configuration.userContentController.add(list)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.loadHTMLString("<p>Page</p>", baseURL: nil)
        XCTAssertTrue(ListTestSupport.spin(until: { !webView.isLoading }, timeout: 10))

        func load(_ sources: [String]) {
            let tags = sources.map { "<img src=\\\"ss-remote://\($0)\\\">" }.joined()
            var done = false
            // In a sandboxed srcdoc frame, as the reader puts every body.
            webView.evaluateJavaScript("""
                (function () { var f = document.createElement('iframe'); f.setAttribute('sandbox', 'allow-same-origin');
                f.srcdoc = "\(tags)"; document.body.appendChild(f); return true; })()
                """) { _, _ in done = true }
            ListTestSupport.spin(until: { done }, timeout: 5)
            ListTestSupport.spin(for: 1.0)
        }

        load(["cdn.example/hero.gif", "us21.list-manage.com/track/open.php?u=1", "url9.shop.example/wf/open?upn=abc"])
        XCTAssertEqual(recorder.paths, ["cdn.example/hero.gif"], "known pixels never reach the network; content does")

        configuration.userContentController.remove(list)
        load(["us21.list-manage.com/track/open.php?u=2"])
        XCTAssertEqual(recorder.paths.last, "us21.list-manage.com/track/open.php", "removed live: the page fetches it again")

        configuration.userContentController.add(list)
        let before = recorder.paths.count
        load(["us21.list-manage.com/track/open.php?u=3", "cdn.example/tile.gif"])
        XCTAssertEqual(Array(recorder.paths.dropFirst(before)), ["cdn.example/tile.gif"], "added live: held again")
    }

    /// The pool's views share one user content controller, so one list in it covers every slot, and it follows the
    /// setting: in while on, out while off; a link opened meanwhile loses its tracking parameters.
    func testAPoolAddsAndRemovesTheListForEveryView() throws {
        let directory = folder.appendingPathComponent("env", isDirectory: true)
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer {
            var finished = false
            Task { @MainActor in await environment.shutdown(); finished = true }
            ListTestSupport.spin(until: { finished }, timeout: 5)
        }
        let pool = WebViewPool(client: environment.engine, size: 3)
        pool.trackerRules = try rules(scheme: "https?")
        for slot in pool.slots {
            XCTAssertTrue(slot.webView.configuration.userContentController === pool.configuration.userContentController,
                          "every slot's view reads the pool's controller")
        }
        XCTAssertNil(pool.installedTrackerRules, "nothing compiled or added while off")
        XCTAssertNil(pool.trackerRules.current)

        pool.blocksTrackers = true
        XCTAssertTrue(ListTestSupport.spin(until: { pool.installedTrackerRules != nil }, timeout: 20), "the list lands")
        let link = URL(string: "https://shop.example/p?utm_source=news&id=4")!
        var opened: [URL] = []
        let policy = try XCTUnwrap(pool.slots.first?.webView.navigationDelegate as? ConversationNavigationPolicy)
        policy.openExternally = { opened.append($0) }
        XCTAssertEqual(policy.outgoing(link).absoluteString, "https://shop.example/p?id=4")

        pool.blocksTrackers = false
        XCTAssertNil(pool.installedTrackerRules, "taken out at once")
        XCTAssertEqual(policy.outgoing(link), link, "links go as written again")
        pool.blocksTrackers = true
        XCTAssertTrue(ListTestSupport.spin(until: { pool.installedTrackerRules != nil }, timeout: 5), "and back, from the kept list")
        XCTAssertTrue(opened.isEmpty)
    }
}
