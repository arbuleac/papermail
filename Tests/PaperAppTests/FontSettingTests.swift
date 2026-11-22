import AppKit
import PaperCore
import PaperDesign
import WebKit
import XCTest
@testable import PaperApp

/// Settings › General › Font (spec §4.4): a switch re-sets every New York surface on screen at once and in
/// place, the masthead, the visible rows, the reader's headline, an open composer's subject and the reader's
/// pooled shells, with no reload and no change of metrics. The choice is set explicitly on throwaway settings
/// and given back to New York afterwards, so nothing depends on, or writes to, the developer's saved choice;
/// the draft store points at a temporary folder.
@MainActor
final class FontSettingTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperFont-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            QuireEnvironment.shared.setTypeface(.newYork)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            QuireEnvironment.shared.setTypeface(.newYork)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func isNewYork(_ font: NSFont?) -> Bool {
        font?.fontName.localizedCaseInsensitiveContains("NewYork") ?? false
    }

    private func font(of string: NSAttributedString) -> NSFont? {
        string.length > 0 ? string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
    }

    /// The first visible conversation row: its row index, its cell and its summary.
    private func firstConversationRow(_ list: MessageListViewController) -> (row: Int, cell: ConversationCellView, summary: ConversationSummary)? {
        var found: (Int, ConversationCellView, ConversationSummary)?
        list.tableView.enumerateAvailableRowViews { rowView, row in
            guard found == nil, let cell = rowView.view(atColumn: 0) as? ConversationCellView, cell.content != nil,
                  let index = list.layout.conversationIndex(atRow: row), list.conversations.indices.contains(index) else { return }
            let summary = list.conversations[index]
            guard !summary.subject.isEmpty else { return }
            found = (row, cell, summary)
        }
        return found
    }

    /// Whether every ready shell in the pool carries `html.ss-sf`, asked of the web views themselves.
    private func shellsUseSans(_ reader: ConversationViewController) -> [Bool] {
        let views = reader.pool.slots.filter(\.isReady).map(\.webView)
        var answers: [Bool?] = Array(repeating: nil, count: views.count)
        for (index, webView) in views.enumerated() {
            webView.evaluateJavaScript("document.documentElement.classList.contains('ss-sf')") { value, _ in
                answers[index] = value as? Bool
            }
        }
        ListTestSupport.spin(until: { answers.allSatisfy { $0 != nil } }, timeout: 5)
        return answers.map { $0 ?? false }
    }

    func testAFontSwitchResetsEverySurfaceLiveWithoutMovingAnything() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        // Throwaway defaults: the choice is saved there, never in the app's own domain.
        let suite = "PaperAppTests.Font.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: defaults).typeface, .newYork, "a fresh domain starts on New York")
        // A saved choice that differs from what Quire draws, so a push from building settings would show.
        defaults.set("sfPro", forKey: "readingFont")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.typeface, .sfPro, "the saved choice is read under the old key")
        XCTAssertEqual(QuireEnvironment.typeface, .newYork, "building settings does not touch what Quire draws")
        settings.typeface = .newYork
        XCTAssertEqual(QuireEnvironment.typeface, .newYork)

        // A conversation in the reader, rendered, with its neighbours pre-rendered into the pool.
        harness.selectFirst(1)
        var landed: WKWebView??
        harness.controller.whenReaderSettles(timeout: 10) { landed = .some($0) }
        harness.spin(until: { landed != nil })
        XCTAssertNotNil(landed ?? nil, "the reader rendered the conversation")
        let composer = ComposeWindowController(client: harness.environment.engine, account: ListTestSupport.accountA,
                                               accounts: [ListTestSupport.accountA, ListTestSupport.accountB], mode: .new)
        composer.window?.contentView?.layoutSubtreeIfNeeded()
        let window = try XCTUnwrap(harness.controller.window)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let header = harness.controller.listPane.header
        let masthead = header.masthead
        let readerHeader = harness.reader.header
        let list = harness.list
        let before = try XCTUnwrap(firstConversationRow(list))
        let rowRect = list.tableView.rect(ofRow: before.row)
        let rowCount = list.tableView.numberOfRows
        let mastheadHeight = masthead.intrinsicContentSize.height
        let readerHeaderFrame = readerHeader.frame

        XCTAssertTrue(isNewYork(font(of: masthead.titleString)))
        XCTAssertTrue(isNewYork(before.cell.content.map(\.subject).flatMap(font(of:))))
        XCTAssertTrue(isNewYork(font(of: readerHeader.headlineString)))
        XCTAssertTrue(isNewYork(composer.subjectFont))
        XCTAssertTrue(shellsUseSans(harness.reader).allSatisfy { !$0 })

        for typeface in [QuireFont.Typeface.sfPro, .newYork, .sfPro] {
            settings.typeface = typeface
            XCTAssertEqual(defaults.string(forKey: "readingFont"), typeface.rawValue, "saved under the old key and raw values")
            XCTAssertEqual(QuireEnvironment.typeface, typeface, "pushed into Quire at once")
            ListTestSupport.spin(for: 0.05)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let serif = typeface == .newYork

            // The masthead: re-set, same line height.
            let mastheadFont = font(of: masthead.titleString)
            XCTAssertEqual(isNewYork(mastheadFont), serif, "\(typeface): masthead")
            XCTAssertTrue(mastheadFont === QuireFont.font(serif ? .masthead : .mastheadSans))
            XCTAssertEqual(masthead.intrinsicContentSize.height, mastheadHeight)

            // The visible row: the same cell, reconfigured in place, not reloaded, at the same height.
            let after = try XCTUnwrap(firstConversationRow(list))
            XCTAssertEqual(after.row, before.row)
            XCTAssertTrue(after.cell === before.cell, "\(typeface): the row was reconfigured, not reloaded")
            let subject = after.cell.content.map(\.subject).flatMap(font(of:))
            XCTAssertEqual(isNewYork(subject), serif, "\(typeface): row subject")
            XCTAssertTrue(subject === QuireFont.font(serif ? .subject : .subjectSans, unread: after.cell.content?.isUnread ?? false),
                          "\(typeface): the unread weight is kept")
            XCTAssertEqual(list.tableView.rect(ofRow: before.row), rowRect, "\(typeface): row metrics never change")
            XCTAssertEqual(list.tableView.numberOfRows, rowCount)

            // The reader's headline and the composer's subject field.
            let headline = font(of: readerHeader.headlineString)
            XCTAssertEqual(isNewYork(headline), serif, "\(typeface): reader headline")
            XCTAssertTrue(headline === QuireFont.font(serif ? .headline : .headlineSans))
            XCTAssertEqual(readerHeader.frame, readerHeaderFrame)
            XCTAssertEqual(isNewYork(composer.subjectFont), serif, "\(typeface): composer subject")
            XCTAssertTrue(composer.subjectFont === QuireFont.font(serif ? .composeSubject : .composeSubjectSans))

            // Every ready shell, the pre-rendered ones too, was told.
            let shells = shellsUseSans(harness.reader)
            XCTAssertFalse(shells.isEmpty)
            XCTAssertEqual(shells, Array(repeating: !serif, count: shells.count), "\(typeface): reader shells")
        }
        composer.closeWithoutSaving()
    }

    /// A shell still loading its page when the face switches misses the broadcast and later replays a payload
    /// built before the switch; the pool then tells it the current preferences, so it shows the new face.
    func testAShellStillLoadingDuringASwitchShowsTheNewFace() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let reader = ConversationViewController(client: harness.environment.engine)
        _ = reader.view
        let id = try XCTUnwrap(harness.list.conversations.first?.id)
        reader.show(id)
        let slot = try XCTUnwrap(reader.pool.current)
        guard !slot.isReady, let pending = slot.pendingRender else {
            throw XCTSkip("the shell was ready before the switch could be made")
        }
        XCTAssertFalse(pending.payload.readingSans, "queued in New York")

        QuireEnvironment.shared.setTypeface(.sfPro)
        ListTestSupport.spin(until: { slot.isReady && slot.pendingRender == nil && !slot.renderInFlight }, timeout: 10)
        XCTAssertTrue(slot.isReady)
        XCTAssertEqual(slot.renderedID, id, "the queued conversation was rendered")
        var sans: Bool?
        slot.webView.evaluateJavaScript("document.documentElement.classList.contains('ss-sf')") { value, _ in
            sans = value as? Bool
        }
        ListTestSupport.spin(until: { sans != nil }, timeout: 5)
        XCTAssertEqual(sans, true, "the replayed payload's New York did not win over the switch")
    }

    /// `--font` forces the face for one process; it is a launch option, not a setting, so nothing is saved.
    func testTheFontLaunchOptionNamesAFace() {
        XCTAssertNil(LaunchOptions(arguments: ["Paper"]).typeface)
        #if DEBUG
        XCTAssertEqual(LaunchOptions(arguments: ["Paper", "--font=sf"]).typeface, .sfPro)
        XCTAssertEqual(LaunchOptions(arguments: ["Paper", "--font=newyork"]).typeface, .newYork)
        XCTAssertEqual(LaunchOptions(arguments: ["Paper", "--demo", "--font=SF"]).typeface, .sfPro)
        XCTAssertNil(LaunchOptions(arguments: ["Paper", "--font=serif"]).typeface)
        XCTAssertNil(LaunchOptions(arguments: ["Paper", "--font="]).typeface)
        #endif
        XCTAssertEqual(QuireEnvironment.typeface, .newYork, "parsing applies nothing")
    }
}
