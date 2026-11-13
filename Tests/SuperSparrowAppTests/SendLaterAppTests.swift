import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// Send Later in the app (spec §5.19, §5.23): offered in Send's drop-down, under ⇧⌘L (Message › Send Later…) and in the
/// quick reply; the message waits in the outbox with its draft kept, listed in Drafts as “Sends Mon 09:00”; opening it,
/// Cancel and Discard take the schedule back; once it goes its draft goes, a failure keeps it with the reason, and a time
/// missed while the app was closed is asked about. The engine never runs here (the outbox is moved by hand), drafts go to
/// a temporary folder and Pick a Time… is answered by the test.
@MainActor
final class SendLaterAppTests: XCTestCase {
    private var folder: URL!
    private var savedPicker: ((NSWindow?, @escaping @MainActor (Date?) -> Void) -> Void)?
    private let ben = EmailAddress(name: "Ben Carter", address: "ben@example.com")
    private let formatter = DateFormatting()

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowSendLater-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            savedPicker = SendLaterPicker.present
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let savedPicker { SendLaterPicker.present = savedPicker }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    private func newDraft(_ subject: String = "Lisbon", body: String = "See you there") -> ComposeDraft {
        ComposeDraft(id: UUID(), mode: .new, account: ListTestSupport.accountA, to: [ben], cc: [], bcc: [], subject: subject,
                     body: ComposeTextView.plainBody(body), attachments: [], quoted: nil, threading: nil)
    }

    private func composer(_ draft: ComposeDraft, _ harness: MainWindowHarness) -> ComposeWindowController {
        ComposeWindowController.present(client: harness.environment.engine, accounts: harness.controller.accounts, draft: draft)
    }

    /// A message waiting for `date`, as a composer leaves it: its draft kept on this Mac, its send in the outbox.
    @discardableResult
    private func schedule(_ draft: ComposeDraft, at date: Date, _ harness: MainWindowHarness) throws -> String {
        ComposeDraftStore.shared.saveNow(draft)
        let message = OutgoingMessage(accountID: draft.account.id, to: draft.to, subject: draft.subject, html: "<p>\(draft.body.string)</p>",
                                      text: draft.body.string)
        return try harness.environment.engine.scheduleSend(message, at: date, draftID: draft.id)
    }

    private func row(_ sendID: String) -> ConversationID {
        SendLaterConversation.conversationID(sendID: sendID, account: ListTestSupport.accountA.id)
    }

    private func draftRow(_ draft: ComposeDraft) -> ConversationID {
        LocalDraftConversation.conversationID(draftID: draft.id, account: draft.account.id)
    }

    private func select(_ id: ConversationID, in harness: MainWindowHarness) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    private func showDrafts(listing id: ConversationID, _ harness: MainWindowHarness) {
        XCTAssertTrue(harness.controller.perform(.goTo(.drafts)))
        harness.spin { harness.list.conversations.contains { $0.id == id } }
    }

    private func perform(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    private func sends(_ harness: MainWindowHarness) -> [PendingSend] {
        (try? harness.environment.store.pendingSends()) ?? []
    }

    private func time(_ date: Date) -> String {
        formatter.dueTime(for: date, reference: formatter.reference(now: Date()))
    }

    /// A timed item's name, without the time its title carries after a tab.
    private func name(of item: NSMenuItem) -> String {
        item.title.components(separatedBy: "\t").first ?? item.title
    }

    // MARK: Offered

    /// The drop-down: the two choices, then Send Later's heading, its times with their times written beside them, and
    /// Pick a Time…; ⇧⌘L shows the times alone, and the Message menu carries the command.
    func testSendsDropDownOffersSendLaterAfterTheTwoChoices() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = composer(newDraft(), harness)
        let menu = composer.sendOptionsMenu()
        XCTAssertEqual(menu.items.prefix(2).map(\.title), ["Send and Archive", "Send"])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertTrue(menu.items[3].isSectionHeader)
        XCTAssertEqual(menu.items[3].title, "Send Later")
        let times = menu.items.dropFirst(4).dropLast()
        let offered = SendLaterPreset.offered(at: Date(), calendar: .autoupdatingCurrent)
        // Each item's title is its name, then its time on a tab stop.
        XCTAssertEqual(times.map { name(of: $0) }, offered.map(\.preset.title), "Tomorrow, then Monday unless Monday is tomorrow")
        XCTAssertEqual(times.compactMap { $0.representedObject as? Date }, offered.map(\.date))
        XCTAssertEqual(times.first?.attributedTitle?.string, "Tomorrow\t" + time(offered[0].date), "its time beside it")
        XCTAssertEqual(menu.items.last?.title, "Pick a Time…")
        XCTAssertTrue(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })

