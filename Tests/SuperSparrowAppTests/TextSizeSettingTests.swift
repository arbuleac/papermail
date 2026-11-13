import AppKit
import SSCore
import SSDesign
import SwiftUI
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Settings › General › Text size (spec §4.15, roadmap Q2.6): the setting is saved and pushed into Quire; a switch
/// re-measures the list's rows live with the selection kept, re-sets the reader (its pooled shells, its headline),
/// the quick reply and an open composer mid-edit; ⌘+ and ⌘− step the reader alone; Settings stays at Default and
/// General never scrolls. Settings live in throwaway defaults suites, the environment is given back to Default, and
/// the draft store points at a temporary folder.
@MainActor
final class TextSizeSettingTests: XCTestCase {
    private var folder: URL!
    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowTextSize-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            QuireEnvironment.shared.setTextSize(.default)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            QuireEnvironment.shared.setTextSize(.default)
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let suite = "SuperSparrowAppTests.TextSize.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func font(of string: NSAttributedString?) -> NSFont? {
        guard let string, string.length > 0 else { return nil }
        return string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    // MARK: The setting

    func testTheSettingIsSavedPushedIntoQuireAndSetsTheReaderToo() throws {
        let defaults = try defaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.textSize, .default, "a fresh domain starts at Default")
        XCTAssertNil(settings.readerTextSize)
        defaults.set("large", forKey: "textSize")
        XCTAssertEqual(AppSettings(defaults: defaults).textSize, .large, "read back")
        XCTAssertEqual(QuireEnvironment.textSize, .default, "building settings does not touch what Quire draws")
        defaults.set("huge", forKey: "textSize")
        XCTAssertEqual(AppSettings(defaults: defaults).textSize, .default, "an unknown value is Default")

