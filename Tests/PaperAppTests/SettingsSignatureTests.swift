import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// Settings › Accounts › Signature (spec §5.40, roadmap Q1.5): the composer's own editor with its inline formatting,
/// saved as the composer's HTML subset once editing ends, never per keystroke. The windows are a throwaway store's;
/// nothing touches the app's real store or defaults.
@MainActor
final class SettingsSignatureTests: XCTestCase {
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB

    /// An editor in a window of its own, recording what it saves.
    private final class Recorder {
        var commits: [(html: String?, account: AccountID)] = []
    }

    private func editorInWindow() -> (SignatureEditorView, NSWindow, Recorder) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let editor = SignatureEditorView(frame: NSRect(x: 20, y: 20, width: 344, height: 66))
        window.contentView?.addSubview(editor)
        let recorder = Recorder()
        editor.onCommit = { html, account in recorder.commits.append((html, account)) }
        return (editor, window, recorder)
    }

    private func type(_ text: String, in editor: SignatureEditorView) {
        let view = editor.textView
        view.insertText(text, replacementRange: view.selectedRange())
    }

    func testItSavesTheComposersHTMLOnceEditingEnds() throws {
        let (editor, window, recorder) = editorInWindow()
        defer { window.close() }
        editor.load(nil, for: a.id)
        XCTAssertEqual(editor.textView.string, "", "empty by default")
        XCTAssertTrue(window.makeFirstResponder(editor.textView))

        type("Alex Morgan", in: editor)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
        editor.textView.toggleBold(nil)
        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        editor.textView.insertNewline(nil)
        type("contoso.test", in: editor)
        editor.textView.applyLink("https://contoso.test", text: nil, to: NSRange(location: 12, length: 12))
        XCTAssertTrue(recorder.commits.isEmpty, "nothing is saved while typing")

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(recorder.commits.count, 1, "saved once, when editing ends")
        XCTAssertEqual(recorder.commits.first?.html,
                       "<div><p><b>Alex</b> Morgan</p><p><a href=\"https://contoso.test\">contoso.test</a></p></div>")
        XCTAssertEqual(recorder.commits.first?.account, a.id)

        // Focus coming and going without a change saves nothing more.
        window.makeFirstResponder(editor.textView)
        window.makeFirstResponder(nil)
        XCTAssertEqual(recorder.commits.count, 1)
    }

    /// Only what the composer sends is kept: styles the editor could hold but mail does not carry, and links the
    /// composer would not send, are dropped. Emptied, the field saves none.
    func testWhatItSavesIsSanitizedAndBlankIsNone() throws {
        let (editor, window, recorder) = editorInWindow()
        defer { window.close() }
        editor.load(nil, for: a.id)
        window.makeFirstResponder(editor.textView)
        let view = editor.textView
        type("Alex", in: editor)
        let storage = try XCTUnwrap(view.textStorage)
        let whole = NSRange(location: 0, length: storage.length)
        XCTAssertTrue(view.shouldChangeText(in: whole, replacementString: nil))
        storage.addAttributes([.foregroundColor: NSColor.systemRed, .font: NSFont(name: "Courier", size: 30) ?? NSFont.systemFont(ofSize: 30),
                               .link: "javascript:alert(1)", .backgroundColor: NSColor.yellow], range: whole)
        view.didChangeText()
        window.makeFirstResponder(nil)
        XCTAssertEqual(recorder.commits.count, 1)
        XCTAssertEqual(recorder.commits.last?.html, "<div><p>Alex</p></div>")

        window.makeFirstResponder(view)
        view.selectAll(nil)
        view.insertText("  \n ", replacementRange: view.selectedRange())
        window.makeFirstResponder(nil)
        XCTAssertEqual(recorder.commits.count, 2)
        XCTAssertNil(recorder.commits.last?.html, "white space alone is no signature")
    }

    func testChoosingAnotherAccountOrClosingTheWindowSavesFirst() throws {
        let (editor, window, recorder) = editorInWindow()
        defer { window.close() }
        editor.load("<div><p>Alex</p></div>", for: a.id)
        XCTAssertEqual(editor.textView.string, "Alex")
        window.makeFirstResponder(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        type(" Morgan", in: editor)

        // The store's echo of the same signature changes nothing in the field while it is being edited.
        editor.load("<div><p>Alex</p></div>", for: a.id)
        XCTAssertEqual(editor.textView.string, "Alex Morgan")

        editor.load("<div><p><i>Fabrikam</i></p></div>", for: b.id)
        XCTAssertEqual(recorder.commits.map(\.account), [a.id], "saved for the account it was editing")
        XCTAssertEqual(recorder.commits.first?.html, "<div><p>Alex Morgan</p></div>")
        XCTAssertEqual(editor.textView.string, "Fabrikam")

        type("!", in: editor)
        window.close()
        XCTAssertEqual(recorder.commits.map(\.account), [a.id, b.id], "closing the window ends editing")
    }

    /// Going to another window keeps the field focused there, so it is saved when its window stops being key: a
    /// composer opened from the main window next reads the accounts with it. Focus stays where it was.
    func testGoingToAnotherWindowSavesIt() throws {
        let (editor, window, recorder) = editorInWindow()
        defer { window.close() }
        editor.load(nil, for: a.id)
        XCTAssertTrue(window.makeFirstResponder(editor.textView))
        type("Alex Morgan", in: editor)
        XCTAssertTrue(recorder.commits.isEmpty)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(recorder.commits.map(\.html), ["<div><p>Alex Morgan</p></div>"])
        XCTAssertTrue(window.firstResponder === editor.textView, "the caret stays in the field")
    }

    /// The link popover belongs to the moment, as in the composer: focus going back to the text, or anywhere else, and
    /// another account's signature replacing the text, each close it, so it never links a range taken from other text.
    func testTheLinkPopoverClosesWhenFocusLeavesItOrTheTextIsReplaced() throws {
        let (editor, window, _) = editorInWindow()
        defer { window.close() }
        let view = editor.textView
        let openPopover = { () -> ComposeLinkPopover? in
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 12, length: 11))
            view.insertLink(nil)
            return Self.find(ComposeLinkPopover.self, in: window.contentView)
        }

        editor.load("<div><p>Roger Boo · example.com</p></div>", for: a.id)
        let first = try XCTUnwrap(openPopover(), "⌘K opens it")
        XCTAssertTrue(window.firstResponder.map { ($0 as? NSView)?.isDescendant(of: first) == true } ?? false, "focused on open")
        window.makeFirstResponder(view)
        XCTAssertTrue(ListTestSupport.spin(until: { first.superview == nil }, timeout: 2), "focus back in the text closes it")

        let second = try XCTUnwrap(openPopover())
        editor.load("<div><p>B</p></div>", for: b.id)
        XCTAssertTrue(ListTestSupport.spin(until: { second.superview == nil }, timeout: 2), "another account's text closes it")
        XCTAssertEqual(view.string, "B")

        // A range the text no longer reaches links nothing (and does not raise).
        view.applyLink("https://example.com", text: nil, to: NSRange(location: 12, length: 11))
        view.removeLink(in: NSRange(location: 12, length: 11))
        XCTAssertEqual(view.string, "B")
        XCTAssertNil(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
    }

    /// Quitting closes the store before AppKit posts will-terminate, so the field still being edited is saved first,
    /// while the store is open: it is there on the next launch.
    func testQuittingSavesTheFieldBeforeTheStoreCloses() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsSignatureTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try environment.store.upsertAccount(a)
        let controller = SettingsWindowController(environment: environment, settings: ListTestSupport.settings(), mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        let store = environment.store
        controller.model.setSignature = { [weak controller] html, id in
            try? store.setSignature(html, for: id)
            controller?.refreshAccounts()
        }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        controller.show(tab: .accounts)
        var editor: SignatureEditorView?
        XCTAssertTrue(ListTestSupport.spin(until: {
            editor = Self.find(SignatureEditorView.self, in: window.contentView)
            return editor?.accountID == a.id
        }, timeout: 5))
        let field = try XCTUnwrap(editor)
        ListTestSupport.spin(for: 0.05)
        XCTAssertTrue(window.makeFirstResponder(field.textView))
        field.textView.insertText("Alex Morgan", replacementRange: field.textView.selectedRange())

        // What `applicationShouldTerminate` does before it lets AppKit go on.
        var finished = false
        Task { @MainActor in
            await AppDelegate.prepareToQuit(settings: controller, environments: [environment])
            finished = true
        }
        XCTAssertTrue(ListTestSupport.spin(until: { finished }, timeout: 5))
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)

        let reopened = try SQLiteMailStore(path: directory.appendingPathComponent("scratch.sqlite").path)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.accounts().first { $0.id == a.id }?.signature, "<div><p>Alex Morgan</p></div>")
    }

    /// The field keeps to the composer's inline styles: the list and quote commands do nothing there.
    func testListsAndQuotesAreOff() throws {
        let (editor, window, _) = editorInWindow()
        defer { window.close() }
        editor.load("<div><p>Alex</p></div>", for: a.id)
        window.makeFirstResponder(editor.textView)
        editor.textView.selectAll(nil)
        editor.textView.toggleBulletList(nil)
        editor.textView.toggleBlockQuote(nil)
        XCTAssertEqual(editor.textView.string, "Alex", "no marker typed")
        XCTAssertEqual(ComposeSignature.html(from: editor.textView.attributedString()), "<div><p>Alex</p></div>")
        let item = NSMenuItem(title: "Bulleted List", action: #selector(ComposeTextView.toggleBulletList(_:)), keyEquivalent: "")
        XCTAssertFalse(editor.textView.validateUserInterfaceItem(item))
        let bold = NSMenuItem(title: "Bold", action: #selector(ComposeTextView.toggleBold(_:)), keyEquivalent: "")
        XCTAssertTrue(editor.textView.validateUserInterfaceItem(bold))
    }

    /// The detail form shows the selected account's signature in the editor, and a change saved there reaches the
    /// store through the model, as the app delegate wires it.
    func testTheDetailFormEditsTheSelectedAccountsSignature() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsSignatureTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try environment.store.upsertAccount(a)
        try environment.store.upsertAccount(b)
        try environment.store.setSignature("<div><p><b>Alex</b> at Contoso</p></div>", for: a.id)
        let controller = SettingsWindowController(environment: environment, settings: ListTestSupport.settings(), mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        let store = environment.store
        controller.model.setSignature = { [weak controller] html, id in
            try? store.setSignature(html, for: id)
            controller?.refreshAccounts()
        }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        controller.show(tab: .accounts)

        var editor: SignatureEditorView?
        XCTAssertTrue(ListTestSupport.spin(until: {
            editor = Self.find(SignatureEditorView.self, in: window.contentView)
            return editor?.textView.string == "Alex at Contoso"
        }, timeout: 5), "the selected account's signature")
        let field = try XCTUnwrap(editor)
        XCTAssertEqual(field.accountID, a.id)
        let bold = try XCTUnwrap(field.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask), "in the composer's own formatting")

        window.makeFirstResponder(field.textView)
        field.textView.setSelectedRange(NSRange(location: (field.textView.string as NSString).length, length: 0))
        field.textView.insertText(" Ltd", replacementRange: field.textView.selectedRange())
        XCTAssertEqual(try store.accounts().first { $0.id == a.id }?.signature, "<div><p><b>Alex</b> at Contoso</p></div>",
                       "not saved per keystroke")
        window.makeFirstResponder(nil)
        XCTAssertEqual(try store.accounts().first { $0.id == a.id }?.signature, "<div><p><b>Alex</b> at Contoso Ltd</p></div>")
        XCTAssertNil(try store.accounts().first { $0.id == b.id }?.signature)

        // Choosing the other account shows its (empty) signature.
        controller.model.selection = b.id.rawValue
        XCTAssertTrue(ListTestSupport.spin(until: {
            let current = Self.find(SignatureEditorView.self, in: window.contentView)
            return current?.accountID == b.id && current?.textView.string == ""
        }, timeout: 5))
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }
}