        let later = composer.sendLaterMenu()
        XCTAssertEqual(later.items.map { name(of: $0) }, ["Send Later"] + offered.map(\.preset.title) + ["Pick a Time…"])

        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let message = try XCTUnwrap(bar.items.first { $0.submenu?.title == "Message" }?.submenu)
        let both = try XCTUnwrap(message.items.firstIndex { $0.action == #selector(ComposeWindowController.sendAndArchive(_:)) })
        let item = message.items[both + 1]
        XCTAssertEqual(item.action, #selector(ComposeWindowController.sendLater(_:)), "after Send and Archive")
        XCTAssertEqual(item.title, "Send Later…")
        XCTAssertEqual(item.keyEquivalent, "l")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(composer.validateMenuItem(item), "while Send could send")
    }

    // MARK: From the composer

    /// Tomorrow: the message waits in the outbox for its time with its draft kept, the composer closes, the window says
    /// when it sends, and Drafts lists it as “Sends …” in place of the draft. Nothing is archived or sent. Undo brings the
    /// composer back with what was written.
    func testSchedulingFromTheComposerKeepsTheDraftAndListsItInDrafts() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = newDraft()
        let composer = composer(draft, harness)
        let menu = composer.sendOptionsMenu()
        let tomorrow = try XCTUnwrap(menu.items.first { name(of: $0) == "Tomorrow" })
        let date = try XCTUnwrap(tomorrow.representedObject as? Date)
        try perform(tomorrow)
        harness.spin { !self.sends(harness).isEmpty }
        let send = try XCTUnwrap(sends(harness).first)
        XCTAssertEqual(send.status, .later)
        XCTAssertEqual(send.sendAfter, date)
        XCTAssertEqual(send.draftID, draft.id)
        XCTAssertEqual(send.message.subject, "Lisbon")
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: draft.id), "kept for opening it from Drafts")
        harness.spin { ComposeWindowRegistry.shared.openControllers.isEmpty }
        XCTAssertTrue(ComposeWindowRegistry.shared.livePanels.isEmpty, "no undo-send countdown: nothing is going now")
        XCTAssertEqual(harness.toastMessage, "Sends " + time(date))

