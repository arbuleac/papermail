import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// A mail link from another app (`mailto:`, spec §5.20, roadmap Q1.3) opens one new composer filled from the link,
/// from the account in scope or the first in rail order; one that launches the app waits for the main window; with
/// no account nothing opens. Nothing is ever sent. Drafts go to a temporary folder, and the windows are a throwaway
/// store's: no test opens the app's real store, LaunchServices or the network.
@MainActor
final class MailLinkTests: XCTestCase {
    private var folder: URL!
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperMailLink-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var lunch: URL {
        URL(string: "mailto:ben@contoso.test,ana@contoso.test?cc=priya@contoso.test&bcc=me@contoso.test&subject=Lunch%3F"
            + "&body=Noon%0D%0AThe%20usual%20place&attach=%2Fetc%2Fhosts")!
    }

    private var composers: [ComposeWindowController] { ComposeWindowRegistry.shared.openControllers }

    private func assertFilledFromLunch(_ composer: ComposeWindowController, file: StaticString = #filePath, line: UInt = #line) {
        let contents = composer.contents
        XCTAssertEqual(composer.mode, .new, "a new message, never a reply", file: file, line: line)
        XCTAssertEqual(contents.to.map(\.address), ["ben@contoso.test", "ana@contoso.test"], file: file, line: line)
        XCTAssertEqual(contents.cc.map(\.address), ["priya@contoso.test"], file: file, line: line)
        XCTAssertEqual(contents.bcc.map(\.address), ["me@contoso.test"], file: file, line: line)
        XCTAssertEqual(contents.subject, "Lunch?", file: file, line: line)
        XCTAssertEqual(composer.bodyText, "Noon\nThe usual place", "the body as plain text", file: file, line: line)
        MainWindowHarness.assertWritingStyle(contents.body, file: file, line: line)
        XCTAssertTrue(contents.attachments.isEmpty, "attach= is ignored", file: file, line: line)
        XCTAssertEqual(composer.window?.title, "Lunch?", file: file, line: line)
    }

    // MARK: The main window

