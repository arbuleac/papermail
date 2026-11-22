import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// Signatures in the composer (spec §5.20, roadmap Q1.5): the From account's signature is ordinary body text one empty
/// line below the typing point and above the folded original, on new messages, replies, forwards and mail links; a From
/// change replaces it, removes it, and never brings back one the user deleted; a reopened draft gets no second one; the
/// quick reply's sends carry it; an empty signature adds nothing. Drafts go to a temporary folder, the windows are a
/// throwaway store's, and nothing reaches the network.
@MainActor
final class ComposerSignatureTests: XCTestCase {
    private var folder: URL!
    private var savedUndoWindow: TimeInterval = 5
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB

    private let contoso = "<div><p><b>Alex Morgan</b></p><p>Contoso · <a href=\"https://contoso.test\">contoso.test</a></p></div>"
    private let contosoText = "Alex Morgan\nContoso · contoso.test"
    /// The exporter's plain-text alternative names a link whose words are not its address.
    private let contosoPlain = "Alex Morgan\nContoso · contoso.test <https://contoso.test>"
    private let fabrikam = "<div><p><i>Alex</i> at Fabrikam</p></div>"
    private let fabrikamText = "Alex at Fabrikam"
    private let lisbon = "<div><p>Alex Morgan, Lisbon office</p></div>"
    private let lisbonText = "Alex Morgan, Lisbon office"

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperSignature-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            savedUndoWindow = ConversationViewController.undoWindow
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ConversationViewController.undoWindow = savedUndoWindow
            for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    /// A main window whose accounts carry these signatures (A Contoso's, B Fabrikam's by default).
    private func harness(a signatureA: String?? = nil, b signatureB: String?? = nil) throws -> MainWindowHarness {
        let harness = try MainWindowHarness()
        try harness.environment.store.setSignature(signatureA ?? contoso, for: a.id)
        try harness.environment.store.setSignature(signatureB ?? fabrikam, for: b.id)
        harness.controller.refreshAccounts()
        return harness
    }

    private var composers: [ComposeWindowController] { ComposeWindowRegistry.shared.openControllers }

    private func newMessage(_ harness: MainWindowHarness) throws -> ComposeWindowController {
        harness.controller.composeNew()
        return try XCTUnwrap(composers.last)
    }

