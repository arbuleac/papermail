import AppKit
import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Download on each attachment chip and Download all on a message with two files or more (spec §5.17): the shell's
/// controls and the messages they post, the save itself (a free name, the quarantine kept, one progress for a batch),
/// the saved toast (§5.30) and File › Download Attachments (⇧⌘D). Files go to a folder of the test's own, never to
/// ~/Downloads; the engine runs over a throwaway store and a provider that serves files from memory, so nothing reaches
/// the network, the Keychain or the user's mail.
@MainActor
final class AttachmentDownloadTests: XCTestCase {
    private var folder: URL!
    private var downloads: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentDownloadTests-\(UUID().uuidString)")
        downloads = folder.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A folder made unwritable by a test must be writable again to be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads.path)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The save

    func testACopyTakesAFreeNameAndKeepsTheQuarantine() throws {
        let source = folder.appendingPathComponent("plan.pdf")
        try AttachmentSafety.write(Data("%PDF-1.4".utf8), to: source)
        let first = try XCTUnwrap(AttachmentSaver.copy(source, into: downloads))
        let second = try XCTUnwrap(AttachmentSaver.copy(source, into: downloads))
        XCTAssertEqual(first.lastPathComponent, "plan.pdf")
        XCTAssertEqual(second.lastPathComponent, "plan 2.pdf", "numbered as the Finder numbers a copy")
        XCTAssertTrue(AttachmentSafety.isQuarantined(first))
        XCTAssertTrue(AttachmentSafety.isQuarantined(second))
        XCTAssertEqual(try Data(contentsOf: second), Data("%PDF-1.4".utf8))

        let bare = folder.appendingPathComponent("README")
        try AttachmentSafety.write(Data("hi".utf8), to: bare)
        _ = AttachmentSaver.copy(bare, into: downloads)
        XCTAssertEqual(AttachmentSaver.copy(bare, into: downloads)?.lastPathComponent, "README 2", "no extension, none added")
    }

    /// The session's files are quarantined as they are written; a copy of one that lost its mark is marked again.
    func testACopyOfAnUnmarkedFileIsMarked() throws {
        let source = folder.appendingPathComponent("run.command")
        try Data("#!/bin/sh\n".utf8).write(to: source)
        XCTAssertFalse(AttachmentSafety.isQuarantined(source))
        let copy = try XCTUnwrap(AttachmentSaver.copy(source, into: downloads))
        XCTAssertTrue(AttachmentSafety.isQuarantined(copy))
    }

    func testAFolderThatCannotBeWrittenSavesNothing() throws {
        let source = folder.appendingPathComponent("plan.pdf")
        try AttachmentSafety.write(Data("%PDF-1.4".utf8), to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: downloads.path)
        XCTAssertNil(AttachmentSaver.copy(source, into: downloads))
    }

    /// Download all fetches the files one after another and reports one fraction for all of them, rising, by size; a
    /// file that cannot be fetched is reported and the rest are saved.
    func testABatchSavesWhatArrivesWithOneRisingProgress() async throws {
        let infos = [
            AttachmentInfo(id: "a", filename: "a.pdf", mimeType: "application/pdf", sizeBytes: 1_000, isInline: false),
            AttachmentInfo(id: "b", filename: "b.pdf", mimeType: "application/pdf", sizeBytes: 1_000, isInline: false),
            AttachmentInfo(id: "c", filename: "c.txt", mimeType: "text/plain", sizeBytes: 2_000, isInline: false),
        ]
        let sources = folder.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let fractions = FractionLog()
        var missing: [String] = []
        let outcome = await AttachmentSaver.save(infos, into: downloads, fetch: { info, progress in
            progress(0.5)
            guard info.id != "b" else { return nil }
            let file = sources.appendingPathComponent(info.filename)
            try? AttachmentSafety.write(Data(info.id.utf8), to: file)
            progress(1)
            return file
        }, progress: { fractions.append($0) }, unfetched: { missing.append($0.id) })

        XCTAssertEqual(outcome.requested, 3)
        XCTAssertEqual(outcome.saved.map(\.lastPathComponent), ["a.pdf", "c.txt"])
        XCTAssertEqual(outcome.unfetched, 1)
        XCTAssertEqual(missing, ["b"])
        XCTAssertTrue(outcome.saved.allSatisfy(AttachmentSafety.isQuarantined))
        let seen = fractions.values
        XCTAssertEqual(seen, seen.sorted(), "never backwards")
        XCTAssertEqual(seen.first ?? -1, 0.125, accuracy: 1e-9, "half of the first file, a quarter of the bytes")
        XCTAssertEqual(seen.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(outcome.toast(), .saved("Saved 2 of 3 attachments to Downloads"))
    }

    // MARK: Script messages

    /// The two controls post ordinary shell actions; parsing stays total, so a malformed one is dropped.
    func testTheDownloadMessagesParse() throws {
        let message = MessageID(accountID: AccountID("acct"), providerID: "m1")
        let key = RenderPayload.messageKey(for: message)
        let one = ConversationScriptMessage(body: ["kind": "action", "type": "downloadAttachment", "messageID": key, "attachmentID": "att-1"])
        XCTAssertEqual(one, .action(type: "downloadAttachment", messageID: message, attachmentID: "att-1", on: nil, point: nil, value: nil))
        let all = ConversationScriptMessage(body: ["kind": "action", "type": "downloadAllAttachments", "messageID": key,
                                                   "attachmentID": NSNull()])
        XCTAssertEqual(all, .action(type: "downloadAllAttachments", messageID: message, attachmentID: nil, on: nil, point: nil, value: nil))
        XCTAssertNil(ConversationScriptMessage(body: ["kind": "action", "messageID": key]), "no type")
        XCTAssertNil(ConversationScriptMessage(body: "downloadAttachment"))
        // A focused Download control reports itself as the elision mark does, so Space and ↩ press it.
        XCTAssertEqual(ConversationScriptMessage(body: ["kind": "focusMark", "on": true]), .focusMark(true))
    }

    // MARK: The reader

    func testTheReaderDrawsDownloadAndDownloadAllAndSavesThroughThem() throws {
        let fixture = try ReaderFixture(folder: folder)
        let reader = fixture.reader
        reader.downloadsFolder = downloads
        var outcomes: [AttachmentSaveOutcome] = []
        reader.onAction = { action in
            if case .attachmentsSaved(let outcome) = action { outcomes.append(outcome) }
        }
        let webView = fixture.webView

        // Two files and an inline image: the count line names the two, and each chip carries its button.
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-atts-head').length", in: webView) as? Int, 1)
        XCTAssertEqual(evaluate("document.querySelector('.ss-atts-count').textContent", in: webView) as? String, "2 attachments")
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').textContent", in: webView) as? String, "Download all")
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').title", in: webView) as? String, "Download Attachments  \u{21e7}\u{2318}D")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip-dl').length", in: webView) as? Int, 2)
        let label = "document.querySelector('.ss-chip-dl[data-attachment-id=\"\(ReaderFixture.plan.id)\"]').getAttribute('aria-label')"
        XCTAssertEqual(evaluate(label, in: webView) as? String, "Download plan.pdf", "VoiceOver names the file")
        XCTAssertEqual(evaluate("document.querySelector('.ss-chip-dl').title", in: webView) as? String, "Save to Downloads")
        XCTAssertEqual(evaluate("document.querySelector('.ss-chip-dl').tabIndex", in: webView) as? Int, 0, "the first chip's button is a stop")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip-dl')[1].tabIndex", in: webView) as? Int, -1)

        // Download on a chip: the file in Downloads, still quarantined, then the toast's outcome.
        _ = evaluate("document.querySelector('.ss-chip-dl[data-attachment-id=\"\(ReaderFixture.plan.id)\"]').click(); true", in: webView)
        ListTestSupport.spin(until: { outcomes.count == 1 }, timeout: 5)
        let first = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(first.requested, 1)
        XCTAssertEqual(first.saved.map(\.lastPathComponent), ["plan.pdf"])
        XCTAssertEqual(first.toast(), .saved("Saved to Downloads"))
        let saved = downloads.appendingPathComponent("plan.pdf")
        XCTAssertEqual(try Data(contentsOf: saved), ReaderFixture.planBytes)
        XCTAssertTrue(AttachmentSafety.isQuarantined(saved), "the copy keeps the quarantine")

        // Download all: both files, the taken name numbered, one outcome.
        _ = evaluate("document.querySelector('.ss-dlall').click(); true", in: webView)
        ListTestSupport.spin(until: { outcomes.count == 2 }, timeout: 5)
        let all = try XCTUnwrap(outcomes.last)
        XCTAssertEqual(all.requested, 2)
        XCTAssertEqual(all.saved.map(\.lastPathComponent), ["plan 2.pdf", "notes.txt"])
        XCTAssertEqual(all.toast(), .saved("Saved 2 attachments to Downloads"))
        ListTestSupport.spin(until: { self.evaluate("document.querySelector('.ss-atts-head').classList.contains('ss-loading')", in: webView) as? Bool == false },
                             timeout: 5)
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').hasAttribute('aria-disabled')", in: webView) as? Bool, false,
                       "Download all is pressable again once it ends")

        // The context menu's Save to Downloads is the button's: the same save and the same toast.
        fixture.reader.downloadAttachment(ReaderFixture.notes, of: fixture.messageID)
        ListTestSupport.spin(until: { outcomes.count == 3 }, timeout: 5)
        XCTAssertEqual(outcomes.last?.saved.map(\.lastPathComponent), ["notes 2.txt"])
        fixture.close()
    }

    /// One file and an inline image: the chip has its Download button, and there is no count line or Download all,
    /// since an inline image is not a file to save.
    func testOneFileHasNoDownloadAll() throws {
        let fixture = try ReaderFixture(folder: folder, attachments: [ReaderFixture.logo, ReaderFixture.plan])
        let webView = fixture.webView
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip').length", in: webView) as? Int, 1)
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip-dl').length", in: webView) as? Int, 1)
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-atts-head, .ss-dlall').length", in: webView) as? Int, 0)
        fixture.close()
    }

    /// While Download all runs the count line shows one contrail and the link is disabled; a chip's own download
    /// disables its button. The values are the chip's: a fraction, null to sweep, negative to end.
    func testProgressDisablesTheControlThatStartedIt() throws {
        let fixture = try ReaderFixture(folder: folder)
        let webView = fixture.webView
        let key = ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: fixture.messageID))
        _ = evaluate("window.ss.attachmentsProgress(\(key), 0.5); true", in: webView)
        XCTAssertEqual(evaluate("document.querySelector('.ss-atts-head .ss-dl-fill').style.width", in: webView) as? String, "60px")
        XCTAssertEqual(evaluate("getComputedStyle(document.querySelector('.ss-atts-count')).display", in: webView) as? String, "none",
                       "the count gives way to the contrail")
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').getAttribute('aria-disabled')", in: webView) as? String, "true")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip.ss-loading').length", in: webView) as? Int, 0, "the chips do not show the batch")
        _ = evaluate("window.ss.attachmentsProgress(\(key), -1); true", in: webView)
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').hasAttribute('aria-disabled')", in: webView) as? Bool, false)

        let plan = ConversationShellAssets.jsStringLiteral(ReaderFixture.plan.id)
        _ = evaluate("window.ss.attachmentProgress(\(key), \(plan), null); true", in: webView)
        let button = "document.querySelector('.ss-chip-dl[data-attachment-id=\"\(ReaderFixture.plan.id)\"]')"
        XCTAssertEqual(evaluate("\(button).getAttribute('aria-disabled')", in: webView) as? String, "true")
        // A press while it downloads posts nothing.
        fixture.reader.downloadsFolder = downloads
        var outcomes = 0
        fixture.reader.onAction = { action in
            if case .attachmentsSaved = action { outcomes += 1 }
        }
        _ = evaluate("\(button).click(); true", in: webView)
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(outcomes, 0)
        _ = evaluate("window.ss.attachmentProgress(\(key), \(plan), -1); true", in: webView)
        XCTAssertEqual(evaluate("\(button).hasAttribute('aria-disabled')", in: webView) as? Bool, false)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: downloads.path)).isEmpty, "nothing was saved")
        fixture.close()
    }

    /// ← → move the stop along the chips' Download buttons as along the chips.
    func testArrowsMoveAlongTheDownloadButtons() throws {
        let fixture = try ReaderFixture(folder: folder)
        let webView = fixture.webView
        let script = """
            (function () {
              var saves = document.querySelectorAll('.ss-chip-dl');
              saves[0].focus();
              saves[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true }));
              var chips = document.querySelectorAll('.ss-chip');
              return [document.activeElement === saves[1], saves[1].tabIndex, chips[1].tabIndex, saves[0].tabIndex, chips[0].tabIndex];
            })()
            """
        let state = evaluate(script, in: webView) as? [Any]
        XCTAssertEqual(state?.first as? Bool, true, "focus moves to the next file's button")
        XCTAssertEqual(state?.dropFirst().compactMap { $0 as? Int }, [0, 0, -1, -1], "the chip and its button share the stop")
        fixture.close()
    }

    // MARK: The main window

    func testTheSavedToastOffersShowInFinder() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let saved = [downloads.appendingPathComponent("plan.pdf"), downloads.appendingPathComponent("notes.txt")]
        harness.controller.handle(.attachmentsSaved(AttachmentSaveOutcome(requested: 2, saved: saved, unfetched: 0)))
        // The long words where they fit beside Show in Finder, else shorter ones, so the count is never cut off.
        func fits(_ words: String) -> Bool {
            harness.toasts.fits(words, symbol: Quire.Icon.download, actionTitle: "Show in Finder", keycap: nil)
        }
        let long = "Saved 2 attachments to Downloads"
        XCTAssertEqual(harness.toastMessage, fits(long) ? long : "Saved 2 to Downloads")
        XCTAssertTrue(fits("Saved 2 to Downloads"), "the short words fit the default list")
        XCTAssertTrue(fits("Saved 2 of 3"), "and so do the shortest")
        XCTAssertEqual(harness.toasts.visibleKind, .notice, "a notice: nothing to undo")
        let slip = try XCTUnwrap(harness.controller.listPane.toastView.slip)
        XCTAssertEqual(slip.actionButton?.title, "Show in Finder")
        XCTAssertNil(slip.actionButton?.keycap, "no keycap: Z is not this toast's")
        XCTAssertEqual(slip.symbolName, Quire.Icon.download)
        XCTAssertEqual(slip.announcement, (harness.toastMessage ?? "") + ". Show in Finder.")

        harness.controller.handle(.attachmentsSaved(AttachmentSaveOutcome(requested: 1, saved: [], unfetched: 0)))
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t save to Downloads")
        XCTAssertEqual(harness.toasts.visibleKind, .error)

        harness.toasts.dismiss()
        harness.controller.handle(.attachmentsSaved(AttachmentSaveOutcome(requested: 2, saved: [], unfetched: 2)))
        XCTAssertFalse(harness.toasts.isVisible, "the chips say what could not be fetched")
    }

    /// File › Download Attachments is ⇧⌘D, answers from the list, and needs the target message to have a file of its
    /// own (an inline image is not one).
    func testFileDownloadAttachmentsIsCommandShiftDAndNeedsFiles() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "D", charactersIgnoringModifiers: "d",
                                                   isARepeat: false, keyCode: 2))
        let item = try XCTUnwrap(MainMenuBar.exactItem(for: event, in: bar))
        XCTAssertEqual(item.title, "Download Attachments")
        XCTAssertEqual(item.menu?.title, "File")
        XCTAssertEqual(item.action, #selector(MainWindowController.downloadAttachments(_:)))
        XCTAssertFalse(harness.controller.validateMenuItem(item), "nothing selected")

        let shown = try XCTUnwrap(harness.list.conversations.first { $0.hasAttachments })
        harness.controller.window?.makeFirstResponder(harness.list.tableView)
        harness.list.selectedConversationID = shown.id
        harness.list.onSelectionChange?(shown.id)
        harness.spin { harness.reader.currentConversationID == shown.id && !harness.reader.currentMessages.isEmpty }
        let target = try XCTUnwrap(harness.reader.selectedMessageID ?? harness.reader.currentMessages.last?.id)
        let inline = AttachmentInfo(id: "cid", filename: "logo.png", mimeType: "image/png", sizeBytes: 10, contentID: "logo", isInline: true)
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: "Hi", attachments: [inline]),
                                                          renderedHTML: "<p>Hi</p>", plainText: "Hi"), for: target)
        XCTAssertFalse(harness.controller.validateMenuItem(item), "an inline image is not a file to save")
        let file = AttachmentInfo(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 2_048, isInline: false)
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: "Hi", attachments: [inline, file]),
                                                          renderedHTML: "<p>Hi</p>", plainText: "Hi"), for: target)
        XCTAssertTrue(harness.controller.validateMenuItem(item), "offered from the list, the reader not in the chain")
    }

    // MARK: Helpers

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, error in
            result = error == nil ? value : nil
            done = true
        }
        ListTestSupport.spin(until: { done }, timeout: 5)
        return result
    }
}

