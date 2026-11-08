import AppKit
import QuickLookUI
import SSCore
import WebKit
import XCTest
@testable import SuperSparrowApp

/// The reader's share of what the Mac provides (roadmap Q1.8, README "What the Mac provides"): text selected in a body
/// goes to the Services menu, and Space hands the target message's attachments to Quick Look, as quarantined files.
/// The engine runs over a throwaway store and a provider that hands over files from memory; no Quick Look panel is put
/// on the screen, and nothing reaches the network, the Keychain or the user's mail.
@MainActor
final class ReaderSystemFeaturesTests: XCTestCase {
    private var folder: URL!
    private let account = ListTestSupport.accountA
    private lazy var conversation = ConversationID(accountID: account.id, providerID: "thread-plan")
    private lazy var messageID = MessageID(accountID: account.id, providerID: "msg-plan")
    private let plan = AttachmentInfo(id: "att-plan", filename: "Plan.pdf", mimeType: "application/pdf", sizeBytes: 9, isInline: false)
    private let logo = AttachmentInfo(id: "att-logo", filename: "logo.png", mimeType: "image/png", sizeBytes: 4, contentID: "logo",
                                      isInline: true)
    private let figures = AttachmentInfo(id: "att-figures", filename: "Figures.csv", mimeType: "text/csv", sizeBytes: 12, isInline: false)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderSystemFeatures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTextSelectedInABodyGoesToServices() throws {
        let reader = try showPlan()
        defer { reader.show(nil) }
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        reader.view.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(reader.view)
        XCTAssertTrue(window.makeFirstResponder(webView))

        let selected = evaluate("""
        (function () {
          var frame = document.querySelector('.ss-frame iframe');
          var doc = frame && frame.contentDocument;
          if (!doc || !doc.body || doc.body.textContent.indexOf('quarterly') < 0) { return ''; }
          frame.contentWindow.focus();
          var range = doc.createRange();
          range.selectNodeContents(doc.body);
          var selection = frame.contentWindow.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          return selection.toString().trim();
        })()
        """, in: webView)
        XCTAssertEqual(selected, "The quarterly plan is attached.", "the body's text is selected")

        // AppKit asks with the legacy names, as for every NSTextView; WebKit learns of the selection a moment later.
        let legacy = ComposeTextView.legacyStringType
        XCTAssertTrue(ListTestSupport.spin(until: { webView.validRequestor(forSendType: legacy, returnType: nil) != nil }, timeout: 5),
                      "Services are offered for the selection")
        let requestor = try XCTUnwrap(webView.validRequestor(forSendType: legacy, returnType: nil) as AnyObject?)
        XCTAssertTrue(requestor === webView)
        let board = NSPasteboard(name: NSPasteboard.Name("ReaderSystemFeatures-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertEqual(requestor.writeSelection?(to: board, types: [legacy]), true)
        XCTAssertEqual(board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "The quarterly plan is attached.")
    }

    /// Space in the reader (spec §6): Quick Look gets the target message's attachments as files, the first one first and
    /// the inline image left out, each quarantined as it was written; the reader hands the panel its data source when the
    /// panel asks the responder chain.
    func testSpaceHandsQuickLookTheAttachmentsAsFiles() throws {
        let reader = try showPlan()
        defer { reader.show(nil) }
        let preview = reader.attachmentPreview
        preview.presentsPanel = false
        XCTAssertFalse(reader.acceptsPreviewPanelControl(nil), "nothing to preview yet")

        XCTAssertTrue(reader.openQuickLookForSelectedMessage(), "Space has attachments to preview")
        XCTAssertTrue(ListTestSupport.spin(until: { preview.numberOfPreviewItems(in: nil) == 2 }, timeout: 5), "both files arrived")
        XCTAssertTrue(reader.acceptsPreviewPanelControl(nil))
        let files = (0..<2).compactMap { preview.previewPanel(nil, previewItemAt: $0) as? URL }
        XCTAssertEqual(files.map(\.lastPathComponent), ["Plan.pdf", "Figures.csv"], "Quick Look picks the previewer from the name")
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, [Data("%PDF-plan".utf8), Data("q1,q2\n10,12\n".utf8)])
        for file in files { XCTAssertTrue(AttachmentSafety.isQuarantined(file), file.lastPathComponent) }
        XCTAssertNil(preview.previewPanel(nil, previewItemAt: 2))

        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        let previous = (panel.dataSource, panel.delegate)
        defer { (panel.dataSource, panel.delegate) = previous }
        reader.beginPreviewPanelControl(panel)
        XCTAssertTrue(panel.dataSource === preview)
        XCTAssertTrue(panel.delegate === preview)
        reader.endPreviewPanelControl(panel)
        XCTAssertNil(panel.dataSource)
    }

    // MARK: Helpers

    /// The reader showing one message with two attachments and an inline image, its body stored.
    private func showPlan() throws -> ConversationViewController {
        let store = InMemoryMailStore()
        try store.upsertAccount(account)
        try store.upsertMessages([MessageMetadata(
            id: messageID, conversationID: conversation, subject: "The plan", snippet: "The quarterly plan is attached.",
            from: EmailAddress(name: "Ada Lovelace", address: "ada@example.com"), to: [EmailAddress(address: account.email)],
            date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: true
        )])
        let html = "<p>The quarterly plan is attached.</p>"
        try store.saveBody(StoredBody(body: MessageBody(html: html, text: "The quarterly plan is attached.", attachments: [plan, logo, figures]),
                                      renderedHTML: html, plainText: "The quarterly plan is attached."), for: messageID)
        let provider = MemoryAttachmentProvider(accountID: account.id, files: [
            plan.id: Data("%PDF-plan".utf8), logo.id: Data("logo".utf8), figures.id: Data("q1,q2\n10,12\n".utf8),
        ])
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        let reader = ConversationViewController(client: engine)
        _ = reader.view
        reader.show(conversation)
        let slot = try XCTUnwrap(reader.pool.current)
        XCTAssertTrue(ListTestSupport.spin(until: { slot.isReady && slot.pendingRender == nil && !slot.renderInFlight
                                                    && slot.renderedID == self.conversation }, timeout: 10), "the conversation rendered")
        return reader
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> String {
        var result: String?
        let deadline = Date().addingTimeInterval(5)
        // The body's frame loads after the shell has rendered; ask again until it answers.
        repeat {
            var answer: String?
            webView.evaluateJavaScript(script) { value, _ in answer = value as? String ?? "" }
            ListTestSupport.spin(until: { answer != nil }, timeout: 2)
            result = answer
            if result?.isEmpty == false { break }
            ListTestSupport.spin(for: 0.1)
        } while Date() < deadline
        return result ?? ""
    }
}

/// Attachment bytes from memory, so the attachment cache's download path runs without a network.
private final class MemoryAttachmentProvider: MailProvider, @unchecked Sendable {
    let accountID: AccountID
    let kind: ProviderKind = .gmail
    private let files: [String: Data]

    init(accountID: AccountID, files: [String: Data]) {
        self.accountID = accountID
        self.files = files
    }

    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        guard let data = files[attachmentID] else { throw ProviderError.notFound }
        return data
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