    /// A reply or forward to thread-0's one message (account A), its original body stored so the quote folds in
    /// without the network.
    private func prefilled(_ harness: MainWindowHarness, forward: Bool = false) throws -> ComposeWindowController {
        let original = MessageID(accountID: a.id, providerID: "msg-0-0")
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>The quarterly plan is attached.</p>",
                                                                            text: "The quarterly plan is attached."),
                                                          renderedHTML: "<p>The quarterly plan is attached.</p>",
                                                          plainText: "The quarterly plan is attached."), for: original)
        let accounts = harness.controller.accounts
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: forward ? .forward(original) : .reply(original, all: false))
        XCTAssertTrue(ListTestSupport.spin(until: { composer.contents.quoted != nil }, timeout: 5), "the original folds in")
        return composer
    }

    private func signatureRange(_ composer: ComposeWindowController) -> NSRange? {
        ComposeSignature.range(in: composer.contents.body)
    }

    private func type(_ text: String, at location: Int, in composer: ComposeWindowController) {
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
        // Ends the run loop turn, so the edit is its own undo group as a keystroke's is.
        ListTestSupport.spin(for: 0.02)
    }

    /// The one composer `action` opens (the registry does not keep them in order).
    private func opened(_ action: () throws -> Void) throws -> ComposeWindowController {
        let before = Set(composers.map(ObjectIdentifier.init))
        try action()
        let new = composers.filter { !before.contains(ObjectIdentifier($0)) }
        XCTAssertEqual(new.count, 1, "one composer opens")
        return try XCTUnwrap(new.first)
    }

    /// Every view of `type` in `view`'s tree, depth first.
    private func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        let own: [T] = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The last queued send, once the composer has handed it over.
    private func queuedSend(_ harness: MainWindowHarness) throws -> OutgoingMessage {
        XCTAssertTrue(ListTestSupport.spin(until: { (try? harness.environment.store.pendingSends().isEmpty) == false }, timeout: 5))
        return try XCTUnwrap(try harness.environment.store.pendingSends().last).message
    }

    // MARK: Insertion

    func testANewMessageStartsWithTheSignatureOneEmptyLineBelowTheCaret() throws {
        let harness = try harness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        XCTAssertEqual(composer.accountID, a.id)
        XCTAssertEqual(composer.bodyText, "\n\n" + contosoText, "the typing line, one empty line, the signature; no “-- ” line")
        XCTAssertEqual(signatureRange(composer), NSRange(location: 2, length: (contosoText as NSString).length))
        XCTAssertEqual(composer.bodyEditor.selectedRange(), NSRange(location: 0, length: 0), "the caret starts above it")

        // In the composer's own formatting, in the writing face.
        let body = composer.contents.body
        let bold = try XCTUnwrap(body.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        XCTAssertEqual(bold.familyName, ComposeTextView.bodyFont.familyName)
        let link = (composer.bodyText as NSString).range(of: "contoso.test")
        XCTAssertEqual(body.attribute(.link, at: link.location, effectiveRange: nil) as? String, "https://contoso.test")

        // What the user types goes above it; text typed at its end is the user's, never marked as the signature.
        type("Hi Ben", at: 0, in: composer)
        XCTAssertEqual(composer.bodyText, "Hi Ben\n\n" + contosoText)
        type(" (sent from Lisbon)", at: (composer.bodyText as NSString).length, in: composer)
        XCTAssertEqual(signatureRange(composer), NSRange(location: 8, length: (contosoText as NSString).length))
    }

    func testARepliesAndForwardsSignatureSitsAboveTheFoldedOriginal() throws {
        let harness = try harness()
        defer { harness.close() }
        for forward in [false, true] {
            let composer = try prefilled(harness, forward: forward)
            XCTAssertEqual(composer.bodyText, "\n\n" + contosoText, forward ? "forward" : "reply")
            XCTAssertEqual(composer.bodyEditor.selectedRange(), NSRange(location: 0, length: 0))
            // The folded original is the next thing after the editor's text, so the signature is above it.
            let export = ComposerHTMLExporter().export(ComposeBodyNormalizer.normalize(composer.contents.body),
                                                       appending: composer.contents.quoted)
            let signature = try XCTUnwrap(export.html.range(of: "<b>Alex Morgan</b>"))
            let quote = try XCTUnwrap(export.html.range(of: "The quarterly plan is attached."))
            XCTAssertLessThan(signature.lowerBound, quote.lowerBound)
            composer.closeWithoutSaving()
        }
    }

    func testAMailLinksBodyIsFollowedByTheSignature() throws {
        let harness = try harness()
        defer { harness.close() }
        let link = MailtoLink(to: [EmailAddress(address: "ben@contoso.test")], subject: "Lunch?", body: "Noon\nThe usual place")
        let composer = try XCTUnwrap(harness.controller.openMailLink(link))
        XCTAssertEqual(composer.bodyText, "Noon\nThe usual place\n\n" + contosoText)
        XCTAssertTrue(composer.window?.firstResponder === composer.bodyEditor, "To and Subject filled: the body")
        XCTAssertEqual(composer.bodyEditor.selectedRange(), NSRange(location: 20, length: 0), "the caret at the end of the link's body")

        // Still the link's starting point: closing it untouched keeps nothing.
        let id = composer.draftID
        try XCTUnwrap(composer.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: id))
    }

    func testAnEmptySignatureAddsNothingAtAll() throws {
        let harness = try harness(a: .some(nil), b: .some("  "))
        defer { harness.close() }
        XCTAssertEqual(harness.controller.accounts.map(\.signature), [nil, nil])
        let composer = try newMessage(harness)
        XCTAssertEqual(composer.bodyText, "")
        XCTAssertNil(signatureRange(composer))
        let reply = try prefilled(harness)
        XCTAssertEqual(reply.bodyText, "")
        let link = try XCTUnwrap(harness.controller.openMailLink(MailtoLink(to: [EmailAddress(address: "ben@contoso.test")], body: "Noon")))
        XCTAssertEqual(link.bodyText, "Noon")
        composer.chooseFrom(b.id)
        XCTAssertEqual(composer.bodyText, "", "nor does a From change")
    }

    /// Closing a message that holds nothing but its signature keeps no draft: the signature is the composer's, not the
    /// user's work. Neither does a From change alone.
    func testASignatureAloneIsNotWorthKeeping() throws {
        let harness = try harness()
        defer { harness.close() }
        let fresh = try newMessage(harness)
        let freshID = fresh.draftID
        try XCTUnwrap(fresh.window).performClose(nil)

        let reply = try prefilled(harness)
        reply.chooseFrom(b.id)
        XCTAssertEqual(reply.bodyText, "\n\n" + fabrikamText)
        let replyID = reply.draftID
        try XCTUnwrap(reply.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: freshID))
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: replyID))
    }

    /// Text typed between the signature's lines is the user's: closing keeps it as a draft, though a From change would
    /// replace it with the signature.
    func testTextTypedInsideTheSignatureIsWorthKeeping() throws {
        let harness = try harness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("\nCan you call me tomorrow?", at: 2 + ("Alex Morgan" as NSString).length, in: composer)
        XCTAssertEqual(composer.bodyText, "\n\nAlex Morgan\nCan you call me tomorrow?\nContoso · contoso.test")
        XCTAssertEqual(ComposeSignature.typedText(of: composer.contents.body), "\nCan you call me tomorrow?")
        let id = composer.draftID
        try XCTUnwrap(composer.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: id), "kept, not dropped without a word")
    }

    // MARK: From

    func testChangingFromReplacesTheSignatureAndUndoBringsTheOldOneBack() throws {
        let harness = try harness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("Hi Ben", at: 0, in: composer)
        composer.bodyEditor.setSelectedRange(NSRange(location: 3, length: 0))

        composer.chooseFrom(b.id)
        XCTAssertEqual(composer.accountID, b.id)
        XCTAssertEqual(composer.bodyText, "Hi Ben\n\n" + fabrikamText)
        XCTAssertEqual(signatureRange(composer), NSRange(location: 8, length: (fabrikamText as NSString).length))
        XCTAssertEqual(composer.bodyEditor.selectedRange(), NSRange(location: 3, length: 0), "the caret stays where it was")
        let italic = try XCTUnwrap(composer.contents.body.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))

        ListTestSupport.spin(for: 0.02)
        let undo = try XCTUnwrap(composer.bodyEditor.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(composer.bodyText, "Hi Ben\n\n" + contosoText, "undo restores the previous body")
    }

    func testFromAnAccountWithoutASignatureRemovesItAndTheEmptyLine() throws {
        let harness = try harness(b: .some(nil))
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("Hi Ben", at: 0, in: composer)
        composer.chooseFrom(b.id)
        XCTAssertEqual(composer.bodyText, "Hi Ben", "removed, with the empty line before it")
        XCTAssertNil(signatureRange(composer))

        // It was the composer that removed it, so going back adds it again.
        composer.chooseFrom(a.id)
        XCTAssertEqual(composer.bodyText, "Hi Ben\n\n" + contosoText)

        // A message that opened from an account with none takes the next account's below what was written.
        let unsigned = try XCTUnwrap(harness.controller.openMailLink(MailtoLink(to: [EmailAddress(address: "ben@contoso.test")],
                                                                                subject: "Hi", body: "Noon")))
        XCTAssertEqual(unsigned.accountID, a.id)
        unsigned.chooseFrom(b.id)
        XCTAssertEqual(unsigned.bodyText, "Noon")
        unsigned.chooseFrom(a.id)
        XCTAssertEqual(unsigned.bodyText, "Noon\n\n" + contosoText)
    }

    func testASignatureTheUserDeletedIsNotAddedAgain() throws {
        let harness = try harness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("Hi Ben", at: 0, in: composer)
        let editor = composer.bodyEditor
        let signature = try XCTUnwrap(signatureRange(composer))
        editor.setSelectedRange(signature)
        editor.deleteBackward(nil)
        XCTAssertEqual(composer.bodyText, "Hi Ben\n\n")
        XCTAssertNil(signatureRange(composer))

        composer.chooseFrom(b.id)
        XCTAssertEqual(composer.bodyText, "Hi Ben\n\n", "nothing is added back")
        composer.chooseFrom(a.id)
        XCTAssertEqual(composer.bodyText, "Hi Ben\n\n")
    }

    /// Text typed inside the signature goes with it: the whole marked range is replaced. Text after it stays.
    func testAnEditedSignatureIsReplacedWhole() throws {
        let harness = try harness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type(" (CEO)", at: 2 + ("Alex Morgan" as NSString).length, in: composer)
        type("\nP.S. Lisbon in May", at: (composer.bodyText as NSString).length, in: composer)
        XCTAssertEqual(composer.bodyText, "\n\nAlex Morgan (CEO)\nContoso · contoso.test\nP.S. Lisbon in May")

        composer.chooseFrom(b.id)
        XCTAssertEqual(composer.bodyText, "\n\n" + fabrikamText + "\nP.S. Lisbon in May")
        XCTAssertEqual(composer.bodyEditor.selectedRange(), NSRange(location: (composer.bodyText as NSString).length, length: 0),
                       "the caret stays at the end of what was written after it")
    }

    /// Clicking From leaves focus in an open link popover, whose range was taken from the body before the From change
    /// moved its text: the change closes it before it edits the body, so it can never link other characters.
    func testAFromChangeClosesTheLinkPopoverBeforeItEditsTheBody() throws {
        let harness = try harness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("\nSee the plan", at: (composer.bodyText as NSString).length, in: composer)
        let editor = composer.bodyEditor
        let window = try XCTUnwrap(composer.window)
        editor.setSelectedRange((composer.bodyText as NSString).range(of: "plan"))
        editor.insertLink(nil)
        let popover = try XCTUnwrap(views(ComposeLinkPopover.self, in: window.contentView).first, "⌘K opens it")
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: popover) == true, "focused, where a click on From leaves it")

        composer.chooseFrom(b.id)
        XCTAssertEqual(composer.bodyText, "\n\n" + fabrikamText + "\nSee the plan")
        XCTAssertTrue(ListTestSupport.spin(until: { popover.superview == nil }, timeout: 2), "the From change closed it")
        XCTAssertTrue(window.firstResponder === editor, "the caret is back in the text")
        XCTAssertEqual(editor.selectedRange(), (composer.bodyText as NSString).range(of: "plan"), "still on the same word")

        // ⌘K again links the word where it is now.
        editor.insertLink(nil)
        let again = try XCTUnwrap(views(ComposeLinkPopover.self, in: window.contentView).first { $0 !== popover })
        again.onConfirm?("https://example.com", nil)
        let plan = (composer.bodyText as NSString).range(of: "plan")
        var linked = NSRange()
        XCTAssertEqual(composer.contents.body.attribute(.link, at: plan.location, effectiveRange: &linked) as? String, "https://example.com")
        XCTAssertEqual(linked, plan)
    }

    // MARK: Accounts as they are now

    /// New Message on a recipient token opens a composer afterwards, so it takes the accounts as Settings left them,
    /// not as they were when this window opened: its signature, and the signatures its From popup swaps in.
    func testNewMessageFromARecipientTakesTheSignaturesAsTheyAreNow() throws {
        let harness = try harness()
        defer { harness.close() }
        let first = try newMessage(harness)
        // What a save in Settings does (`AppDelegate.edit`): the store, then the main window re-reads its accounts.
        try harness.environment.store.setSignature(lisbon, for: a.id)
        try harness.environment.store.setSignature(nil, for: b.id)
        harness.controller.refreshAccounts()

        let ben = EmailAddress(address: "ben@contoso.test")
        let field = try XCTUnwrap(views(AddressTokenField.self, in: first.window?.contentView).first)
        let newMessage = try XCTUnwrap(field.onNewMessage)
        let second = try opened { newMessage(ben) }
        XCTAssertEqual(second.accountID, a.id)
        XCTAssertEqual(second.contents.to, [ben])
        XCTAssertEqual(second.bodyText, "\n\n" + lisbonText, "the signature saved since the first window opened")
        second.chooseFrom(b.id)
        XCTAssertEqual(second.bodyText, "", "B has none now")
        XCTAssertEqual(first.bodyText, "\n\n" + contosoText, "the open window keeps what it started with")
    }

    /// A composer the main window opens reads the accounts as it opens, and Settings may still be key with a signature
    /// being edited (⌘N there, or a notification's Reply, whose banner leaves Settings key). The window lets Settings save
    /// first (`beforeCompose`, which the app delegate wires to end Settings' editing), on every path that opens one.
    func testEveryComposerTheMainWindowOpensLetsSettingsSaveFirst() throws {
        let harness = try harness()
        defer { harness.close() }
        let store = harness.environment.store
        let accountA = a.id
        var saves = 0
        harness.controller.beforeCompose = { [weak controller = harness.controller] in
            saves += 1
            try? store.setSignature("<div><p>Saved \(saves)</p></div>", for: accountA)
            controller?.refreshAccounts()
        }

        XCTAssertEqual(try opened { harness.controller.composeNew() }.bodyText, "\n\nSaved 1", "⌘N")
        let link = try XCTUnwrap(harness.controller.openMailLink(MailtoLink(to: [EmailAddress(address: "ben@contoso.test")],
                                                                            subject: "Lunch?", body: "Noon")))
        XCTAssertEqual(link.bodyText, "Noon\n\nSaved 2", "a mail link")
        let reply = try opened { harness.controller.answer(.reply(ConversationID(accountID: a.id, providerID: "thread-0"))) }
        XCTAssertEqual(reply.mode, .reply(MessageID(accountID: a.id, providerID: "msg-0-0"), all: false))
        XCTAssertEqual(reply.bodyText, "\n\nSaved 3", "a notification's Reply")
        _ = try openThread(harness, "thread-2")
        let handoff = try opened { harness.reader.quickReplyBar.onOpenInComposer?("Tuesday works", .reply) }
        XCTAssertEqual(handoff.bodyText, "Tuesday works\n\nSaved 4", "the quick reply's hand-off")
    }

    // MARK: Drafts

    func testReopeningADraftAddsNoSecondSignature() throws {
        let harness = try harness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("Hi Ben", at: 0, in: composer)
        let id = composer.draftID
        try XCTUnwrap(composer.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: id))

        XCTAssertTrue(ComposeWindowController.reopenKeptDraft(id: id, client: harness.environment.engine, accounts: harness.controller.accounts))
        let reopened = try XCTUnwrap(composers.last)
        XCTAssertEqual(reopened.bodyText, "Hi Ben\n\n" + contosoText, "the draft's own signature, once")
        // The kept draft's signature is still the composer's: From replaces it.
        reopened.chooseFrom(b.id)
        XCTAssertEqual(reopened.bodyText, "Hi Ben\n\n" + fabrikamText)

        // A draft kept without one is reopened as it was, and a From change adds none to it.
        let bare = ComposeDraft(id: UUID(), mode: .new, account: a, to: [EmailAddress(address: "ben@contoso.test")], cc: [], bcc: [],
                                subject: "Lisbon", body: ComposeTextView.plainBody("See you there"), attachments: [], quoted: nil, threading: nil)
        let restored = ComposeWindowController.present(client: harness.environment.engine, accounts: harness.controller.accounts, draft: bare)
        XCTAssertEqual(restored.bodyText, "See you there")
        restored.chooseFrom(b.id)
        XCTAssertEqual(restored.bodyText, "See you there")
    }

    // MARK: Sending

    func testTheSentMessageCarriesTheSignatureInHTMLAndText() throws {
        let harness = try harness()
        defer { harness.close() }
        let composer = try prefilled(harness)
        type("Thanks, looks good", at: 0, in: composer)
        composer.send(nil)
        let message = try queuedSend(harness)
        XCTAssertTrue(message.html.hasPrefix("<div><p>Thanks, looks good</p><p><br></p><p><b>Alex Morgan</b></p>"
                                             + "<p>Contoso · <a href=\"https://contoso.test\">contoso.test</a></p></div>"), message.html)
        XCTAssertTrue(message.text.hasPrefix("Thanks, looks good\n\n" + contosoPlain + "\n\n"), message.text)
        XCTAssertTrue(message.text.contains("The quarterly plan is attached."), "the quote follows the signature")
        XCTAssertFalse(message.text.contains("-- "))
    }

    // MARK: The quick reply

    private func openThread(_ harness: MainWindowHarness, _ providerID: String) throws -> ConversationID {
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == providerID }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { !harness.reader.currentMessages.isEmpty && harness.reader.currentConversationID == id }
        return id
    }

    func testASentQuickReplyCarriesTheSignature() throws {
        let harness = try harness()
        defer { harness.close() }
        let thread = try openThread(harness, "thread-2")
        XCTAssertEqual(thread.accountID, a.id)
        harness.reader.sendQuickReply("Sounds good", mode: .reply)
        let message = try XCTUnwrap(try harness.environment.store.pendingSends().first).message
        XCTAssertEqual(message.html, "<p>Sounds good</p><div><p><b>Alex Morgan</b></p><p>Contoso · <a href=\"https://contoso.test\">contoso.test</a></p></div>")
        XCTAssertEqual(message.text, "Sounds good\n\n" + contosoPlain)

        // Undone from a panel, the reply reopens in a composer with the same signature, still the composer's.
        _ = harness.controller.perform(.extendNext)
        let send = try XCTUnwrap(UndoSendPanel.liveSends.first)
        harness.controller.performUndo(.send(send.id))
        let composer = try XCTUnwrap(composers.last)
        XCTAssertEqual(composer.bodyText, "Sounds good\n\n" + contosoText)
        XCTAssertNotNil(signatureRange(composer))
    }

    func testTheQuickReplysTextGoesToTheComposerAboveTheSignature() throws {
        let harness = try harness()
        defer { harness.close() }
        _ = try openThread(harness, "thread-2")
        let bar = harness.reader.quickReplyBar
        bar.onOpenInComposer?("Tuesday works for me", .reply)
        let composer = try XCTUnwrap(composers.first)
        XCTAssertEqual(composer.bodyText, "Tuesday works for me\n\n" + contosoText)
        XCTAssertEqual(composer.bodyEditor.selectedRange(), NSRange(location: 20, length: 0), "the caret at the end of the text")

        // Kept, then handed more text: it goes above the signature, which stays one.
        try XCTUnwrap(composer.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        bar.onOpenInComposer?("Or Wednesday", .reply)
        let reopened = try XCTUnwrap(composers.first)
        XCTAssertEqual(reopened.bodyText, "Tuesday works for me\n\nOr Wednesday\n\n" + contosoText)
        XCTAssertEqual(reopened.bodyEditor.selectedRange().location, ("Tuesday works for me\n\nOr Wednesday" as NSString).length)
    }
}