/// Fractions as the batch reports them, from any thread.
private final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    func append(_ value: Double) { lock.withLock { list.append(value) } }
    var values: [Double] { lock.withLock { list } }
}

/// A reader showing one conversation whose latest message carries two files and an inline image, over an engine whose
/// provider serves the files from memory.
@MainActor
private final class ReaderFixture {
    static let plan = AttachmentInfo(id: "att-plan", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 4_000, isInline: false)
    static let notes = AttachmentInfo(id: "att-notes", filename: "notes.txt", mimeType: "text/plain", sizeBytes: 12, isInline: false)
    static let logo = AttachmentInfo(id: "att-logo", filename: "logo.png", mimeType: "image/png", sizeBytes: 10, contentID: "logo", isInline: true)
    static let planBytes = Data(repeating: 7, count: 4_000)

    let reader: ConversationViewController
    let messageID: MessageID
    let webView: WKWebView

    init(folder: URL, attachments: [AttachmentInfo]? = nil) throws {
        let account = ListTestSupport.accountA
        let conversation = ConversationID(accountID: account.id, providerID: "thread-plan")
        messageID = MessageID(accountID: account.id, providerID: "msg-plan")
        let store = InMemoryMailStore()
        try store.upsertAccount(account)
        try store.upsertMessages([MessageMetadata(
            id: messageID, conversationID: conversation, subject: "The plan", snippet: "Attached.",
            from: EmailAddress(name: "Ada Lovelace", address: "ada@example.com"), to: [EmailAddress(address: account.email)],
            date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: true
        )])
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Attached.</p>", text: "Attached.", attachments: attachments ?? [Self.plan, Self.logo, Self.notes]),
                                      renderedHTML: "<p>Attached.</p>", plainText: "Attached."), for: messageID)
        let provider = ServedAttachmentProvider(accountID: account.id, files: [
            Self.plan.id: Self.planBytes, Self.notes.id: Data("Notes, line 1".utf8),
        ])
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        reader = ConversationViewController(client: engine)
        _ = reader.view
        reader.show(conversation)
        let slot = try XCTUnwrap(reader.pool.current)
        ListTestSupport.spin(until: { slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == conversation },
                             timeout: 10)
        webView = slot.webView
    }

    func close() {
        reader.show(nil)
    }
}

/// Serves each file whole; an id it does not know fails, as a file the server no longer has would.
private final class ServedAttachmentProvider: MailProvider, @unchecked Sendable {
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
