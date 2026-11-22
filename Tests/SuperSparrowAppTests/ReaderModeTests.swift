import AppKit
import PDFKit
import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Reader mode in the real reader (spec §5.59): the header's toggle and View › Reader Mode only while Settings ›
/// Experimental offers it; a switch renders the shown page's other version in place and drops the pre-rendered pages;
/// Show original and Show text for one message in one window; an evicted body's kept text at once, while its download
/// runs; print and find following the text version; the state kept across launches. Settings live in throwaway defaults,
/// stores in temporary folders; nothing reaches the network.
@MainActor
final class ReaderModeTests: XCTestCase {
    private var folder: URL!
    private var windows: [NSWindow] = []
    private var environments: [AppEnvironment] = []
    private var engines: [MailEngine] = []
    private var suites: [String] = []
    private let account = ListTestSupport.accountA
    private lazy var conversation = ConversationID(accountID: account.id, providerID: "thread-reader")
    private lazy var other = ConversationID(accountID: account.id, providerID: "thread-other")

    /// What only the HTML holds, what only the text part says, and what both say.
    private static let designOnly = "Designwordsonly"
    private static let textOnly = "Textpartwordsonly"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderMode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows = []
        for environment in environments {
            var finished = false
            Task { @MainActor in
                await environment.shutdown()
                finished = true
            }
            ListTestSupport.spin(until: { finished }, timeout: 5)
        }
        environments = []
        for engine in engines {
            var stopped = false
            Task { await engine.stopAndWait(); stopped = true }
            ListTestSupport.spin(until: { stopped }, timeout: 5)
        }
        engines = []
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixtures

    private func defaults() throws -> UserDefaults {
        let suite = "SuperSparrowAppTests.ReaderMode.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func settings(offering: Bool) throws -> AppSettings {
        let settings = AppSettings(defaults: try defaults())
        settings.offersReaderMode = offering
        return settings
    }

