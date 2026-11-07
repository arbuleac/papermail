import AppKit
import SSCore
import WebKit
import XCTest
@testable import SuperSparrowApp

/// A chip's download in the reader (spec §5.17, Q1.7b): for a file whose size is known, the contrail fills to what
/// has arrived instead of sweeping, and the meta returns when the fetch ends. The engine runs over a throwaway store
/// and a provider that streams its file in steps; nothing reaches the network, the Keychain or the user's mail.
@MainActor
final class AttachmentProgressTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentProgressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAChipShowsADeterminateContrailForAKnownSize() throws {
        let account = ListTestSupport.accountA
        let conversation = ConversationID(accountID: account.id, providerID: "thread-plan")
        let messageID = MessageID(accountID: account.id, providerID: "msg-plan")
        let info = AttachmentInfo(id: "att-plan", filename: "Plan.pdf", mimeType: "application/pdf", sizeBytes: 4_000, isInline: false)
        let store = InMemoryMailStore()
        try store.upsertAccount(account)
        try store.upsertMessages([MessageMetadata(
            id: messageID, conversationID: conversation, subject: "The plan", snippet: "Attached.",
            from: EmailAddress(name: "Ada Lovelace", address: "ada@example.com"), to: [EmailAddress(address: account.email)],
            date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: true
        )])
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Attached.</p>", text: "Attached.", attachments: [info]),
                                      renderedHTML: "<p>Attached.</p>", plainText: "Attached."), for: messageID)
        let provider = SteppedAttachmentProvider(accountID: account.id, file: Data(repeating: 7, count: 4_000))
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        let reader = ConversationViewController(client: engine)
        _ = reader.view
        reader.show(conversation)
        let slot = try XCTUnwrap(reader.pool.current)
        ListTestSupport.spin(until: { slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == conversation },
                             timeout: 10)
        XCTAssertEqual(chipState(info.id, in: slot.webView), "idle", "the chip is drawn with its meta")

        var fetched: URL??
        Task { fetched = .some(await reader.fetchAttachmentFile(info, of: messageID)) }
        // The provider reports 0, then half, and holds the rest back.
        ListTestSupport.spin(until: { self.chipState(info.id, in: slot.webView) == "determinate 60px" }, timeout: 5)
        XCTAssertEqual(chipState(info.id, in: slot.webView), "determinate 60px", "half of the 120 pt contrail, no sweep")
        XCTAssertEqual(provider.expectedSizes, [4_000], "the listed size went with the fetch")

        provider.release()
        ListTestSupport.spin(until: { fetched != nil }, timeout: 5)
        XCTAssertNotNil(fetched ?? nil, "the file arrived")
        ListTestSupport.spin(until: { self.chipState(info.id, in: slot.webView) == "idle" }, timeout: 5)
        XCTAssertEqual(chipState(info.id, in: slot.webView), "idle", "the meta returns when the fetch ends")
        reader.show(nil)
    }

    /// "idle" (meta shown), "sweeping", or "determinate <fill width>"; "missing" when no such chip is drawn.
    private func chipState(_ attachmentID: String, in webView: WKWebView) -> String {
        let script = """
        (function () {
          var chip = document.querySelector('.ss-chip[data-attachment-id="\(attachmentID)"]');
          if (!chip) { return 'missing'; }
          if (!chip.classList.contains('ss-loading')) { return 'idle'; }
          if (chip.querySelector('.ss-dl').classList.contains('ss-sweep')) { return 'sweeping'; }
          return 'determinate ' + chip.querySelector('.ss-dl-fill').style.width;
        })()
        """
        var state: String?
        webView.evaluateJavaScript(script) { value, _ in state = value as? String ?? "error" }
        ListTestSupport.spin(until: { state != nil }, timeout: 5)
        return state ?? "timeout"
    }
}

/// Streams one file in steps, as a provider over a slow network would: it reports 0, then half, and holds the file
/// until the test lets it go. Nothing else is asked of it, since the engine never starts.
private final class SteppedAttachmentProvider: MailProvider, @unchecked Sendable {
    let accountID: AccountID
    let kind: ProviderKind = .gmail
    private let file: Data
    private let lock = NSLock()
    private var held = true
    private var sizes: [Int] = []

    init(accountID: AccountID, file: Data) {
        self.accountID = accountID
        self.file = file
    }

    var expectedSizes: [Int] { lock.withLock { sizes } }

    func release() {
        lock.withLock { held = false }
    }

    func downloadAttachment(messageID providerID: String, attachmentID: String, expectedSize: Int, to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { sizes.append(expectedSize) }
        progress(0)
        try await Task.sleep(for: .milliseconds(20))
        progress(0.5)
        while lock.withLock({ held }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try file.write(to: destination)
        progress(1)
    }

    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data { file }
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
