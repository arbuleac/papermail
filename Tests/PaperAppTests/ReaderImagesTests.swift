import AppKit
import PaperCore
import WebKit
import XCTest
@testable import PaperApp

/// Every kind of image a message carries draws in the real reader (its pool's web views, scheme handlers and an
/// engine over a throwaway store): an inline cid: image fetched through the attachment cache, a data: image, and a
/// remote image parked at sync time, with Load remote images on and when the user loads one message's images, under
/// an invitation card as well. The parked image's source is data, so loading it reaches no network; plain-http
/// sources depend on the bundle's transport policy, which `AppTransportSecurityTests` holds.
@MainActor
final class ReaderImagesTests: XCTestCase {
    private var folder: URL!
    private var savedPreference = false
    private let account = ListTestSupport.accountA
    private lazy var conversation = ConversationID(accountID: account.id, providerID: "thread-images")
    private lazy var messageID = MessageID(accountID: account.id, providerID: "msg-images")
    private var engine: MailEngine?
    private let logo = AttachmentInfo(id: "att-logo", filename: "logo.png", mimeType: "image/png", sizeBytes: 0,
                                      contentID: "logo@contoso.test", isInline: true)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The settings write the preference into the reader when they first load (the app loads them at launch);
        // loaded here, before the tests set it, so the reader's first render does not put the saved value back.
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
        try? FileManager.default.removeItem(at: folder)
    }

    func testEveryKindDrawsWithRemoteImagesOn() throws {
        ConversationViewController.loadRemoteImages = true
        let provider = ImageProvider(accountID: account.id, png: Self.png(width: 30, height: 20))
        let reader = try show(provider: provider)
        XCTAssertTrue(waitFor(drawnImages, toBe: "Banner 40, Chart 20, Logo 30", in: reader), "got \(evaluate(drawnImages, in: reader))")
        XCTAssertEqual(provider.fetches, ["att-logo"], "the inline image came through the attachment cache")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-load-images').length", in: reader), "0", "nothing is held back")
        reader.show(nil)
    }

    /// With the preference off only the remote image waits: inline and data images are this Mac's and draw under the
    /// blocking policy, and Load images brings the remote one in.
    func testOnlyTheRemoteImageWaitsForLoadImages() throws {
        ConversationViewController.loadRemoteImages = false
        let reader = try show(provider: ImageProvider(accountID: account.id, png: Self.png(width: 30, height: 20)))
        XCTAssertTrue(waitFor(drawnImages, toBe: "Banner 1, Chart 20, Logo 30", in: reader),
                      "the parked image keeps its 1 px stand-in; got \(evaluate(drawnImages, in: reader))")
        XCTAssertEqual(evaluate("document.querySelector('.ss-banner .ss-wide').textContent", in: reader),
                       "1 remote image hidden to protect your privacy.")
        reader.loadImages(nil)
        XCTAssertTrue(waitFor(drawnImages, toBe: "Banner 40, Chart 20, Logo 30", in: reader), "got \(evaluate(drawnImages, in: reader))")
        XCTAssertTrue(waitFor("document.querySelectorAll('.ss-banner').length", toBe: "0", in: reader), "the banner goes once they load")
        reader.show(nil)
    }

    /// The message under an invitation card loads its images while folded, out of sight, and shows them unfolded.
    func testImagesUnderAnInvitationCard() throws {
        ConversationViewController.loadRemoteImages = true
        let reader = try show(provider: ImageProvider(accountID: account.id, png: Self.png(width: 30, height: 20)),
                              invitation: invitation())
        XCTAssertEqual(evaluate("document.querySelector('.ss-card').classList.contains('ss-mfolded')", in: reader), "true")
        XCTAssertTrue(waitFor(drawnImages, toBe: "Banner 40, Chart 20, Logo 30", in: reader), "got \(evaluate(drawnImages, in: reader))")
        _ = evaluate("document.querySelector('.ss-mrow .ss-elide').click()", in: reader)
        XCTAssertTrue(waitFor("document.querySelector('.ss-card').classList.contains('ss-mfolded')", toBe: "false", in: reader))
        let height = Double(evaluate("document.querySelector('.ss-card iframe').getBoundingClientRect().height", in: reader)) ?? 0
        XCTAssertGreaterThanOrEqual(height, 30, "the unfolded frame is as tall as its tallest image")
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

    /// A body as the sanitizer stores it: the cid: and data: images from the source, then a remote image parked as the
    /// sanitizer parks one while the preference is off, with data standing in for its address.
    private func show(provider: ImageProvider, invitation: CalendarInvitation? = nil) throws -> ConversationViewController {
        let chart = "data:image/png;base64," + Self.png(width: 20, height: 10).base64EncodedString()
        let source = "<p>Figures attached.</p><img src=\"cid:logo@contoso.test\" alt=\"Logo\"><img src=\"\(chart)\" alt=\"Chart\">"
        let sanitized = HTMLSanitizer().sanitize(MessageBody(html: source, text: nil, attachments: [logo]), messageID: messageID)
        let banner = "data:image/png;base64," + Self.png(width: 40, height: 30).base64EncodedString()
        let parked = "<img src=\"\(HTMLSanitizer.placeholderImage)\" data-ss-src=\"\(banner)\" alt=\"Banner\">"
        // Inside the sanitizer's wrapper, whose closing tag ends the body.
        let wrapperEnd = try XCTUnwrap(sanitized.html.range(of: "</div>", options: .backwards))
        let rendered = sanitized.html.replacingCharacters(in: wrapperEnd, with: parked + "</div>")
        let store = InMemoryMailStore()
        try store.upsertAccount(account)
        try store.upsertMessages([MessageMetadata(
            id: messageID, conversationID: conversation, subject: "Figures", snippet: "Figures attached.",
            from: EmailAddress(name: "Ben Carter", address: "ben@contoso.test"), to: [EmailAddress(address: account.email)],
            date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
        )])
        try store.saveBody(StoredBody(body: MessageBody(html: source, text: nil, attachments: [logo]), renderedHTML: rendered,
                                      plainText: sanitized.plainText, blockedRemoteImageCount: 1, invitation: invitation),
                           for: messageID)
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        self.engine = engine
        let reader = ConversationViewController(client: engine)
        _ = reader.view
        reader.show(conversation)
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == self.conversation
        }, timeout: 10), "the conversation rendered")
        return reader
    }

    private func invitation() -> CalendarInvitation {
        CalendarInvitation(
            method: .request, uid: "uid-images@google.com", title: "Figures review",
            start: Date().addingTimeInterval(86_400), end: Date().addingTimeInterval(86_400 + 3_600),
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@contoso.test"),
            attendees: [CalendarInvitation.Person(name: nil, address: account.email, response: .needsAction)],
            userAddress: account.email, userResponse: .needsAction,
            calendarText: "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"
        )
    }

    private static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: .png, properties: [:]) ?? Data()
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

    private func waitFor(_ script: String, toBe expected: String, in reader: ConversationViewController, timeout: TimeInterval = 10) -> Bool {
        ListTestSupport.spin(until: { self.evaluate(script, in: reader) == expected }, timeout: timeout)
    }
}

/// Serves one image for every attachment and records what was asked for; nothing else is asked of it.
private final class ImageProvider: MailProvider, @unchecked Sendable {
    let accountID: AccountID
    let kind: ProviderKind = .gmail
    private let png: Data
    private let lock = NSLock()
    private var asked: [String] = []

    init(accountID: AccountID, png: Data) {
        self.accountID = accountID
        self.png = png
    }

    var fetches: [String] { lock.withLock { asked } }

    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        lock.withLock { asked.append(attachmentID) }
        return png
    }

    func profile() async throws -> AccountProfile { AccountProfile(email: "alex@contoso.test", displayName: "Alex") }
    func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        BootstrapPage(messages: [], nextPage: nil, changeCursor: "c")
    }
    func changes(since cursor: String, limit: Int) async throws -> ChangesPage {
        ChangesPage(upserts: [], deletedIDs: [], cursor: cursor, hasMore: false)
    }
    func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] { [] }
    func body(for providerID: String) async throws -> MessageBody { throw ProviderError.notFound }
    func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {}
    func send(_ message: OutgoingMessage) async throws -> SendReceipt { throw ProviderError.notFound }
    func search(_ text: String, limit: Int) async throws -> [String] { [] }
}
