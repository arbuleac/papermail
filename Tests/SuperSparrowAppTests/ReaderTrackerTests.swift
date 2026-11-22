import AppKit
import SSCore
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Block trackers in the real reader (spec §5.60): its pool, scheme handlers and an engine over a throwaway store, with
/// settings in a throwaway defaults suite. Turning the setting on or off reaches the conversation on screen without a
/// relaunch: the marked tracker is held back or put back while the picture beside it stays loaded, the card's note comes
/// and goes, and the pool's content blocker and link stripping follow. The parked sources are data, so loading them reaches
/// no network. Gated behind `SS_UI_TESTS=1`, as every WebKit render is.
@MainActor
final class ReaderTrackerTests: XCTestCase {
    private var folder: URL!
    private var suite: String?
    private var savedPreference = false
    private var engine: MailEngine?
    private let account = ListTestSupport.accountA
    private lazy var conversation = ConversationID(accountID: account.id, providerID: "thread-trackers")
    private lazy var messageID = MessageID(accountID: account.id, providerID: "msg-trackers")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1", "WebKit runs with SS_UI_TESTS=1")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderTrackers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = AppSettings.shared
        savedPreference = ConversationViewController.loadRemoteImages
    }

    override func tearDownWithError() throws {
        ConversationViewController.loadRemoteImages = savedPreference
        if let engine {
            var stopped = false
            Task { await engine.stopAndWait(); stopped = true }
            ListTestSupport.spin(until: { stopped }, timeout: 5)
        }
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testTheSettingReachesTheShownConversation() throws {
        let suite = "ReaderTrackerTests-\(UUID().uuidString)"
        self.suite = suite
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        // After the settings, which hand the reader their own image preference when they load.
        ConversationViewController.loadRemoteImages = true
        let reader = try show(settings: settings)
        reader.pool.trackerRules = TrackerContentRules(
            store: try XCTUnwrap(WKContentRuleListStore(url: folder.appendingPathComponent("rules", isDirectory: true))))

        XCTAssertTrue(waitFor(drawnImages, toBe: "Hero 40, Pixel 3", in: reader), "off: both load; got \(evaluate(drawnImages, in: reader))")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-trackers').length", in: reader), "0")
        XCTAssertFalse(reader.pool.blocksTrackers)

        settings.blocksTrackers = true
        XCTAssertTrue(reader.pool.blocksTrackers, "the pool follows at once")
        XCTAssertTrue(waitFor("(document.querySelector('.ss-trackers .ss-btxt') || {}).textContent", toBe: "1 tracker blocked.", in: reader))
        XCTAssertTrue(waitFor(drawnImages, toBe: "Hero 40, Pixel 1", in: reader),
                      "on: the tracker shows its 1 px stand-in, the picture stays; got \(evaluate(drawnImages, in: reader))")
        XCTAssertTrue(ListTestSupport.spin(until: { reader.pool.installedTrackerRules != nil }, timeout: 20), "the content blocker lands")

        settings.blocksTrackers = false
        XCTAssertNil(reader.pool.installedTrackerRules)
        XCTAssertTrue(waitFor("document.querySelectorAll('.ss-trackers').length", toBe: "0", in: reader))
        XCTAssertTrue(waitFor(drawnImages, toBe: "Hero 40, Pixel 3", in: reader), "off again: put back; got \(evaluate(drawnImages, in: reader))")
        reader.show(nil)
    }

    // MARK: Support

    /// The images of the shown body as "alt naturalWidth", sorted; an image not loaded yet counts as 0.
    private let drawnImages = """
    (function () {
      var f = document.querySelector('.ss-card iframe'); var d = f && f.contentDocument;
      if (!d) { return ''; }
      return Array.prototype.map.call(d.images, function (i) { return i.alt + ' ' + (i.complete ? i.naturalWidth : 0); }).sort().join(', ');
    })()
    """

    /// A body as the sanitizer stores it with remote images allowed: a picture live (data standing in for its address) and
    /// a 3 px pixel parked and marked as a tracker.
    private func show(settings: AppSettings) throws -> ConversationViewController {
        let hero = "data:image/png;base64," + Self.png(width: 40, height: 30).base64EncodedString()
        let pixel = "data:image/png;base64," + Self.png(width: 3, height: 3).base64EncodedString()
        let rendered = "<div class=\"ss-body\"><p>Fall gear is here.</p><img src=\"\(hero)\" alt=\"Hero\">"
            + "<img src=\"\(HTMLSanitizer.placeholderImage)\" data-ss-src=\"\(pixel)\" \(HTMLSanitizer.trackerAttribute)=\"tiny\" alt=\"Pixel\"></div>"
        let store = InMemoryMailStore()
        try store.upsertAccount(account)
        try store.upsertMessages([MessageMetadata(
            id: messageID, conversationID: conversation, subject: "Fall gear", snippet: "Fall gear is here.",
            from: EmailAddress(name: "Trailhead", address: "news@trailhead.test"), to: [EmailAddress(address: account.email)],
            date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
        )])
        try store.saveBody(StoredBody(body: MessageBody(html: rendered, text: nil), renderedHTML: rendered, plainText: "Fall gear is here.",
                                      blockedRemoteImageCount: 1, trackerImageCount: 1), for: messageID)
        let service = DemoMailService()
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { service.provider(for: $0) },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        self.engine = engine
        let reader = ConversationViewController(client: engine, settings: settings)
        _ = reader.view
        reader.show(conversation)
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == self.conversation
        }, timeout: 10), "the conversation rendered")
        return reader
    }

    private func evaluate(_ script: String, in reader: ConversationViewController) -> String {
        guard let webView = reader.pool.current?.webView else { return "" }
        var answer: String?
        webView.evaluateJavaScript("(function () { var v = (\(script)); return v === null || v === undefined ? '' : String(v); })()") { value, _ in
            answer = value as? String ?? ""
        }
        ListTestSupport.spin(until: { answer != nil }, timeout: 5)
        return answer ?? ""
    }

    private func waitFor(_ script: String, toBe expected: String, in reader: ConversationViewController) -> Bool {
        ListTestSupport.spin(until: { self.evaluate(script, in: reader) == expected }, timeout: 10)
    }

    private static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
}
