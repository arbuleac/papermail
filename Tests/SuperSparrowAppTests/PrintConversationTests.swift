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

    /// A remote image that is asked for and never comes, as a slow tracking pixel's.
    @MainActor
    private final class StalledRemote: NSObject, WKURLSchemeHandler {
        private(set) var paths: [String] = []
        private var open: [ObjectIdentifier: WKURLSchemeTask] = [:]

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            paths.append(urlSchemeTask.request.url?.path ?? "")
            open[ObjectIdentifier(urlSchemeTask)] = urlSchemeTask
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            open[ObjectIdentifier(urlSchemeTask)] = nil
        }
    }

    /// The inline images' scheme answered as a download would answer it: `image` after `delay`, unless the page stopped
    /// asking first.
    @MainActor
    private final class SlowInlineImages: NSObject, WKURLSchemeHandler {
        let delay: TimeInterval
        let image: Data
        private(set) var requested: [String] = []
        private(set) var served: [String] = []
        /// Told as each answer goes out.
        var onServe: (() -> Void)?
        private var open: [ObjectIdentifier: WKURLSchemeTask] = [:]

        init(delay: TimeInterval, image: Data) {
            self.delay = delay
            self.image = image
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url else { return }
            requested.append(url.path)
            let key = ObjectIdentifier(urlSchemeTask)
            open[key] = urlSchemeTask
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let task = self.open.removeValue(forKey: key) else { return }
                    task.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: self.image.count, textEncodingName: nil))
                    task.didReceive(self.image)
                    task.didFinish()
                    self.served.append(url.path)
                    self.onServe?()
                }
            }
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
            open[ObjectIdentifier(urlSchemeTask)] = nil
        }
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

    /// The payload a render of the stored conversation draws.
    private func payload(_ environment: AppEnvironment) throws -> RenderPayload {
        let messages = try environment.store.messages(in: conversation)
        let bodies = Dictionary(uniqueKeysWithValues: try messages.map { ($0.id, try XCTUnwrap(try environment.store.body(for: $0.id))) })
        return RenderPayloadBuilder().build(messages: messages, bodies: bodies, accounts: [account.id: account])
    }

    /// A window for a printer of the test's own to print on.
    private func printingWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        self.window = window
        return window
    }

    /// Prints `document` with `printer` to a PDF file and reads it back.
    private func print(_ document: String, with printer: ConversationPrinter, imageWait: TimeInterval) throws -> PDFDocument {
        let url = folder.appendingPathComponent("direct-\(UUID().uuidString).pdf")
        printer.destination = .file(url)
        var finished: Bool?
        printer.onFinish = { finished = $0 }
        XCTAssertTrue(printer.print(document, title: "Direct", imageWait: imageWait, on: window ?? printingWindow()))
        XCTAssertTrue(ListTestSupport.spin(until: { finished != nil }, timeout: 20), "the print ran")
        XCTAssertEqual(finished, true)
        return try XCTUnwrap(PDFDocument(url: url), "a PDF was written")
    }

    /// `page` drawn at one pixel per point (or the screen's scale), white where nothing is drawn.
    private func bitmap(of page: PDFPage) throws -> NSBitmapImageRep {
        let image = page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox)
        return try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    }

    /// How many of the pixels in `rect` (page points, origin at the bottom left) pass `test`.
    private func count(in bitmap: NSBitmapImageRep, page: PDFPage, rect: CGRect? = nil, where test: (NSColor) -> Bool) -> Int {
        let size = page.bounds(for: .mediaBox).size
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let area = (rect ?? CGRect(origin: .zero, size: size)).intersection(CGRect(origin: .zero, size: size))
        var found = 0
        for y in Int(area.minY * scale)..<Int(area.maxY * scale) {
            for x in Int(area.minX * scale)..<Int(area.maxX * scale) {
                guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
                if test(color) { found += 1 }
            }
        }
        return found
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    /// An 8-pixel square PNG of pure red, which nothing else on a printout is.
    private static func redPNG() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<8 { for x in 0..<8 { rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
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
        let payload = try payload(environment)
        let recorder = RemoteRecorder()
        let printer = ConversationPrinter(client: environment.engine, schemeHandlers: [RemoteRecorder.scheme: recorder])

        func run(_ sheets: [String: PrintSheetState]) throws -> String {
            try print(PrintDocumentBuilder().document(for: payload, sheets: sheets), with: printer, imageWait: 3).string ?? ""
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

    /// Each step has a wait of its own. With Load remote images off, a reply with an inline screenshot prints in the
    /// second step, its images held back; a slow remote image in a body shown before it has used up the first step's wait,
    /// and the screenshot, answered as a download would be, still comes in before the page says it is ready.
    func testAHeldBackBodysInlineImagesGetAWaitOfTheirOwn() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let shown = message(1, from: ada)
        let held = message(2, from: ben)
        let environment = try store([
            (shown, body("<p>The newsletter</p><img src=\"ss-remote://images/pixel.gif\" width=\"20\" height=\"20\">")),
            (held, body("<p>The screenshot</p><img src=\"ss-cid://account/message/screenshot\" width=\"80\" height=\"80\">")),
        ])
        let stalled = StalledRemote()
        let inline = SlowInlineImages(delay: 0.6, image: try Self.redPNG())
        let printer = ConversationPrinter(client: environment.engine,
                                          schemeHandlers: [RemoteRecorder.scheme: stalled, RenderURLScheme.inlineImage: inline])
        var printingWhenServed: [Bool] = []
        inline.onServe = { [weak printer] in printingWhenServed.append(printer?.isPrinting ?? true) }
        let wait: TimeInterval = 1
        let document = PrintDocumentBuilder(imageWait: wait).document(for: try payload(environment), sheets: [
            RenderPayload.messageKey(for: shown.id): PrintSheetState(imagesShown: true),
            RenderPayload.messageKey(for: held.id): PrintSheetState(imagesShown: false),
        ])
        let started = Date()
        let pdf = try print(document, with: printer, imageWait: wait)
        XCTAssertEqual(stalled.paths, ["/pixel.gif"], "the shown body's image was asked for and never came")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), wait + inline.delay, "the first step waited all of its wait, then the second")
        XCTAssertEqual(inline.requested.count, 1, "the held-back body's inline image was asked for")
        XCTAssertEqual(inline.served, inline.requested, "and came in")
        XCTAssertEqual(printingWhenServed, [false], "before the page said it was ready")
        let page = try XCTUnwrap(pdf.page(at: 0))
        let red = count(in: try bitmap(of: page), page: page) { $0.redComponent > 0.8 && $0.greenComponent < 0.25 && $0.blueComponent < 0.25 }
        XCTAssertGreaterThan(red, 1_000, "the screenshot printed, not an empty box: \(red) red pixels")
    }

    /// In the reader a body is a frame that contains whatever it places; on paper its host does the same, so a block a
    /// sender pins to the top left lands at the top of its own body, under its own sender, and never over the masthead
    /// or another message's header.
    func testABodysPositionedContentStaysInItsSheet() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let cover = "<div style=\"position:absolute;top:0;left:0;width:420px;height:400px;background:#fff;z-index:2147483647\">Forged words</div>"
        let reader = try reader(showing: [
            (message(1, from: ada), body("<p>The first word on the plan.</p>")),
            (message(2, from: ben, isRead: false), body(cover + "<p>The latest word on the plan.</p>")),
        ])
        let pdf = try print(reader)
        let page = try XCTUnwrap(pdf.page(at: 0))
        func bounds(_ words: String) throws -> CGRect {
            try XCTUnwrap(pdf.findString(words, withOptions: []).first, words).bounds(for: page)
        }
        let forged = try bounds("Forged words")
        let sender = try bounds("ben@contoso.test")
        let first = try bounds("The first word on the plan.")
        XCTAssertLessThanOrEqual(forged.maxY, sender.minY, "the block sits in its own body, below its sender's line")
        XCTAssertLessThanOrEqual(forged.maxY, first.minY, "and below the first message")
        // Painted over, text still reads in a PDF's text; so look at the paper: the masthead and the other message still
        // show their ink.
        let paper = try bitmap(of: page)
        for words in ["Quarterly plan", "The first word on the plan.", "ben@contoso.test"] {
            let ink = count(in: paper, page: page, rect: try bounds(words)) { $0.alphaComponent > 0.5 && Self.luminance($0) < 0.6 }
            XCTAssertGreaterThan(ink, 10, "\(words) still shows on the paper")
        }
    }

    /// The reader runs none of a body's script (its frame's sandbox); the printout's page lets none run either, from the
    /// first byte: an event handler or a script element that got past the sanitizer fetches nothing.
    func testNoScriptInABodyRuns() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let shown = message(1, from: ada)
        let environment = try store([
            (shown, body("<p>Shown</p><img src=\"ss-remote://images/pixel.gif\" width=\"20\" height=\"20\" "
                         + "onload=\"new Image().src='ss-remote://images/onload.gif'\">"
                         + "<img src=\"ss-nowhere://images/missing.gif\" onerror=\"new Image().src='ss-remote://images/onerror.gif'\">"
                         + "<script>new Image().src='ss-remote://images/script.gif'</script>")),
        ])
        let recorder = RemoteRecorder()
        let printer = ConversationPrinter(client: environment.engine, schemeHandlers: [RemoteRecorder.scheme: recorder])
        let document = PrintDocumentBuilder().document(for: try payload(environment),
                                                       sheets: [RenderPayload.messageKey(for: shown.id): PrintSheetState(imagesShown: true)])
        let text = try XCTUnwrap(try print(document, with: printer, imageWait: 3).string)
        XCTAssertTrue(text.contains("Shown"), "the document's own script ran and attached the body")
        XCTAssertEqual(recorder.paths, ["/pixel.gif"], "nothing a body's script asks for is fetched")
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
        // Light ink on white paper would leave almost nothing dark, and dark paper almost nothing light: the printout is
        // Light's near-black ink on paper that stays light.
        let paper = try bitmap(of: page)
        let total = paper.pixelsWide * paper.pixelsHigh
        let dark = count(in: paper, page: page) { $0.alphaComponent > 0.5 && Self.luminance($0) < 0.4 }
        let light = count(in: paper, page: page) { $0.alphaComponent > 0.5 && Self.luminance($0) > 0.9 }
        XCTAssertGreaterThan(Double(dark) / Double(max(1, total)), 0.01, "dark ink on the page: \(dark) of \(total) pixels")
        XCTAssertGreaterThan(Double(light) / Double(max(1, total)), 0.8, "on light paper: \(light) of \(total) pixels")
    }

    /// The page declares `color-scheme: light` over the Quire head's `light dark`, so even in a dark web view a sender's
    /// text with no colour of its own takes the light scheme's ink. The printer's web view is Aqua as well; this holds the
    /// document to its own half.
    func testThePageDeclaresALightSchemeOverTheQuireHead() throws {
        let ada = EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test")
        let only = message(1, from: ada)
        let environment = try store([(only, body("<table><tr><td><p id=\"plain\">A styled body that names no colour</p></td></tr></table>"))])
        let document = PrintDocumentBuilder().document(for: try payload(environment))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.loadHTMLString(document, baseURL: nil)
        func value(_ script: String) -> String {
            var answer: String?
            webView.evaluateJavaScript("(function () { try { return String(\(script)); } catch (e) { return ''; } })()") { value, _ in
                answer = value as? String ?? ""
            }
            ListTestSupport.spin(until: { answer != nil }, timeout: 5)
            return answer ?? ""
        }
        XCTAssertTrue(ListTestSupport.spin(until: { value("document.documentElement.hasAttribute('data-ss-ready')") == "true" }, timeout: 10))
        XCTAssertEqual(value("matchMedia('(prefers-color-scheme: dark)').matches"), "true", "a dark web view")
        XCTAssertEqual(value("getComputedStyle(document.documentElement).colorScheme"), "light")
        XCTAssertEqual(value("getComputedStyle(document.querySelector('.ss-pbody').shadowRoot.getElementById('plain')).color"), "rgb(0, 0, 0)",
                       "a sender's text with no colour of its own is black")
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

    /// The budget row "Print: ⌘P to the print panel": 500 ms for a conversation of 20 messages. Measured from ⌘P to the
    /// PDF written, which is the panel's moment plus the pages laid out and saved, so an upper bound. Gated, as the other
    /// benchmarks are: `SS_PERF=1 swift test --filter PrintConversationTests/testPrintingTwentyMessagesStaysWithinBudget`.
    func testPrintingTwentyMessagesStaysWithinBudget() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to measure printing")
        }
        let people = [EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test"), EmailAddress(name: "Ben Carter", address: "ben@contoso.test"),
                      EmailAddress(name: "Carol Diaz", address: "carol@contoso.test")]
        let reply = (1...8).map { "<p>Paragraph \($0) of the reply, long enough to run over two lines on paper, as most of a thread's words do.</p>" }
            .joined()
        let messages = (1...20).map { number in
            (message(number, from: people[number % people.count], isRead: number < 20),
             body(reply + "<div class=\"ss-quote\"><p>What was said before, folded.</p></div>", quoted: true))
        }
        let reader = try reader(showing: messages)
        func printOnce() throws -> (milliseconds: Double, pages: Int) {
            let url = folder.appendingPathComponent("perf-\(UUID().uuidString).pdf")
            reader.printer.destination = .file(url)
            var finished: Bool?
            reader.printer.onFinish = { finished = $0 }
            let start = DispatchTime.now()
            reader.printConversation(nil)
            XCTAssertTrue(ListTestSupport.spin(until: { finished != nil }, timeout: 20))
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
            XCTAssertEqual(finished, true)
            return (elapsed, PDFDocument(url: url)?.pageCount ?? 0)
        }
        _ = try printOnce()  // the first print starts the web view's content process
        var times: [Double] = []
        var pages = 0
        for _ in 0..<7 {
            let run = try printOnce()
            times.append(run.milliseconds)
            pages = run.pages
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        Swift.print("SS_PERF print 20 messages (\(pages) pages): median \(String(format: "%.1f", median)) ms, max \(String(format: "%.1f", sorted.last ?? 0)) ms")
        XCTAssertGreaterThan(pages, 1)
        XCTAssertLessThan(median, 500, "⌘P to a written PDF of 20 messages")
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
            ".ss-pbody { margin-top: \(px(reader.bodyTop));",
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