        showDrafts(listing: row(send.id), harness)
        let listed = try XCTUnwrap(harness.list.conversations.first { $0.id == row(send.id) })
        XCTAssertEqual(listed.sendLater, .waiting(until: date))
        XCTAssertFalse(harness.list.conversations.contains { $0.id == draftRow(draft) }, "the row stands in for its draft")
        select(row(send.id), in: harness)
        XCTAssertEqual(harness.reader.currentMessages.map(\.subject), ["Lisbon"])
        XCTAssertEqual(harness.reader.currentMessages.first?.to, [ben])

        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(sends(harness).isEmpty, "Undo takes the schedule back")
        let reopened = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first)
        XCTAssertEqual(reopened.draftID, draft.id)
        XCTAssertEqual(reopened.contents.subject, "Lisbon")
    }

    /// Pick a Time… asks for the time first; Cancel there schedules nothing.
    func testPickATimeAsksForTheTimeFirst() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        var answer: Date?
        SendLaterPicker.present = { _, completion in completion(answer) }
        let composer = composer(newDraft(), harness)
        composer.sendLater(at: nil)
        XCTAssertTrue(sends(harness).isEmpty, "cancelled: nothing scheduled")
        XCTAssertFalse(ComposeWindowRegistry.shared.openControllers.isEmpty)
        answer = Date().addingTimeInterval(7_200)
        composer.sendLater(at: nil)
        harness.spin { !self.sends(harness).isEmpty }
        XCTAssertEqual(sends(harness).first?.sendAfter.timeIntervalSince1970 ?? 0, answer?.timeIntervalSince1970 ?? 1, accuracy: 0.001)
    }

    // MARK: In Drafts

    /// Opening it (↩, Continue Editing) cancels the schedule and brings back the draft it was written in.
    func testOpeningAScheduledMessageCancelsItsSchedule() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = newDraft()
        let sendID = try schedule(draft, at: Date().addingTimeInterval(86_400), harness)
        showDrafts(listing: row(sendID), harness)
        select(row(sendID), in: harness)
        XCTAssertTrue(harness.controller.perform(.open))
        XCTAssertTrue(sends(harness).isEmpty, "opening it cancels the schedule")
        let composer = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first)
        XCTAssertEqual(composer.draftID, draft.id)
        harness.spin { harness.list.conversations.contains { $0.id == self.draftRow(draft) } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == row(sendID) })
    }

    /// Cancel beside its time: the schedule goes, the draft stays and takes the selection; Undo schedules it again.
    func testCancelKeepsTheDraftAndUndoSchedulesItAgain() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = newDraft()
        let date = Date().addingTimeInterval(86_400)
        let sendID = try schedule(draft, at: date, harness)
        showDrafts(listing: row(sendID), harness)
        select(row(sendID), in: harness)
        harness.controller.cancelSendLater(row(sendID))
        XCTAssertTrue(sends(harness).isEmpty)
        XCTAssertEqual(harness.list.selectedConversationID, draftRow(draft), "the draft it was written in, selected in its place")
        XCTAssertEqual(harness.toastMessage, "Send Later cancelled")
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: draft.id))

        XCTAssertTrue(harness.controller.perform(.undo))
        let again = try XCTUnwrap(sends(harness).first)
        XCTAssertEqual(again.status, .later)
        XCTAssertEqual(again.draftID, draft.id)
        XCTAssertEqual(again.sendAfter.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(harness.list.selectedConversationID, row(again.id))
    }

    /// Discard takes the schedule and the draft; Undo brings back both.
    func testDiscardingAScheduledMessageTakesItsDraftAndUndoBringsBothBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = newDraft()
        let sendID = try schedule(draft, at: Date().addingTimeInterval(86_400), harness)
        showDrafts(listing: row(sendID), harness)
        harness.controller.discardDrafts([row(sendID)])
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(sends(harness).isEmpty)
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: draft.id))
        XCTAssertEqual(harness.toastMessage, "Draft discarded")
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: draft.id))
        XCTAssertEqual(sends(harness).map(\.draftID), [draft.id], "scheduled again")
    }

    // MARK: Outcomes

    /// Once it has gone (the runner leaves it `sent`), its draft goes, then its row.
    func testOnceItHasGoneItsDraftAndRowGo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = newDraft()
        let sendID = try schedule(draft, at: Date().addingTimeInterval(60), harness)
        var send = try XCTUnwrap(sends(harness).first { $0.id == sendID })
        send.status = .sent
        try harness.environment.store.updateSend(send)
        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: draft.id), "no draft left of a message that went")
    }

    /// A failure when its time came keeps the draft with the reason and says so; the row goes.
    func testAFailureKeepsTheDraftWithItsReason() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = newDraft()
        let sendID = try schedule(draft, at: Date().addingTimeInterval(60), harness)
        var send = try XCTUnwrap(sends(harness).first { $0.id == sendID })
        send.status = .failed
        send.lastError = "server(status: 413, message: too large)"
        try harness.environment.store.updateSend(send)
        harness.spin { self.sends(harness).isEmpty }
        let kept = try XCTUnwrap(ComposeDraftStore.shared.draft(id: draft.id, accounts: harness.controller.accounts))
        XCTAssertEqual(kept.sendFailure, "Couldn't send: Gmail rejected the attachment size.")
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t send \u{201c}Lisbon\u{201d}")
    }

    /// A time missed while the app was closed is asked about: Keep in Drafts (the default) leaves it as its draft, Send
    /// Now sends it.
    func testATimeMissedWhileClosedIsAskedAbout() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        var asked: [(alert: AppAlert, answer: @MainActor (Int) -> Void)] = []
        harness.controller.presentMissedSends = { alert, answer in asked.append((alert, answer)) }
        let draft = newDraft()
        ComposeDraftStore.shared.saveNow(draft)
        let missed = PendingSend(message: OutgoingMessage(accountID: draft.account.id, to: [ben], subject: "Lisbon", html: "", text: "See you there"),
                                 sendAfter: Date().addingTimeInterval(-3_600), status: .missed, draftID: draft.id)
        try harness.environment.store.enqueueSend(missed)
        harness.spin { !asked.isEmpty }
        let first = try XCTUnwrap(asked.first)
        XCTAssertEqual(first.alert.title, "A scheduled message wasn't sent")
        XCTAssertEqual(first.alert.buttons.map(\.title), ["Keep in Drafts", "Send Now"])
        XCTAssertTrue(first.alert.body.contains("\u{201c}Lisbon\u{201d} to Ben Carter"), first.alert.body)
        XCTAssertEqual(first.alert.escapeIndex, 0, "Esc keeps it")
        first.answer(1)
        let released = try XCTUnwrap(sends(harness).first)
        XCTAssertEqual(released.status, .later)
        XCTAssertLessThanOrEqual(released.sendAfter, Date(), "due now, so it goes at the runner's next look")
        XCTAssertEqual(asked.count, 1, "asked once")

        try harness.environment.store.deleteSend(id: missed.id)
        let other = PendingSend(message: missed.message, sendAfter: Date().addingTimeInterval(-60), status: .missed, draftID: draft.id)
        try harness.environment.store.enqueueSend(other)
        harness.spin { asked.count == 2 }
        asked[1].answer(0)
        XCTAssertTrue(sends(harness).isEmpty, "kept in Drafts")
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: draft.id))
    }

    // MARK: The quick reply

    /// The quick reply's drop-down offers the same times; scheduling clears the bar and archives nothing, and Undo puts
    /// the text back.
    func testTheQuickReplySchedulesToo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        select(id, in: harness)
        harness.spin { harness.reader.currentConversationID == id && !harness.reader.currentMessages.isEmpty }
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let bar = harness.reader.quickReplyBar
        bar.text = "Thanks, see you Monday"
        let menu = bar.sendOptionsMenu()
        XCTAssertEqual(menu.items.last?.title, "Pick a Time…")
        XCTAssertEqual(bar.sendLaterMenu().items.first?.title, "Send Later")
        let date = Date().addingTimeInterval(86_400)
        bar.sendLater(at: date)
        let send = try XCTUnwrap(sends(harness).first)
        XCTAssertEqual(send.status, .later)
        XCTAssertEqual(send.message.inReplyTo?.providerID, "msg-2-2")
        let draftID = try XCTUnwrap(send.draftID)
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: draftID))
        XCTAssertEqual(bar.text, "")
        XCTAssertTrue(try harness.environment.store.messages(in: id).contains(where: \.isInInbox), "nothing is archived")
        XCTAssertEqual(harness.toastMessage, "Sends " + time(date))

        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(sends(harness).isEmpty)
        XCTAssertEqual(bar.text, "Thanks, see you Monday", "the reply is back where it was written")
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: draftID))
    }
}