    private func message(_ id: String, in conversation: ConversationID? = nil, isRead: Bool = true, minutes: Double = 0) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account.id, providerID: id), conversationID: conversation ?? self.conversation, subject: "Quarterly plan",
            snippet: "Snippet of \(id)", from: EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test"),
            to: [EmailAddress(name: "Alex Morgan", address: account.email)],
            date: Date(timeIntervalSince1970: 1_700_000_000 + minutes * 60), roles: [.inbox], isRead: isRead, isStarred: false,
            hasAttachments: false
        )
    }

    /// An HTML body with a real text part, as the sanitizer stores it.
    private func designed(_ marker: String = "") -> StoredBody {
        let source = "<table><tr><td><p style=\"color:#334455\">\(Self.designOnly) \(marker) and the shared words</p></td></tr></table>"
        let message = MessageID(accountID: account.id, providerID: "x")
        let sanitized = HTMLSanitizer().sanitize(MessageBody(html: source, text: nil), messageID: message)
        return StoredBody(body: MessageBody(html: source, text: "\(Self.textOnly) \(marker) and the shared words"),
                          renderedHTML: sanitized.html, plainText: sanitized.plainText, hasQuotedContent: sanitized.hasQuotedContent,
                          blockedRemoteImageCount: sanitized.blockedRemoteImageCount, typesetting: sanitized.typesetting,
                          declaresColors: sanitized.declaresColors, coveredByNewYork: sanitized.coveredByNewYork)
    }

    private func environment(_ messages: [(MessageMetadata, StoredBody?)]) throws -> AppEnvironment {
        let environment = try AppEnvironment.makeScratch(in: folder.appendingPathComponent("env-\(UUID().uuidString)"))
        environments.append(environment)
        try environment.store.upsertAccount(account)
        try environment.store.upsertMessages(messages.map(\.0))
        for (message, body) in messages { if let body { try environment.store.saveBody(body, for: message.id) } }
        return environment
    }

    /// A reader on `client` in a window off screen, showing `conversation` once rendered.
    private func reader(_ client: MailClient, settings: AppSettings, poolSize: Int = 3,
                        showing conversation: ConversationID? = nil) -> ConversationViewController {
        let reader = ConversationViewController(client: client, poolSize: poolSize, settings: settings)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 840, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = reader
        window.setContentSize(NSSize(width: 840, height: 900))
        window.orderFrontRegardless()
        windows.append(window)
        show(conversation ?? self.conversation, in: reader)
        return reader
    }

    private func show(_ id: ConversationID, in reader: ConversationViewController) {
        reader.show(id)
        XCTAssertTrue(landed(id, in: reader), "the conversation rendered")
    }

    private func landed(_ id: ConversationID, in reader: ConversationViewController, timeout: TimeInterval = 10) -> Bool {
        ListTestSupport.spin(until: {
            guard let slot = reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == id
        }, timeout: timeout)
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

    private func waitFor(_ script: String, toBe expected: String, in reader: ConversationViewController, timeout: TimeInterval = 5) -> Bool {
        ListTestSupport.spin(until: { self.evaluate(script, in: reader) == expected }, timeout: timeout)
    }

    /// The words of the card's line, “Text version” and the like, card by card ('' for a card without one).
    private let lines = "Array.prototype.map.call(document.querySelectorAll('.ss-card'), function (c) { var b = c.querySelector('.ss-banner.ss-reader .ss-btxt'); return b ? b.textContent : ''; }).join(' | ')"

    /// The text of every loaded body frame, in card order, its style sheets left out.
    private let frames = "Array.prototype.map.call(document.querySelectorAll('.ss-card iframe'), function (f) { var d = f.contentDocument; "
        + "if (!d || !d.body) { return ''; } var c = d.body.cloneNode(true); Array.prototype.forEach.call(c.querySelectorAll('style'), "
        + "function (s) { s.remove(); }); return c.textContent; }).join(' | ')"

    // MARK: Controls

    /// The header's toggle is there only while the experiment is offered, draws reader mode's state and flips it; the gate
    /// closing takes it away.
    func testTheHeaderOffersTheToggleOnlyWithTheGate() throws {
        let settings = try settings(offering: false)
        let environment = try environment([(message("m1"), designed())])
        let reader = reader(environment.engine, settings: settings)
        XCTAssertEqual(reader.header.content.actions.view, [], "no toggle while the experiment is off")
        XCTAssertNil(reader.header.button(for: .readerMode))

        settings.offersReaderMode = true
        XCTAssertEqual(reader.header.content.actions.view, [.readerMode])
        let button = try XCTUnwrap(reader.header.button(for: .readerMode))
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.isOn, "the gate turned reader mode on with it")
        XCTAssertEqual(button.toolTip, "Reader Mode  ⇧⌘R")
        XCTAssertEqual(button.accessibilitySubrole(), .toggle, "VoiceOver hears a switch")
        let star = try XCTUnwrap(reader.header.button(for: .star))
        XCTAssertLessThan(button.frame.maxX, star.frame.minX - Quire.Layout.ReaderHeader.actionGroupGap + 1,
                          "a group of its own before Star")

        button.performClick(nil)
        XCTAssertFalse(settings.readerModeOn, "the toggle flips reader mode")
        XCTAssertFalse(button.isOn)
        reader.show(nil)
        button.performClick(nil)
        XCTAssertTrue(settings.readerModeOn, "global: it answers with nothing selected")

        settings.offersReaderMode = false
        XCTAssertEqual(reader.header.content.actions.view, [])
        XCTAssertTrue(button.isHidden, "the gate closing takes it away")
        XCTAssertFalse(settings.readerModeOn)
    }

    /// View › Reader Mode, ⇧⌘R: listed and enabled only while the experiment is offered, checked while reader mode is on,
    /// and the same command in a reader window. The Keyboard Shortcuts sheet lists it in View while its key works.
    func testTheMenuItemAndTheSheetFollowTheGate() throws {
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let view = try XCTUnwrap(bar.items.first { $0.title == "View" }?.submenu)
        let item = try XCTUnwrap(view.items.first { $0.action == #selector(MainWindowController.toggleReaderMode(_:)) })
        XCTAssertEqual(item.title, "Reader Mode")
        XCTAssertEqual(item.keyEquivalent, "r")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertFalse(item.allowsKeyEquivalentWhenHidden, "hidden, its key does nothing")
        let titles = view.items.map(\.title)
        let originalColors = try XCTUnwrap(titles.firstIndex(of: "Original Colors"))
        XCTAssertEqual(titles.firstIndex(of: "Reader Mode"), originalColors + 1, "next to Load Images and Original Colors")

        let settings = try settings(offering: false)
        let menus = try XCTUnwrap(MainMenuController.shared)
        menus.readerModeSettings = settings
        XCTAssertTrue(item.isHidden)
        settings.offersReaderMode = true
        XCTAssertFalse(item.isHidden, "listed the moment the gate opens")

        let harness = try MainWindowHarness(settings: settings)
        defer { harness.close() }
        XCTAssertTrue(harness.controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        harness.controller.toggleReaderMode(item)
        XCTAssertFalse(settings.readerModeOn)
        XCTAssertTrue(harness.controller.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        settings.offersReaderMode = false
        XCTAssertTrue(item.isHidden)
        XCTAssertFalse(harness.controller.validateMenuItem(item), "never while the experiment is off")
        harness.controller.toggleReaderMode(item)
        XCTAssertFalse(settings.readerModeOn, "the command does nothing without the gate")
        menus.readerModeSettings = .shared

        XCTAssertEqual(CheatSheetController.sections(offeringReaderMode: false), Quire.cheatSheet)
        let offered = CheatSheetController.sections(offeringReaderMode: true)
        let viewRows = try XCTUnwrap(offered.first { $0.title == "View" }?.rows)
        let images = try XCTUnwrap(viewRows.firstIndex { $0.keys == "⇧⌘I ⇧⌘O" })
        XCTAssertEqual(viewRows[images + 1], QuireCheatSheetRow(keys: "⇧⌘R", label: "Reader mode"))
        XCTAssertEqual(offered.map(\.rows.count).reduce(0, +), Quire.cheatSheet.map(\.rows.count).reduce(0, +) + 1)
    }

    /// While the quick reply is typed in, ⇧⌘R is still its Open in Composer (§6): the bar takes the key before the menu's
    /// Reader Mode can.
    func testTheQuickReplyKeepsShiftCommandR() throws {
        let settings = try settings(offering: true)
        let harness = try MainWindowHarness(settings: settings)
        defer {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            harness.close()
        }
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentConversationID == id }
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        harness.reader.quickReplyBar.text = "Tuesday works"
        let window = try XCTUnwrap(harness.controller.window)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "R",
                                                   charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "the bar takes the key")
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.first?.bodyText, "Tuesday works", "the reply moved to a composer")
        XCTAssertTrue(settings.readerModeOn, "reader mode is left as it was")
    }

    // MARK: Rendering

    /// Turning reader mode on sets the page on screen again in place, each body's frame now holding its text version
    /// under its line; the pre-rendered page goes, since it holds the other version; turning it off brings the design back.
    func testASwitchRendersTheOtherVersionInPlaceAndDropsThePrerenderedPages() throws {
        let settings = try settings(offering: false)
        let environment = try environment([(message("m1"), designed()), (message("o1", in: other), designed("other"))])
        let reader = reader(environment.engine, settings: settings)
        XCTAssertTrue(waitFor(frames, toBe: "\(Self.designOnly)  and the shared words", in: reader), evaluate(frames, in: reader))
        XCTAssertEqual(evaluate(lines, in: reader), "")
        reader.prerender([other])
        XCTAssertTrue(ListTestSupport.spin(until: { reader.pool.slot(rendering: self.other).map { !$0.renderInFlight } ?? false }, timeout: 5))
        let shown = try XCTUnwrap(reader.pool.current)

        settings.offersReaderMode = true
        XCTAssertNil(reader.pool.slot(rendering: other), "the pre-rendered page held the design: it goes")
        XCTAssertTrue(reader.pool.current === shown, "the same page, set again in place")
        XCTAssertTrue(landed(conversation, in: reader))
        XCTAssertEqual(shown.renderedInputs?.readerMode, [])
        XCTAssertTrue(waitFor(frames, toBe: "\(Self.textOnly)  and the shared words", in: reader), evaluate(frames, in: reader))
        XCTAssertEqual(evaluate(lines, in: reader), "Text version")
        XCTAssertEqual(evaluate("document.querySelector('.ss-card').dataset.typesetting", in: reader), "plain")

        // A neighbour pre-rendered now is rendered in reader mode.
        reader.prerender([other])
        XCTAssertTrue(ListTestSupport.spin(until: { reader.pool.slot(rendering: self.other).map { !$0.renderInFlight } ?? false }, timeout: 5))
        XCTAssertEqual(reader.pool.slot(rendering: other)?.renderedInputs?.readerMode, [])

        settings.readerModeOn = false
        XCTAssertNil(reader.pool.slot(rendering: other))
        XCTAssertTrue(waitFor(frames, toBe: "\(Self.designOnly)  and the shared words", in: reader), evaluate(frames, in: reader))
        XCTAssertEqual(evaluate(lines, in: reader), "")
        XCTAssertNil(shown.renderedInputs?.readerMode)
    }

    /// Show original shows that one message as sent, in this window, for the session; Show text takes it back. Another
    /// window's reader keeps the text version.
    func testShowOriginalAndShowTextActOnOneMessageInOneWindow() throws {
        let settings = try settings(offering: true)
        let first = message("m1", isRead: false, minutes: 0)
        let second = message("m2", isRead: false, minutes: 5)
        let environment = try environment([(first, designed("one")), (second, designed("two"))])
        let reader = reader(environment.engine, settings: settings)
        XCTAssertTrue(waitFor(lines, toBe: "Text version | Text version", in: reader), evaluate(lines, in: reader))

        _ = evaluate("document.querySelectorAll('.ss-reader-switch')[0].click()", in: reader)
        XCTAssertTrue(waitFor(lines, toBe: "Original | Text version", in: reader), evaluate(lines, in: reader))
        XCTAssertTrue(reader.showsReaderOriginal(first.id))
        XCTAssertTrue(waitFor(frames, toBe: "\(Self.designOnly) one and the shared words | \(Self.textOnly) two and the shared words", in: reader),
                      evaluate(frames, in: reader))
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-reader-switch')[0].textContent", in: reader), "Show text")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-card iframe').length", in: reader), "2", "the cards kept as they were")

        // A reader window keeps its own choices.
        let window = self.reader(environment.engine, settings: settings, poolSize: 1)
        XCTAssertTrue(waitFor(lines, toBe: "Text version | Text version", in: window), evaluate(lines, in: window))
        XCTAssertFalse(window.showsReaderOriginal(first.id))

        // The choice outlives the conversation and reader mode going off and on again.
        show(other, in: reader)
        show(conversation, in: reader)
        XCTAssertTrue(waitFor(lines, toBe: "Original | Text version", in: reader), evaluate(lines, in: reader))
        settings.readerModeOn = false
        XCTAssertTrue(waitFor(lines, toBe: " | ", in: reader) || waitFor(lines, toBe: "", in: reader))
        settings.readerModeOn = true
        XCTAssertTrue(waitFor(lines, toBe: "Original | Text version", in: reader), evaluate(lines, in: reader))

        _ = evaluate("document.querySelectorAll('.ss-reader-switch')[0].click()", in: reader)
        XCTAssertTrue(waitFor(lines, toBe: "Text version | Text version", in: reader), evaluate(lines, in: reader))
        XCTAssertFalse(reader.showsReaderOriginal(first.id))
    }

    /// Keep mail on this Mac evicted the body: reader mode needs no HTML, so its kept text shows in the first render, while
    /// the download that brings the rest back runs; once the body lands, the card shows it without a reload of the page.
    func testAnEvictedBodyShowsItsKeptTextWithoutWaiting() throws {
        let store = try SQLiteMailStore(path: folder.appendingPathComponent("mail.sqlite").path)
        try store.upsertAccount(account)
        let old = message("old", minutes: -2_000_000)
        try store.upsertMessages([old])
        try store.saveBody(designed("kept"), for: old.id)
        XCTAssertEqual(try store.evictBodies(receivedBefore: Date(timeIntervalSince1970: 1_600_000_000 + 1), excluding: [], limit: 10), 1)
        XCTAssertNil(try store.body(for: old.id))
        let provider = QueuedServerProvider(accountID: account.id, kind: .gmail, latency: 0, serverConcurrency: 4, bodyKilobytes: 1)
        provider.hold([old.id.providerID])
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        engines.append(engine)
        let settings = try settings(offering: true)
        let reader = reader(engine, settings: settings)
        XCTAssertTrue(waitFor(frames, toBe: "\(Self.designOnly) kept and the shared words", in: reader), evaluate(frames, in: reader))
        XCTAssertEqual(evaluate(lines, in: reader), "Text from the email’s design", "the kept text was taken from the design")
        XCTAssertTrue(ListTestSupport.spin(until: { provider.call(for: old.id.providerID) != nil }, timeout: 5), "the download runs as ever")
        XCTAssertEqual(reader.bodyState(of: old.id), .loading)
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-skels').length", in: reader), "0", "no skeleton: the text is the body")

        provider.release(old.id.providerID)
        XCTAssertTrue(waitFor("document.querySelector('.ss-card iframe').contentDocument.body.textContent.indexOf('old') >= 0 ? 'landed' : ''",
                              toBe: "landed", in: reader, timeout: 10), evaluate(frames, in: reader))
        XCTAssertNil(reader.bodyState(of: old.id))
        XCTAssertEqual(evaluate(lines, in: reader), "Text from the email’s design", "the downloaded body is HTML alone")
    }

    /// Print prints what the reader shows: the text version, not the design.
    func testPrintPrintsTheTextVersion() throws {
        let settings = try settings(offering: true)
        let environment = try environment([(message("m1"), designed())])
        let reader = reader(environment.engine, settings: settings)
        let url = folder.appendingPathComponent("print.pdf")
        reader.printer.destination = .file(url)
        var finished: Bool?
        reader.printer.onFinish = { finished = $0 }
        reader.printConversation(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { finished != nil }, timeout: 20), "the print ran")
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        XCTAssertTrue(text.contains(Self.textOnly), text)
        XCTAssertFalse(text.contains(Self.designOnly), "the design's words are not printed")
    }

    /// Find in conversation searches the text version the page shows.
    func testFindSearchesTheTextVersion() throws {
        let settings = try settings(offering: true)
        let environment = try environment([(message("m1"), designed())])
        let reader = reader(environment.engine, settings: settings)
        XCTAssertTrue(waitFor(lines, toBe: "Text version", in: reader))
        reader.find.open(query: Self.textOnly)
        XCTAssertTrue(ListTestSupport.spin(until: { reader.find.result?.count == 1 }, timeout: 5), "found in the text version")
        reader.find.open(query: Self.designOnly)
        XCTAssertTrue(ListTestSupport.spin(until: { reader.find.result?.query == Self.designOnly }, timeout: 5))
        XCTAssertEqual(reader.find.result?.count, 0, "the design is not on the page")
    }

    // MARK: State

    /// Reader mode is kept across launches while the experiment is offered, and never comes back on without it.
    func testTheStateIsKeptAcrossLaunches() throws {
        let store = try defaults()
        let first = AppSettings(defaults: store)
        first.offersReaderMode = true
        first.readerModeOn = false
        XCTAssertFalse(AppSettings(defaults: store).readerModeOn, "switched off in the reader, off at the next launch")
        first.readerModeOn = true
        let second = AppSettings(defaults: store)
        XCTAssertTrue(second.offersReaderMode)
        XCTAssertTrue(second.readerModeOn, "on at the next launch")
        store.set(false, forKey: "experimental.readerMode")
        XCTAssertFalse(AppSettings(defaults: store).readerModeOn, "never on without the gate, whatever was saved")
    }
}