        for size in QuireFont.TextSize.allCases.reversed() {
            settings.textSize = size
            XCTAssertEqual(defaults.string(forKey: "textSize"), size.rawValue)
            XCTAssertEqual(QuireEnvironment.textSize, size, "pushed into Quire at once")
            XCTAssertEqual(settings.readerSize, size, "the reader follows")
        }
    }

    /// ⌘+ and ⌘−: the reader alone, one size at a time, never past Larger or Small; back at the setting's size it
    /// follows the setting again; kept across launches; a new setting sets the reader to it.
    func testTheReadersOwnSizeStepsAloneAndIsKept() throws {
        let defaults = try defaults()
        let settings = AppSettings(defaults: defaults)
        settings.textSize = .default
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: AppSettings.readerTextSizeChanged, object: settings, queue: nil) { _ in
            posts += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(settings.stepReaderTextSize(larger: true))
        XCTAssertEqual(settings.readerSize, .large)
        XCTAssertEqual(QuireEnvironment.textSize, .default, "the list, the quick reply and the composer stay")
        XCTAssertTrue(settings.stepReaderTextSize(larger: true))
        XCTAssertFalse(settings.stepReaderTextSize(larger: true), "no size past Larger")
        XCTAssertEqual(settings.readerSize, .larger)
        XCTAssertEqual(posts, 2)
        XCTAssertEqual(AppSettings(defaults: defaults).readerSize, .larger, "kept across launches")

        XCTAssertTrue(settings.stepReaderTextSize(larger: false))
        XCTAssertTrue(settings.stepReaderTextSize(larger: false))
        XCTAssertNil(settings.readerTextSize, "back at the setting's size, the reader follows the setting")
        XCTAssertNil(defaults.string(forKey: "readerTextSize"))
        XCTAssertTrue(settings.stepReaderTextSize(larger: false))
        XCTAssertFalse(settings.stepReaderTextSize(larger: false), "no size past Small")
        XCTAssertEqual(settings.readerSize, .small)

        settings.textSize = .large
        XCTAssertEqual(settings.readerSize, .large, "choosing a Text size sets the reader to it too")
        XCTAssertNil(settings.readerTextSize)
    }

    func testTheTextSizeLaunchOptionNamesASize() {
        XCTAssertNil(LaunchOptions(arguments: ["SuperSparrow"]).textSize)
        #if DEBUG
        XCTAssertEqual(LaunchOptions(arguments: ["SuperSparrow", "--text-size=larger"]).textSize, .larger)
        XCTAssertEqual(LaunchOptions(arguments: ["SuperSparrow", "--demo", "--text-size=Small"]).textSize, .small)
        XCTAssertNil(LaunchOptions(arguments: ["SuperSparrow", "--text-size=huge"]).textSize)
        XCTAssertNil(LaunchOptions(arguments: ["SuperSparrow", "--text-size="]).textSize)
        #endif
        XCTAssertEqual(QuireEnvironment.textSize, .default, "parsing applies nothing")
    }

    // MARK: Keys

    /// View › Make Text Bigger ⌘+ (⌘= too) and Make Text Smaller ⌘−, each the only item on its key, and a cheat-sheet
    /// row; ⌘0 stays All Inboxes.
    func testTheKeysAreInTheViewMenuAndTheCheatSheetAndCollideWithNothing() throws {
        let menu = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in item.submenu.map(items) ?? [item] }
        }
        let all = items(menu)
        let view = try XCTUnwrap(menu.items.first { $0.title == "View" }?.submenu)
        let bigger = view.items.filter { $0.action == #selector(MainWindowController.makeReaderTextBigger(_:)) }
        let smaller = view.items.filter { $0.action == #selector(MainWindowController.makeReaderTextSmaller(_:)) }
        XCTAssertEqual(bigger.map(\.title), ["Make Text Bigger", "Make Text Bigger"])
        XCTAssertEqual(bigger.map(\.keyEquivalent), ["+", "="])
        XCTAssertEqual(bigger.map(\.isHidden), [false, true], "⌘= answers without a second visible item")
        XCTAssertTrue(bigger[1].allowsKeyEquivalentWhenHidden)
        XCTAssertEqual(smaller.map(\.title), ["Make Text Smaller"])
        XCTAssertEqual(smaller.map(\.keyEquivalent), ["-"])
        for item in bigger + smaller { XCTAssertEqual(item.keyEquivalentModifierMask, .command) }
        for key in ["+", "=", "-"] {
            let users = all.filter { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }
            XCTAssertTrue(users.allSatisfy { bigger.contains($0) || smaller.contains($0) }, "⌘\(key) belongs to the reader's size alone")
        }
        let allInboxes = all.filter { $0.keyEquivalent == "0" && $0.keyEquivalentModifierMask == .command }
        XCTAssertEqual(allInboxes.map(\.title), ["All Inboxes"], "⌘0 stays All Inboxes, so there is no reset key")

        let rows = Quire.cheatSheet.flatMap(\.rows).filter { $0.keys == "⌘+ ⌘−" }
        XCTAssertEqual(rows.map(\.label), ["Reader text bigger · smaller"])
        XCTAssertEqual(Quire.cheatSheet.first { $0.rows.contains { $0.keys == "⌘+ ⌘−" } }?.title, "View")
    }

    // MARK: The list

    /// A switch re-measures the rows at once (64 / 68 / 72 / 76, compact 44 … 56), keeps the selection, sets the
    /// rows' text at the size and keeps the heads at their heights.
    func testASwitchReMeasuresTheListLiveKeepingTheSelection() throws {
        let settings = ListTestSupport.settings()
        let (list, window) = ListTestSupport.host(store: try ListTestSupport.store(threads: 20), settings: settings)
        list.selectNext()
        list.selectNext()
        let selected = list.selectedConversationID
        let row = try XCTUnwrap(list.layout.row(ofConversation: 1))
        window.layoutIfNeeded()
        window.displayIfNeeded()

        for compact in [false, true] {
            settings.listDensity = compact ? .compact : .standard
            for size in QuireFont.TextSize.allCases.reversed() {
                QuireEnvironment.shared.setTextSize(size)
                window.layoutIfNeeded()
                window.displayIfNeeded()
                let metrics = QuireRowMetrics(textSize: size, compact: compact)
                XCTAssertEqual(list.rowMetrics, metrics)
                XCTAssertEqual(list.tableView.rect(ofRow: row).height, metrics.height, "\(size) compact=\(compact)")
                XCTAssertEqual(list.selectedConversationID, selected, "\(size): the selection survives the switch")
                let rowView = list.tableView.rowView(atRow: row, makeIfNecessary: false) as? ConversationRowView
                XCTAssertEqual(rowView?.metrics, metrics)
                let cell = rowView?.view(atColumn: 0) as? ConversationCellView
                XCTAssertEqual(cell?.metrics, metrics)
                XCTAssertEqual(font(of: cell?.content?.sender)?.pointSize, QuireFont.Role.sender.size(at: size), "\(size): the sender")
                XCTAssertEqual(font(of: cell?.content?.snippet)?.pointSize, QuireFont.Role.snippet.size(at: size), "\(size): the snippet")
                XCTAssertEqual(font(of: cell?.content?.time)?.pointSize, QuireFont.Role.meta.size(at: size), "\(size): the time")
                if let head = list.layout.items.firstIndex(where: { if case .head = $0 { return true }; return false }) {
                    let expected = compact ? Quire.Layout.RunningHead.compactHeight : Quire.Layout.RunningHead.height
                    XCTAssertEqual(list.tableView.rect(ofRow: head).height, expected, "\(size): heads keep their height")
                }
            }
        }
        QuireEnvironment.shared.setTextSize(.default)
    }

    // MARK: The reader

    /// Whether every ready shell carries the class, asked of the web views themselves.
    private func shellClasses(_ reader: ConversationViewController) -> [String] {
        let views = reader.pool.slots.filter(\.isReady).map(\.webView)
        var answers: [String?] = Array(repeating: nil, count: views.count)
        for (index, webView) in views.enumerated() {
            webView.evaluateJavaScript("document.documentElement.className") { value, _ in answers[index] = (value as? String) ?? "" }
        }
        ListTestSupport.spin(until: { answers.allSatisfy { $0 != nil } }, timeout: 5)
        return answers.map { $0 ?? "" }
    }

    /// The setting reaches every shell and the headline; ⌘+ and ⌘− then move the reader alone, the list and the quick
    /// reply staying at the setting, and the menu items stop at Larger and Small.
    func testTheReaderFollowsTheSettingAndItsOwnKeys() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let settings = harness.settings
        harness.selectFirst(1)
        var landed: WKWebView??
        harness.controller.whenReaderSettles(timeout: 10) { landed = .some($0) }
        harness.spin(until: { landed != nil })
        XCTAssertNotNil(landed ?? nil, "the reader rendered the conversation")
        let reader = harness.reader
        let window = try XCTUnwrap(harness.controller.window)
        let headerFrame = reader.header.frame
        func shells(have size: QuireFont.TextSize) -> Bool {
            let classes = shellClasses(reader)
            guard !classes.isEmpty else { return false }
            return classes.allSatisfy { size == .default ? !$0.contains("ss-text-") : $0.contains("ss-text-" + size.rawValue) }
        }
        XCTAssertTrue(shells(have: .default))

        settings.textSize = .large
        ListTestSupport.spin(for: 0.05)
        window.layoutIfNeeded()
        XCTAssertTrue(shells(have: .large), "every ready shell, the pre-rendered ones too")
        XCTAssertEqual(font(of: reader.header.headlineString)?.pointSize, QuireFont.Role.headline.size(at: .large))
        XCTAssertEqual(reader.header.frame, headerFrame, "the band keeps its height")
        XCTAssertEqual(reader.quickReplyBar.writingFont?.pointSize, QuireFont.Role.writing.size(at: .large), "the quick reply follows the setting")

        let bigger = NSMenuItem(title: "Make Text Bigger", action: #selector(MainWindowController.makeReaderTextBigger(_:)), keyEquivalent: "+")
        let smaller = NSMenuItem(title: "Make Text Smaller", action: #selector(MainWindowController.makeReaderTextSmaller(_:)), keyEquivalent: "-")
        XCTAssertTrue(harness.controller.validateMenuItem(bigger))
        harness.controller.makeReaderTextBigger(bigger)
        ListTestSupport.spin(for: 0.05)
        XCTAssertTrue(shells(have: .larger), "⌘+ steps the reader")
        XCTAssertEqual(font(of: reader.header.headlineString)?.pointSize, QuireFont.Role.headline.size(at: .larger))
        XCTAssertEqual(QuireEnvironment.textSize, .large, "and nothing else")
        XCTAssertEqual(harness.list.rowMetrics.height, 72, "the list stays at the setting")
        XCTAssertEqual(reader.quickReplyBar.writingFont?.pointSize, QuireFont.Role.writing.size(at: .large))
        XCTAssertFalse(harness.controller.validateMenuItem(bigger), "Larger is the last size")
        XCTAssertTrue(harness.controller.validateMenuItem(smaller))

        for _ in 0..<3 { harness.controller.makeReaderTextSmaller(smaller) }
        ListTestSupport.spin(for: 0.05)
        XCTAssertTrue(shells(have: .small))
        XCTAssertFalse(harness.controller.validateMenuItem(smaller), "Small is the first size")
        XCTAssertEqual(font(of: reader.header.headlineString)?.pointSize, QuireFont.Role.headline.size(at: .small))

        settings.textSize = .default
        ListTestSupport.spin(for: 0.05)
        XCTAssertTrue(shells(have: .default), "a new setting sets the reader to it")
        XCTAssertEqual(font(of: reader.header.headlineString)?.pointSize, 24)
    }

    /// A shell still loading when the size changes replays a payload built before; the pool then tells it the
    /// current preferences, so it shows the new size.
    func testAShellStillLoadingDuringASwitchShowsTheNewSize() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let reader = ConversationViewController(client: harness.environment.engine, settings: harness.settings)
        _ = reader.view
        let id = try XCTUnwrap(harness.list.conversations.first?.id)
        reader.show(id)
        let slot = try XCTUnwrap(reader.pool.current)
        guard !slot.isReady, let pending = slot.pendingRender else {
            throw XCTSkip("the shell was ready before the switch could be made")
        }
        XCTAssertEqual(pending.payload.textSize, "default", "queued at Default")
        harness.settings.textSize = .larger
        ListTestSupport.spin(until: { slot.isReady && slot.pendingRender == nil && !slot.renderInFlight }, timeout: 10)
        XCTAssertEqual(slot.renderedID, id)
        var classes: String?
        slot.webView.evaluateJavaScript("document.documentElement.className") { value, _ in classes = value as? String }
        ListTestSupport.spin(until: { classes != nil }, timeout: 5)
        XCTAssertTrue(classes?.contains("ss-text-larger") ?? false, "the replayed payload's size did not win: \(classes ?? "")")
    }

    /// The reader's CSS steps exactly as the AppKit roles do, so a body in the reader and a row in the list move
    /// together (spec §4.15, §8.4).
    func testTheReadersCSSMatchesTheAppKitRoles() throws {
        let lines = QuireCSS.textSizes.components(separatedBy: "\n")
        for size in QuireFont.TextSize.allCases where size != .default {
            let line = try XCTUnwrap(lines.first { $0.hasPrefix("html.ss-text-\(size.rawValue){") })
            for role in QuireFont.Role.allCases where role.spec.size > 0 {
                let needle = "--q-font-\(role.rawValue):"
                guard role.step(at: size) != 0 else {
                    XCTAssertFalse(line.contains(needle), "\(role) at \(size)")
                    continue
                }
                let value = String(line[try XCTUnwrap(line.range(of: needle)).upperBound...].prefix { $0 != ";" })
                let px = "\(Int(role.size(at: size)))px/\(Int(role.lineHeight(at: size)))px"
                XCTAssertTrue(value.contains(" " + px + " "), "\(role) at \(size): \(value), want \(px)")
            }
        }
    }

    // MARK: Writing

    /// An open composer sets its subject and its body again, mid-edit: bold, links and lists keep their styles, the
    /// caret stays, nothing goes on the undo stack; its quoted original follows; back at Default all is as it was.
    func testAnOpenComposerSetsItsTextAgainMidEdit() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = ComposeWindowController(client: harness.environment.engine, account: ListTestSupport.accountA,
                                               accounts: [ListTestSupport.accountA, ListTestSupport.accountB], mode: .new)
        defer { composer.closeWithoutSaving() }
        composer.window?.contentView?.layoutSubtreeIfNeeded()
        let editor = composer.bodyEditor
        let manager = NSFontManager.shared
        let typing = ComposeTextView.defaultTypingAttributes
        let body = NSMutableAttributedString(string: "Hello", attributes: typing.merging([.font: manager.convert(ComposeTextView.bodyFont,
                                                                                                               toHaveTrait: .boldFontMask)]) { $1 })
        body.append(NSAttributedString(string: " there", attributes: typing))
        editor.replaceContents(with: body)
        XCTAssertTrue(manager.traits(of: try XCTUnwrap(editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont))
            .contains(.boldFontMask))
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        let undoable = editor.undoManager?.canUndo ?? false
        let height = editor.intrinsicContentSize.height

        func check(_ size: QuireFont.TextSize) {
            let storage = editor.attributedString()
            let line = QuireFont.Role.writing.lineHeight(at: size)
            let bold = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let plain = storage.attribute(.font, at: 8, effectiveRange: nil) as? NSFont
            XCTAssertEqual(bold?.pointSize, QuireFont.Role.writing.size(at: size), "\(size): bold text takes the size")
            XCTAssertTrue(bold.map { manager.traits(of: $0).contains(.boldFontMask) } ?? false, "\(size): and stays bold")
            XCTAssertEqual(plain?.pointSize, QuireFont.Role.writing.size(at: size), "\(size)")
            XCTAssertFalse(plain.map { manager.traits(of: $0).contains(.boldFontMask) } ?? true)
            XCTAssertEqual((storage.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight, line)
            XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize, QuireFont.Role.writing.size(at: size), "\(size): what is typed next")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 0), "\(size): the caret stays")
            XCTAssertEqual(composer.subjectFont?.pointSize, QuireFont.Role.composeSubject.size(at: size), "\(size): the subject")
            XCTAssertEqual(editor.undoManager?.canUndo ?? false, undoable, "\(size): not an edit")
        }

        for size in [QuireFont.TextSize.larger, .small, .large] {
            harness.settings.textSize = size
            check(size)
        }
        XCTAssertGreaterThan(QuireFont.Role.writing.lineHeight(at: .large), QuireFont.Role.writing.lineHeight)
        harness.settings.textSize = .default
        check(.default)
        XCTAssertEqual(editor.intrinsicContentSize.height, height, "back at Default the body measures as before")
        let sent = try XCTUnwrap(ComposeSignature.html(from: editor.attributedString()))
        XCTAssertTrue(sent.contains("Hello"))
        XCTAssertFalse(sent.contains("font") || sent.contains("px"), "what is sent never carries a size: \(sent)")
    }

    /// Text built for a composer outside one (a mail link's body, the quick reply's hand-off) is set at the
    /// composer's size; a draft archived at another size opens at the composer's.
    func testTextHandedToAComposerTakesItsSize() throws {
        QuireEnvironment.shared.setTextSize(.larger)
        let typed = ComposeTextView.plainBody("From a mail link")
        XCTAssertEqual(font(of: typed)?.pointSize, 16)
        let editor = ComposeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let archived = NSAttributedString(string: "Archived at Default", attributes: ComposeTextView.defaultTypingAttributes(at: .default))
        editor.replaceContents(with: archived)
        XCTAssertEqual(font(of: editor.attributedString())?.pointSize, 16, "the editor's size wins over the draft's")
        XCTAssertEqual((editor.attributedString().attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight, 23)
    }

    // MARK: Settings

    /// General gains one row and never scrolls: at every Text size (Settings stays at Default) it holds Text size after
    /// Font, and with every optional caption showing it fits the 760 pt the tallest tab, Accounts, is designed for.
    func testGeneralShowsTextSizeAfterFontAndNeverScrolls() throws {
        let settings = AppSettings(defaults: try defaults())
        settings.accountWasAdded(totalAccounts: 7)
        XCTAssertTrue(settings.showsSevenAccountsCaption)
        let mailtoHandler = FakeMailtoHandler()
        let model = DefaultMailAppModel(handler: mailtoHandler)
        var heights: [CGFloat] = []
        for size in QuireFont.TextSize.allCases {
            QuireEnvironment.shared.setTextSize(size)
            let general = NSHostingView(rootView: GeneralSettingsView(settings: settings, defaultMailApp: model,
                                                                      mailboxSize: MailboxSizeModel(measure: { 292_000_000 })))
            general.layoutSubtreeIfNeeded()
            heights.append(general.fittingSize.height)
        }
        QuireEnvironment.shared.setTextSize(.default)
        XCTAssertEqual(Set(heights).count, 1, "Settings stays at Default: \(heights)")
        XCTAssertLessThanOrEqual(heights[0], 760, "General never scrolls: \(heights[0]) pt")
        XCTAssertEqual(QuireFont.TextSize.allCases.map(\.title), ["Small", "Default", "Large", "Larger"], "the popup's words")
    }
}
