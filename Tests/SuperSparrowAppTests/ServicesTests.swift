import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// The Services menu's New Message with Selection and Send with SuperSparrow (spec §5.20 Services, roadmap Q2.8): what
/// each reads from the pasteboard, the new composer it opens (from the account a new message starts from, the text as
/// its body or the files attached as a drop attaches them), a request held until the main window exists, and nothing
/// opening without an account. Pasteboards are private, files are temporary, drafts go to a temporary folder and the
/// windows are a throwaway store's: no test registers a service with macOS, sends, or touches the network.
@MainActor
final class ServicesTests: XCTestCase {
    private var folder: URL!
    private var pasteboards: [NSPasteboard] = []
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowServices-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder.appendingPathComponent("Drafts")) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            for pasteboard in pasteboards { pasteboard.releaseGlobally() }
            pasteboards = []
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    private var composers: [ComposeWindowController] { ComposeWindowRegistry.shared.openControllers }

    private func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    /// Text as another app copies a selection: plain, with styled text beside it.
    private func selectionPasteboard(_ text: String) -> NSPasteboard {
        let pasteboard = privatePasteboard()
        let rtf = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let data = rtf.rtf(from: NSRange(location: 0, length: rtf.length), documentAttributes: [:])
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        pasteboard.setData(data, forType: .rtf)
        pasteboard.setString(text, forType: .string)
        return pasteboard
    }

    /// Files as Finder hands them to a service: one file URL per pasteboard item.
    private func filesPasteboard(_ urls: [URL]) -> NSPasteboard {
        let pasteboard = privatePasteboard()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return pasteboard
    }

    private func makeFile(_ name: String, bytes: Int = 1_200) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The composer's first responder is the To field's editor: a recipients field's (Cc and Bcc are hidden), not the
    /// Subject's or the body.
    private func assertFocusInTo(_ composer: ComposeWindowController, file: StaticString = #filePath, line: UInt = #line) {
        let editor = composer.window?.firstResponder as? NSTextView
        XCTAssertEqual(editor?.isFieldEditor, true, "a field has focus", file: file, line: line)
        XCTAssertTrue(editor?.delegate is TokenInputField, "To", file: file, line: line)
        XCTAssertTrue(composer.contents.cc.isEmpty && composer.contents.bcc.isEmpty, file: file, line: line)
    }

    private func assertNothingSentOrQueued(_ harness: MainWindowHarness, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try harness.environment.store.pendingSends().isEmpty, "nothing is sent", file: file, line: line)
        for account in [a, b] {
            XCTAssertTrue(try harness.environment.store.pendingOperations(accountID: account.id, limit: 10).isEmpty, "nor queued",
                          file: file, line: line)
        }
    }

    // MARK: Info.plist

    /// The two entries macOS reads, and the provider answering what each names: a renamed method would leave a menu
    /// item that does nothing.
    func testInfoPlistDeclaresBothServicesAndTheProviderAnswersThem() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        XCTAssertEqual(services.count, 2)
        let provider = MailServicesProvider()
        var titles: [String] = []
        for service in services {
            let title = try XCTUnwrap((service["NSMenuItem"] as? [String: String])?["default"])
            titles.append(title)
            XCTAssertEqual(service["NSPortName"] as? String, plist["CFBundleName"] as? String, title)
            XCTAssertNil(service["NSKeyEquivalent"], "no key: a service's key works in every app (\(title))")
            XCTAssertNotNil(service["NSRequiredContext"], "listed in the Services menu without the user turning it on (\(title))")
            XCTAssertNil(service["NSReturnTypes"], "nothing goes back to the app that asked (\(title))")
            let message = try XCTUnwrap(service["NSMessage"] as? String)
            XCTAssertTrue(provider.responds(to: NSSelectorFromString("\(message):userData:error:")), "\(title) reaches the provider")
        }
        XCTAssertEqual(titles, ["New Message with Selection", "Send with SuperSparrow"])
        XCTAssertEqual(services[0]["NSSendTypes"] as? [String], ["public.plain-text"], "text, in any form a selection is copied")
        XCTAssertNil(services[0]["NSSendFileTypes"])
        XCTAssertEqual(services[1]["NSSendFileTypes"] as? [String], ["public.data"], "files, never folders, which can't be attached")
        XCTAssertNil(services[1]["NSSendTypes"])
    }

    // MARK: The pasteboard

    func testTheSelectionIsReadAsPlainTextWithItsLineBreaks() throws {
        let pasteboard = selectionPasteboard("\r\n \n  Noon\r\nThe usual place\rSee you  \n\n")
        XCTAssertEqual(ServiceRequest.selection(from: pasteboard), .selection("  Noon\nThe usual place\nSee you"),
                       "CR LF and CR as line breaks; the empty lines before and the white space after go; the indent stays")
        XCTAssertEqual(ServiceRequest.body(from: " \n\t\n"), "", "white space alone is no text")
        XCTAssertEqual(ServiceRequest.body(from: "One\n\n\nTwo"), "One\n\n\nTwo", "empty lines inside are the writer's")
    }

    func testTextUnderItsLegacyNameIsRead() {
        let pasteboard = privatePasteboard()
        let legacy = NSPasteboard.PasteboardType("NSStringPboardType")
        pasteboard.declareTypes([legacy], owner: nil)
        pasteboard.setString("Noon", forType: legacy)
        XCTAssertEqual(ServiceRequest.selection(from: pasteboard), .selection("Noon"))
    }

    func testAPasteboardWithoutTextIsNoSelection() throws {
        let pasteboard = filesPasteboard([try makeFile("notes.txt")])
        pasteboard.clearContents()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(Data([0x89, 0x50]), forType: .png)
        XCTAssertNil(ServiceRequest.selection(from: pasteboard))

        let provider = MailServicesProvider()
        var error: NSString?
        provider.newMessageWithSelection(pasteboard, userData: nil, error: &error)
        XCTAssertEqual(error, "No text to send.", "the requesting app hears why")
        XCTAssertTrue(provider.pending.isEmpty, "and nothing is held to open")
    }

    func testFilesAreReadInTheirOrder() throws {
        let notes = try makeFile("notes.txt")
        let budget = try makeFile("budget.xlsx")
        XCTAssertEqual(ServiceRequest.files(from: filesPasteboard([notes, budget])), .files([notes, budget]))

        // An app that hands files over only under the legacy name, as paths.
        let legacy = privatePasteboard()
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        legacy.declareTypes([filenames], owner: nil)
        legacy.setPropertyList([budget.path, notes.path], forType: filenames)
        XCTAssertEqual(ServiceRequest.files(from: legacy).map(Self.paths), [budget.path, notes.path])
    }

    func testAPasteboardWithoutFilesIsNoRequest() throws {
        let web = privatePasteboard()
        web.writeObjects([URL(string: "https://example.com/report.pdf")! as NSURL])
        XCTAssertNil(ServiceRequest.files(from: web), "a web address is not a file")

        let provider = MailServicesProvider()
        var error: NSString?
        provider.sendFiles(selectionPasteboard("notes.txt"), userData: nil, error: &error)
        XCTAssertEqual(error, "No files to send.")
        XCTAssertTrue(provider.pending.isEmpty)
    }

    private static func paths(_ request: ServiceRequest) -> [String] {
        guard case .files(let urls) = request else { return [] }
        return urls.map(\.path)
    }

    // MARK: New Message with Selection

    func testASelectionOpensOneNewMessageWithItAsTheBody() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        XCTAssertEqual(harness.controller.strip.scope, .unified)
        let request = try XCTUnwrap(ServiceRequest.selection(from: selectionPasteboard("Noon\r\nThe usual place\n")))

        let composer = try XCTUnwrap(harness.controller.openServiceRequest(request))
        XCTAssertEqual(composers.count, 1)
        XCTAssertTrue(composers.first === composer)
        XCTAssertEqual(composer.mode, .new, "a new message, never a reply")
        XCTAssertEqual(composer.accountID, a.id, "All Inboxes: the first account in rail order")
        let contents = composer.contents
        XCTAssertTrue(contents.to.isEmpty && contents.cc.isEmpty && contents.bcc.isEmpty)
        XCTAssertEqual(contents.subject, "")
        XCTAssertEqual(composer.bodyText, "Noon\nThe usual place", "plain text, its line breaks kept")
        MainWindowHarness.assertWritingStyle(contents.body)
        XCTAssertTrue(contents.attachments.isEmpty)
        XCTAssertEqual(composer.window?.title, "New Message")
        assertFocusInTo(composer)
        XCTAssertEqual(composer.bodyEditor.selectedRange(), NSRange(location: 20, length: 0), "the caret waits at the end of the text")
        try assertNothingSentOrQueued(harness)
    }

    func testAScopedWindowComposesFromItsAccount() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.strip.select(.account(b.id), notify: true)
        let composer = try XCTUnwrap(harness.controller.openServiceRequest(.selection("Noon")))
        XCTAssertEqual(composer.accountID, b.id, "the account the window is scoped to")
    }

    func testTheSelectionIsFollowedByTheSignature() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        try harness.environment.store.setSignature("<p>Alex</p>", for: a.id)
        harness.controller.refreshAccounts()
        let composer = try XCTUnwrap(harness.controller.openServiceRequest(.selection("Noon")))
        XCTAssertEqual(composer.bodyText, "Noon\n\nAlex", "one empty line, then the signature, as on any new message")
        XCTAssertEqual(composer.bodyEditor.selectedRange(), NSRange(location: 4, length: 0), "the caret above the signature")
    }

    func testAnEmptySelectionOpensAnEmptyMessage() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try XCTUnwrap(harness.controller.openServiceRequest(try XCTUnwrap(ServiceRequest.selection(from: selectionPasteboard(" \n")))))
        XCTAssertEqual(composer.bodyText, "")
        assertFocusInTo(composer)
    }

    // MARK: Send with SuperSparrow

    func testFilesOpenOneNewMessageWithThemAttached() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let notes = try makeFile("notes.txt", bytes: 1_200)
        let budget = try makeFile("budget.xlsx", bytes: 48_000)
        let request = try XCTUnwrap(ServiceRequest.files(from: filesPasteboard([notes, budget])))

        let composer = try XCTUnwrap(harness.controller.openServiceRequest(request))
        XCTAssertEqual(composers.count, 1)
        XCTAssertEqual(composer.mode, .new)
        XCTAssertEqual(composer.accountID, a.id)
        let attachments = composer.contents.attachments
        XCTAssertEqual(attachments.map(\.filename), ["notes.txt", "budget.xlsx"], "in the order they came")
        XCTAssertEqual(attachments.map(\.sizeBytes), [1_200, 48_000])
        XCTAssertEqual(attachments.map(\.source), [.file(notes), .file(budget)], "read at send, as a dropped file is")
        XCTAssertTrue(attachments.allSatisfy { $0.state == .ready && !$0.isInline })
        XCTAssertEqual(composer.bodyText, "")
        XCTAssertEqual(composer.contents.subject, "")
        XCTAssertNil(composer.status, "nothing to report")
        assertFocusInTo(composer)
        try assertNothingSentOrQueued(harness)
    }

    /// The same rules as a drop on the composer: the readable files are attached, a folder or a file that cannot be read
    /// is named in the rejected-drop status, and no alert shows.
    func testAFolderIsSkippedAsADropSkipsIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let notes = try makeFile("notes.txt")
        let project = try makeFolder("Project Files")
        let composer = try XCTUnwrap(harness.controller.openServiceRequest(.files([notes, project])))
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["notes.txt"])
        XCTAssertEqual(composer.status, .rejectedDrop(ComposeStatus.RejectedDrop(folders: ["Project Files"])))
        XCTAssertEqual(composer.status?.text, "Folders can't be attached: “Project Files”.")

        let gone = folder.appendingPathComponent("moved.pdf")
        let onlyGone = try XCTUnwrap(harness.controller.openServiceRequest(.files([gone])))
        XCTAssertTrue(onlyGone.contents.attachments.isEmpty)
        XCTAssertEqual(onlyGone.status, .rejectedDrop(ComposeStatus.RejectedDrop(unreadable: ["moved.pdf"])),
                       "the composer still opens, saying why nothing is attached")
    }

    // MARK: Drafts

    /// What the service filled in is the window's starting point, as a mail link's is: closing it untouched, or Esc,
    /// keeps no draft; a recipient added is the user's work.
    func testClosingAnUntouchedServiceComposerKeepsNoDraft() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let text = try XCTUnwrap(harness.controller.openServiceRequest(.selection("Noon")))
        let textID = text.draftID
        try XCTUnwrap(text.window).performClose(nil)

        let files = try XCTUnwrap(harness.controller.openServiceRequest(.files([try makeFile("notes.txt")])))
        let filesID = files.draftID
        files.window?.cancelOperation(nil)
        XCTAssertTrue(composers.isEmpty, "Esc closes it, as it closes any composer nobody wrote in")
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: textID))
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: filesID))

        // A word typed into the body is the user's.
        let typed = try XCTUnwrap(harness.controller.openServiceRequest(.selection("Noon")))
        let editor = typed.bodyEditor
        typed.window?.makeFirstResponder(editor)
        editor.insertText(" Thanks!", replacementRange: editor.selectedRange())
        XCTAssertEqual(typed.bodyText, "Noon Thanks!")
        let typedID = typed.draftID
        try XCTUnwrap(typed.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: typedID))
    }

    // MARK: No account, demo mode

    func testWithNoAccountTheWelcomeComesForwardAndNothingOpens() throws {
        let harness = try MainWindowHarness(accounts: false)
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        XCTAssertFalse(window.isVisible)

        XCTAssertNil(harness.controller.openServiceRequest(.files([try makeFile("notes.txt")])))
        XCTAssertNil(harness.controller.openServiceRequest(.selection("Noon")))
        XCTAssertTrue(composers.isEmpty, "no composer without an account")
        XCTAssertTrue(window.isVisible, "the app comes forward")
        XCTAssertTrue(window.contentViewController is WelcomeViewController, "on the welcome screen")
    }

    func testTheDemoWritesFromItsFirstAccount() throws {
        let harness = try MainWindowHarness(demo: true)
        defer { harness.close() }
        ComposeDraftStore.shared.useDirectory(folder.appendingPathComponent("Demo Drafts"))
        let composer = try XCTUnwrap(harness.controller.openServiceRequest(.selection("Noon")))
        XCTAssertEqual(composer.accountID, harness.controller.accounts.first?.id)
        XCTAssertEqual(composer.bodyText, "Noon")
        try assertNothingSentOrQueued(harness)
    }

    // MARK: The app delegate

    /// A service that launches the app reaches the provider before the main window exists: it is held, then opened in
    /// one composer once the window is there, and later requests open at once.
    func testARequestThatArrivesBeforeTheWindowWaitsForIt() throws {
        let delegate = AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"]))
        var error: NSString?
        delegate.services.newMessageWithSelection(selectionPasteboard("Noon"), userData: nil, error: &error)
        XCTAssertNil(error)
        XCTAssertEqual(delegate.services.pending, [.selection("Noon")], "read from the pasteboard now, while it lasts")
        XCTAssertTrue(composers.isEmpty, "nothing opens before the window")

        // What `install` does once the main window is on screen.
        let harness = try MainWindowHarness()
        defer { harness.close() }
        delegate.openServiceRequests(in: harness.controller)
        XCTAssertTrue(delegate.services.pending.isEmpty)
        XCTAssertEqual(composers.count, 1, "one composer for one request")
        XCTAssertEqual(composers.first?.bodyText, "Noon")
        XCTAssertEqual(composers.first?.accountID, a.id)

        let first = try XCTUnwrap(composers.first)
        let notes = try makeFile("notes.txt")
        delegate.services.sendFiles(filesPasteboard([notes]), userData: nil, error: &error)
        XCTAssertNil(error)
        XCTAssertEqual(composers.count, 2, "once the window is there a request opens at once")
        XCTAssertEqual(composers.first { $0 !== first }?.contents.attachments.map(\.filename), ["notes.txt"])
    }

    func testHeldRequestsOpenInTheOrderTheyCame() {
        let provider = MailServicesProvider()
        provider.receive(.selection("one"))
        provider.receive(.files([URL(fileURLWithPath: "/tmp/two.txt")]))
        var opened: [ServiceRequest] = []
        provider.receiver = { opened.append($0) }
        XCTAssertEqual(opened, [.selection("one"), .files([URL(fileURLWithPath: "/tmp/two.txt")])])
        provider.receiver = { _ in XCTFail("each request opens once") }
        XCTAssertTrue(provider.pending.isEmpty)
    }
}
