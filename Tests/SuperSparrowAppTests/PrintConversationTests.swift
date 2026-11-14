import AppKit
import PDFKit
@testable import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// File › Print… in the real reader (spec §5.46), printed to a PDF file through the real print operation, with no panel:
/// every message of the conversation on the pages, the remote images the reader holds back never fetched while the ones it
/// shows are, folded quoted text left out and unfolded text printed, light paper in a dark app, and the command's place in
/// the menus. Runs over a throwaway store; a scheme of the test's own stands in for the network.
@MainActor
final class PrintConversationTests: XCTestCase {
    /// Counts what a printout fetches, and answers each request with a one-pixel image.
    @MainActor
    private final class RemoteRecorder: NSObject, WKURLSchemeHandler {
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

    private var folder: URL!
    private var environment: AppEnvironment?
    private var window: NSWindow?
    private let account = ListTestSupport.accountA
    private lazy var conversation = ConversationID(accountID: account.id, providerID: "thread-print")
    private let placeholder = HTMLSanitizer.placeholderImage

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrintConversation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        window = nil
        if let environment {
            var finished = false
            Task { @MainActor in
                await environment.shutdown()
                finished = true
            }
            ListTestSupport.spin(until: { finished }, timeout: 5)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    private func message(_ number: Int, from: EmailAddress, isRead: Bool = true, subject: String = "Quarterly plan") -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account.id, providerID: "msg-\(number)"), conversationID: conversation, subject: subject,
            snippet: "Message \(number)", from: from, to: [EmailAddress(name: "Alex Morgan", address: account.email)],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(number) * 3_600), roles: [.inbox], isRead: isRead, isStarred: false,
            hasAttachments: false
        )
    }

    private func body(_ html: String, quoted: Bool = false, blocked: Int = 0) -> StoredBody {
        StoredBody(body: MessageBody(html: html, text: nil, attachments: []), renderedHTML: html, plainText: "",
                   hasQuotedContent: quoted, blockedRemoteImageCount: blocked)
    }

    private func store(_ messages: [(MessageMetadata, StoredBody)]) throws -> AppEnvironment {
        let environment = try AppEnvironment.makeScratch(in: folder.appendingPathComponent("env-\(UUID().uuidString)"))
        self.environment = environment
        try environment.store.upsertAccount(account)
        try environment.store.upsertMessages(messages.map(\.0))
        for (message, stored) in messages { try environment.store.saveBody(stored, for: message.id) }
        return environment
    }

    /// The real reader in a window off screen, showing the conversation.
    private func reader(showing messages: [(MessageMetadata, StoredBody)], appearance: NSAppearance.Name = .aqua) throws -> ConversationViewController {
        let environment = try store(messages)
        let reader = ConversationViewController(client: environment.engine)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 840, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = reader
        window.setContentSize(NSSize(width: 840, height: 900))
        window.orderFrontRegardless()
        self.window = window
        reader.show(conversation)
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == self.conversation
        }, timeout: 10), "the conversation rendered")
        return reader
    }

    /// Prints what the reader shows to a PDF file, as File › Print… does, and reads it back.
    private func print(_ reader: ConversationViewController) throws -> PDFDocument {
        let url = folder.appendingPathComponent("print-\(UUID().uuidString).pdf")
        reader.printer.destination = .file(url)
        var finished: Bool?
        reader.printer.onFinish = { finished = $0 }
        reader.printConversation(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { finished != nil }, timeout: 20), "the print ran")
        XCTAssertEqual(finished, true)
        return try XCTUnwrap(PDFDocument(url: url), "a PDF was written")
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

    // MARK: Tests

    func testEveryMessagePrintsWhateverTheReaderCollapsed() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let long = (1...140).map { "<p>Line \($0) of the long reply.</p>" }.joined()
        let reader = try reader(showing: [
            (message(1, from: ada), body("<p>The first word on the plan.</p>")),
            (message(2, from: ben), body(long)),
            (message(3, from: ada, isRead: false), body("<p>The latest word on the plan.</p>")),
        ])
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-card.ss-collapsed').length", in: reader), "2",
                       "the reader collapses the read messages")

        let pdf = try print(reader)
        XCTAssertGreaterThan(pdf.pageCount, 1, "a long reply runs on to more pages")
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(pdf.page(at: 0)?.string?.hasPrefix("Quarterly plan") == true, "the subject heads the first page")
        for words in ["The first word on the plan.", "Line 1 of the long reply.", "Line 140 of the long reply.", "The latest word on the plan.",
                      "Ada Lovelace", "ada@contoso.test", "Ben Carter", "3 messages", "2023"] {
            XCTAssertTrue(text.contains(words), "printed: \(words)")
        }
        let first = try XCTUnwrap(text.range(of: "The first word"))
        let latest = try XCTUnwrap(text.range(of: "The latest word"))
        XCTAssertLessThan(first.lowerBound, latest.lowerBound, "oldest first")
        XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "Quarterly plan", "Quarterly plan")
    }

    func testFoldedQuotedTextIsLeftOutUntilTheReaderUnfoldsIt() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let reader = try reader(showing: [
            (message(1, from: ada, isRead: false), body("<p>Agreed, Thursday it is.</p><div class=\"ss-quote\"><p>Shall we say Thursday?</p></div>", quoted: true)),
        ])
        let folded = try XCTUnwrap(try print(reader).string)
        XCTAssertTrue(folded.contains("Agreed, Thursday it is."))
        XCTAssertFalse(folded.contains("Shall we say Thursday?"), "folded in the reader, left out on paper")
        XCTAssertTrue(folded.contains("Quoted text hidden"))

        _ = evaluate("window.ss.toggleQuotes()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { self.evaluate("window.ss.cardStates()[0].quotesShown", in: reader) == "true" }, timeout: 5))
        let unfolded = try XCTUnwrap(try print(reader).string)
        XCTAssertTrue(unfolded.contains("Shall we say Thursday?"), "unfolded in the reader, printed")
        XCTAssertFalse(unfolded.contains("Quoted text hidden"))
    }

    /// The reader's image policy, per body, in one printed page: the shown body's parked image is put back and fetched;
    /// nothing in the held-back body is, neither its parked image nor a live one (a body stored while Load remote images
    /// was on) nor its stylesheet's background.
    func testPrintingFetchesOnlyTheImagesTheReaderShows() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let shown = message(1, from: ada)
        let held = message(2, from: ada)
        let environment = try store([
            (shown, body("<p>Shown</p><img src=\"\(placeholder)\" data-ss-src=\"ss-remote://images/shown.gif\" width=\"20\" height=\"20\">", blocked: 1)),
            (held, body("<style>.band{background:url(ss-remote://images/held-band.gif)}</style><p class=\"band\">Held</p>"
                        + "<img src=\"ss-remote://images/held-live.gif\" width=\"20\" height=\"20\">"
                        + "<img src=\"\(placeholder)\" data-ss-src=\"ss-remote://images/held-parked.gif\" width=\"20\" height=\"20\">", blocked: 1)),
        ])
        let messages = try environment.store.messages(in: conversation)
        let bodies = Dictionary(uniqueKeysWithValues: try messages.map { ($0.id, try XCTUnwrap(try environment.store.body(for: $0.id))) })
        let payload = RenderPayloadBuilder().build(messages: messages, bodies: bodies, accounts: [account.id: account])
        let recorder = RemoteRecorder()
        let printer = ConversationPrinter(client: environment.engine, schemeHandlers: [RemoteRecorder.scheme: recorder])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        self.window = window

        func run(_ sheets: [String: PrintSheetState]) throws -> String {
            let url = folder.appendingPathComponent("images-\(UUID().uuidString).pdf")
            printer.destination = .file(url)
            var finished: Bool?
            printer.onFinish = { finished = $0 }
            let document = PrintDocumentBuilder().document(for: payload, sheets: sheets)
            XCTAssertTrue(printer.print(document, title: "Images", imageWait: 3, on: window))
            XCTAssertTrue(ListTestSupport.spin(until: { finished != nil }, timeout: 20))
            XCTAssertEqual(finished, true)
            return PDFDocument(url: url)?.string ?? ""
        }

        let mixed = try run([RenderPayload.messageKey(for: shown.id): PrintSheetState(imagesShown: true),
                             RenderPayload.messageKey(for: held.id): PrintSheetState(imagesShown: false, liveRemoteImages: 1)])
        XCTAssertEqual(recorder.paths, ["/shown.gif"], "only what the reader shows is fetched")
        XCTAssertTrue(mixed.contains("Shown") && mixed.contains("Held"), "both bodies print")
        XCTAssertTrue(mixed.contains("2 remote images hidden"), "the held-back body says what it holds back")

        let before = recorder.paths.count
        _ = try run([:])
        XCTAssertEqual(recorder.paths.count, before, "a conversation whose images are all held back fetches nothing")

        _ = try run([RenderPayload.messageKey(for: shown.id): PrintSheetState(imagesShown: true),
                     RenderPayload.messageKey(for: held.id): PrintSheetState(imagesShown: true)])
        XCTAssertEqual(Set(recorder.paths.dropFirst(before)), ["/shown.gif", "/held-band.gif", "/held-live.gif", "/held-parked.gif"],
                       "with every image shown, everything the reader would load is fetched")
    }

    func testTheReaderShowsLoadedImagesAndThePrintoutFollows() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let only = message(1, from: ada, isRead: false)
        let reader = try reader(showing: [(only, body("<p>News</p><img src=\"\(placeholder)\" data-ss-src=\"https://example.invalid/a.gif\">", blocked: 1))])
        let held = try XCTUnwrap(try print(reader).string)
        XCTAssertTrue(held.contains("1 remote image hidden"))
        // Load images, as ⇧⌘I does: the printout follows the reader. The reader's own fetch fails offline, which is no matter.
        _ = evaluate("window.ss.loadImages(null)", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { self.evaluate("window.ss.cardStates()[0].imagesLoaded", in: reader) == "true" }, timeout: 5))
        let shown = try XCTUnwrap(try print(reader).string)
        XCTAssertFalse(shown.contains("remote image hidden"))
    }

    func testThePaperIsLightInADarkApp() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let words = (1...30).map { "<p>Plain words that should print in a dark ink on light paper, line \($0).</p>" }.joined()
        // The app dark, not only the window: a web view outside any window, as the printer's is, follows the app.
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = NSAppearance(named: .darkAqua)
        defer { app.appearance = previous }
        let reader = try reader(showing: [(message(1, from: ada, isRead: false), body(words))], appearance: .darkAqua)
        XCTAssertEqual(reader.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        let page = try XCTUnwrap(try print(reader).page(at: 0))
        // Light ink on white paper would leave almost nothing dark; the printout's ink is Light's, near black.
        let image = page.thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var dark = 0
        var total = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                if color.alphaComponent > 0.5, luminance < 0.4 { dark += 1 }
            }
        }
        XCTAssertGreaterThan(Double(dark) / Double(max(1, total)), 0.01, "dark ink on the page: \(dark) of \(total) samples")
    }

    func testPrintIsOfferedForOneOpenConversationAndOneAtATime() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let reader = try reader(showing: [(message(1, from: ada, isRead: false), body("<p>Hello</p>"))])
        let item = NSMenuItem(title: "Print…", action: #selector(ConversationViewController.printConversation(_:)), keyEquivalent: "p")
        XCTAssertTrue(reader.validateMenuItem(item))

        let url = folder.appendingPathComponent("busy.pdf")
        reader.printer.destination = .file(url)
        var finished: Bool?
        reader.printer.onFinish = { finished = $0 }
        reader.printConversation(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { reader.printer.isBusy || finished != nil }, timeout: 5))
        if finished == nil { XCTAssertFalse(reader.validateMenuItem(item), "one printout at a time") }
        XCTAssertTrue(ListTestSupport.spin(until: { finished != nil }, timeout: 20))
        XCTAssertTrue(reader.validateMenuItem(item), "and again once it is done")

        let other = ConversationID(accountID: account.id, providerID: "thread-other")
        reader.showSelection([conversation, other])
        XCTAssertTrue(ListTestSupport.spin(until: { !reader.validateMenuItem(item) }, timeout: 5), "not with several selected")
        reader.show(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { !reader.validateMenuItem(item) }, timeout: 5), "nor with nothing open")
    }

    /// The printout's stylesheet lives in SSCore, which cannot read the tokens, so its metrics are written out there; this
    /// holds them to `layout.print` and the reader's own (`layout.reader`, `layout.invitation`).
    func testThePrintoutsMetricsAreTheTokens() {
        let css = PrintDocumentAssets.css
        func px(_ value: CGFloat) -> String { "\(Int(value))px" }
        let print = Quire.Layout.Print.self
        let reader = Quire.Layout.Reader.self
        let invitation = Quire.Layout.Invitation.self
        for rule in [
            ".ss-pparts { margin: \(px(print.partsTop)) 0 0;",
            ".ss-pmsg { margin-top: \(px(print.messageGap)); padding-top: \(px(print.messageGap));",
            "gap: \(px(print.noteGap)); margin-top: \(px(print.noteTop));",
            ".ss-pnote svg { flex: none; width: \(px(print.noteGlyph)); height: \(px(print.noteGlyph)); }",
            ".ss-patts li + li { margin-top: \(px(print.attachmentGap)); }",
            ".ss-phead { display: flex; gap: \(px(reader.headerGap));",
            ".ss-paddr { margin-left: \(px(reader.addressGap));",
            ".ss-pind { margin-left: \(px(reader.bodyIndent)); }",
            ".ss-pbody { margin-top: \(px(reader.bodyTop)); }",
            ".ss-patts { list-style: none; margin-top: \(px(reader.attachmentsTop));",
            ".ss-av36 { width: \(px(reader.headerAvatar)); height: \(px(reader.headerAvatar));",
            ".ss-pinvite { margin-top: \(px(reader.bodyTop)); max-width: \(px(reader.measure)); padding: \(px(invitation.padTop)) \(px(invitation.padX));",
            ".ss-pititle { margin-top: \(px(invitation.titleTop));",
            ".ss-piwhen { margin-top: \(px(invitation.whenTop));",
            "margin: \(px(invitation.detailsTop)) 0 0; display: grid; grid-template-columns: \(px(invitation.labelColumn)) minmax(0, 1fr); row-gap: \(px(invitation.rowGap));",
        ] {
            XCTAssertTrue(css.contains(rule), "the print stylesheet holds: \(rule)")
        }
        XCTAssertEqual(invitation.padTop, invitation.padBottom, "one vertical padding serves both")
        XCTAssertTrue(PrintDocumentAssets.bodyCSS.contains("max-width: \(px(reader.measure))"), "plain bodies keep the reading measure")
        XCTAssertEqual(Quire.Layout.Print.imageWait, "motion.duration.printImageWait")
    }

    func testFilePrintIsCommandPAndAnswersFromTheMainWindow() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let file = try XCTUnwrap(bar.items.first { $0.title == "File" }?.submenu)
        let print = try XCTUnwrap(file.items.first { $0.title == "Print…" })
        XCTAssertEqual(print.action, #selector(MainWindowController.printConversation(_:)))
        XCTAssertEqual(print.keyEquivalent, "p")
        XCTAssertEqual(print.keyEquivalentModifierMask, .command)
        XCTAssertNil(print.target, "it goes to the first responder, so the main window's reader answers it")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                                   context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        XCTAssertTrue(MainMenuBar.exactItem(for: event, in: bar) === print, "⌘P is Print… and nothing else")

        let harness = try MainWindowHarness()
        defer { harness.close() }
        let command = NSMenuItem(title: "", action: #selector(MainWindowController.printConversation(_:)), keyEquivalent: "")
        XCTAssertTrue(harness.controller.responds(to: #selector(MainWindowController.printConversation(_:))))
        XCTAssertFalse(harness.controller.validateMenuItem(command), "nothing open, nothing to print")
        harness.controller.window?.makeFirstResponder(harness.list.tableView)
        let first = try XCTUnwrap(harness.list.conversations.first)
        harness.list.selectedConversationID = first.id
        harness.list.onSelectionChange?(first.id)
        harness.spin { harness.controller.validateMenuItem(command) }
        XCTAssertTrue(harness.controller.validateMenuItem(command), "focus on the list, one conversation open")
    }
}