    func testTheBodyIsInTheWritingStyleLikeTextTypedAfterIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try XCTUnwrap(harness.controller.openMailLink(try XCTUnwrap(MailtoLink(url: lunch))))
        let editor = try XCTUnwrap(composer.window?.firstResponder as? NSTextView)
        editor.insertText(" Thanks!", replacementRange: editor.selectedRange())
        XCTAssertEqual(composer.bodyText, "Noon\nThe usual place Thanks!")
        MainWindowHarness.assertWritingStyle(composer.contents.body)
    }

    func testAMailLinkOpensOneComposerFromTheFirstAccountInRailOrder() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        XCTAssertEqual(harness.controller.strip.scope, .unified)
        let link = try XCTUnwrap(MailtoLink(url: lunch))

        let composer = try XCTUnwrap(harness.controller.openMailLink(link))
        XCTAssertEqual(composers.count, 1)
        XCTAssertTrue(composers.first === composer)
        XCTAssertEqual(composer.accountID, a.id, "All Inboxes: the first account in rail order")
        assertFilledFromLunch(composer)
        XCTAssertTrue(try harness.environment.store.pendingSends().isEmpty, "nothing is sent")
        for account in [a, b] {
            XCTAssertTrue(try harness.environment.store.pendingOperations(accountID: account.id, limit: 10).isEmpty, "nor queued")
        }
    }

    func testAScopedWindowComposesFromItsAccount() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.strip.select(.account(b.id), notify: true)
        XCTAssertEqual(harness.controller.strip.scope, .account(b.id))

        let composer = try XCTUnwrap(harness.controller.openMailLink(MailtoLink(to: [EmailAddress(address: "ben@contoso.test")])))
        XCTAssertEqual(composer.accountID, b.id, "the account the window is scoped to")
    }

    func testWithNoAccountTheWelcomeComesForwardAndNothingOpens() throws {
        let harness = try MainWindowHarness(accounts: false)
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        XCTAssertFalse(window.isVisible)

        XCTAssertNil(harness.controller.openMailLink(try XCTUnwrap(MailtoLink(url: lunch))))
        XCTAssertTrue(composers.isEmpty, "no composer without an account")
        XCTAssertTrue(window.isVisible, "the app comes forward")
        XCTAssertTrue(window.contentViewController is WelcomeViewController, "on the welcome screen")
    }

    func testClosingAnUntouchedMailLinkComposerKeepsNoDraft() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let untouched = try XCTUnwrap(harness.controller.openMailLink(try XCTUnwrap(MailtoLink(url: lunch))))
        let untouchedID = untouched.draftID
        try XCTUnwrap(untouched.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: untouchedID), "what the link filled in is not the user's work")

        // A word typed into the body is.
        let typed = try XCTUnwrap(harness.controller.openMailLink(try XCTUnwrap(MailtoLink(url: lunch))))
        let editor = try XCTUnwrap(typed.window?.firstResponder as? NSTextView, "focus is in the body, To and Subject being filled")
        XCTAssertEqual(editor.selectedRange().location, (typed.bodyText as NSString).length, "the caret at the end of the body")
        editor.insertText(" Thanks!", replacementRange: editor.selectedRange())
        let typedID = typed.draftID
        try XCTUnwrap(typed.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: typedID))
    }

    func testFocusGoesToTheFirstFieldTheLinkLeftEmpty() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        // The body's text view is the composer's own delegate; a field's editor answers to its field.
        let noSubject = try XCTUnwrap(harness.controller.openMailLink(MailtoLink(to: [EmailAddress(address: "ben@contoso.test")])))
        let subjectEditor = try XCTUnwrap(noSubject.window?.firstResponder as? NSTextView)
        XCTAssertTrue(subjectEditor.isFieldEditor, "To is filled, so Subject")
        XCTAssertFalse(subjectEditor.delegate === noSubject)
        XCTAssertEqual((subjectEditor.delegate as? NSTextField)?.stringValue, "", "the empty Subject field")
        noSubject.closeWithoutSaving()

        let full = try XCTUnwrap(harness.controller.openMailLink(MailtoLink(to: [EmailAddress(address: "ben@contoso.test")], subject: "Hi")))
        XCTAssertTrue((full.window?.firstResponder as? NSTextView)?.delegate === full, "To and Subject filled: the body")
        full.closeWithoutSaving()
    }

    // MARK: The app delegate

    /// A link that launches the app reaches the delegate before the main window exists: it is held, then opened in
    /// one composer once the window is there, and later links open at once. Anything else handed over is dropped.
    func testALinkThatArrivesBeforeTheWindowWaitsForIt() throws {
        let delegate = AppDelegate(options: LaunchOptions(arguments: ["Paper"]))
        delegate.application(NSApplication.shared, open: [lunch, URL(string: "https://example.com")!, URL(fileURLWithPath: "/tmp/notes.txt")])
        XCTAssertEqual(delegate.mailLinks.pending, [try XCTUnwrap(MailtoLink(url: lunch))], "held, and only the mail link")
        XCTAssertTrue(composers.isEmpty, "nothing opens before the window")

        // What `install` does once the main window is on screen.
        let harness = try MainWindowHarness()
        defer { harness.close() }
        delegate.openMailLinks(in: harness.controller)
        XCTAssertTrue(delegate.mailLinks.pending.isEmpty)
        XCTAssertEqual(composers.count, 1, "one composer for one link")
        assertFilledFromLunch(try XCTUnwrap(composers.first))
        XCTAssertEqual(composers.first?.accountID, a.id)

        delegate.application(NSApplication.shared, open: [URL(string: "mailto:ana@contoso.test")!])
        XCTAssertEqual(composers.count, 2, "once the window is there a link opens at once")
        XCTAssertTrue(delegate.mailLinks.pending.isEmpty)
    }

    func testHeldLinksOpenInTheOrderTheyCame() throws {
        let inbox = MailLinkInbox()
        inbox.receive([URL(string: "mailto:one@an.example")!])
        inbox.receive([URL(string: "mailto:two@an.example")!, URL(string: "mailto:three@an.example")!])
        var opened: [String] = []
        inbox.receiver = { opened.append(contentsOf: $0.to.map(\.address)) }
        XCTAssertEqual(opened, ["one@an.example", "two@an.example", "three@an.example"])
        inbox.receiver = { _ in XCTFail("each link opens once") }
        XCTAssertTrue(inbox.pending.isEmpty)
    }
}
