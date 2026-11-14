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
        // Each time says, where a sighted user sees it, that it sends only while the app is open (spec §5.46).
        for (item, preset) in zip(times, offered) {
            XCTAssertEqual(item.toolTip, "Sends " + time(preset.date) + " while SuperSparrow is open")
            XCTAssertEqual(item.accessibilityHelp(), item.toolTip)
        }
        for (item, preset) in zip(later.items.dropFirst().dropLast(), offered) {
            XCTAssertEqual(item.toolTip, "Sends " + time(preset.date) + " while SuperSparrow is open", "under ⇧⌘L too")
        }
        // Later's own times have no such condition and keep their words for VoiceOver alone.
        let snooze = LaterMenu.build(now: Date(), formatter: formatter, target: self, presetAction: #selector(NSObject.copy),
                                     pickAction: #selector(NSObject.copy))
        XCTAssertTrue(snooze.items.allSatisfy { $0.toolTip == nil })

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

    /// R again on the conversation a scheduled reply answers starts another reply: the scheduled one's draft is not
    /// reopened, which would leave one message both waiting and open for sending.
    func testReplyingAgainDoesNotReopenAScheduledReply() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        var draft = newDraft("Re: thread")
        draft.mode = .reply(original, all: false)
        let sendID = try schedule(draft, at: Date().addingTimeInterval(86_400), harness)
        let accounts = harness.controller.accounts
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(original, all: false))
        XCTAssertNotEqual(composer.draftID, draft.id)
        XCTAssertEqual(sends(harness).map(\.id), [sendID], "still scheduled")
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
        // Built from the draft as the composer builds it, its attachments read off the main thread first.
        harness.spin { !self.sends(harness).isEmpty }
        let again = try XCTUnwrap(sends(harness).first)
        XCTAssertEqual(again.status, .later)
        XCTAssertEqual(again.draftID, draft.id)
        XCTAssertEqual(again.message.subject, "Lisbon")
        XCTAssertEqual(again.sendAfter.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        harness.spin { harness.list.selectedConversationID == self.row(again.id) }
        XCTAssertEqual(harness.list.selectedConversationID, row(again.id))
    }

    /// The draft is free to change once cancelled: Undo schedules it as it is then, not the message as it was cancelled.
    func testUndoingCancelSchedulesTheDraftAsItIsNow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        var draft = newDraft()
        let sendID = try schedule(draft, at: Date().addingTimeInterval(86_400), harness)
        showDrafts(listing: row(sendID), harness)
        harness.controller.cancelSendLater(row(sendID))
        draft.subject = "Lisbon, Friday"
        ComposeDraftStore.shared.saveNow(draft)
        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { !self.sends(harness).isEmpty }
        XCTAssertEqual(sends(harness).map(\.message.subject), ["Lisbon, Friday"])
    }

    /// Once the cancelled draft has gone (sent from a composer, discarded) or while a composer holds it, Undo schedules
    /// nothing: the old message must not go beside what the user did with it.
    func testUndoingCancelSchedulesNothingOnceTheDraftIsOpenOrGone() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = newDraft()
        let sendID = try schedule(draft, at: Date().addingTimeInterval(86_400), harness)
        showDrafts(listing: row(sendID), harness)
        harness.controller.cancelSendLater(row(sendID))
        let composer = composer(draft, harness)
        XCTAssertTrue(harness.controller.perform(.undo))
        ListTestSupport.spin(until: { false }, timeout: 0.3)
        XCTAssertTrue(sends(harness).isEmpty, "open in a composer")
        composer.closeWithoutSaving()

        let other = newDraft("Porto")
        let otherID = try schedule(other, at: Date().addingTimeInterval(86_400), harness)
        harness.spin { harness.list.conversations.contains { $0.id == self.row(otherID) } }
        harness.controller.cancelSendLater(row(otherID))
        // Sent from a composer meanwhile: its draft went with it.
        ComposeDraftStore.shared.remove(id: other.id)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(harness.controller.perform(.undo))
        ListTestSupport.spin(until: { false }, timeout: 0.3)
        XCTAssertTrue(sends(harness).isEmpty, "gone")
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
        harness.spin { !self.sends(harness).isEmpty }
        XCTAssertEqual(sends(harness).map(\.draftID), [draft.id], "scheduled again")
    }

    /// The row's time says on what condition it sends, in its tooltip (spec §5.46), as VoiceOver hears it.
    func testTheRowsTimeSaysItSendsWhileTheAppIsOpen() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let date = Date().addingTimeInterval(86_400)
        let sendID = try schedule(newDraft(), at: date, harness)
        showDrafts(listing: row(sendID), harness)
        harness.controller.window?.displayIfNeeded()
        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == row(sendID) })
        let tableRow = try XCTUnwrap(harness.list.layout.row(ofConversation: index))
        let cell = try XCTUnwrap(harness.list.tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: true) as? ConversationCellView)
        let tip = try XCTUnwrap(cell.toolTipRegions().first { $0.text.hasPrefix("Sends ") })
        XCTAssertEqual(tip.text, "Sends " + time(date) + " while SuperSparrow is open")
        XCTAssertGreaterThan(tip.rect.minX, cell.bounds.midX, "over the time, at the row's trailing edge")
    }

    /// Continue Editing on a provider's draft whose kept continuation is scheduled opens that one, its schedule cancelled
    /// first, rather than a fresh copy of the provider's draft that would go beside it.
    func testContinuingAProvidersDraftWhoseContinuationIsScheduledCancelsTheSchedule() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let provider = MessageID(accountID: ListTestSupport.accountA.id, providerID: "server-draft-x")
        var draft = newDraft()
        draft.continuesDraft = provider
        _ = try schedule(draft, at: Date().addingTimeInterval(86_400), harness)
        XCTAssertTrue(DraftReopener.present(provider, client: harness.environment.engine, accounts: harness.controller.accounts))
        XCTAssertTrue(sends(harness).isEmpty, "the schedule is cancelled first")
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.map(\.draftID), [draft.id])
    }

    // MARK: Outcomes

    /// Once it has gone (the runner leaves it `sent`), its draft goes, then its row.
    func testOnceItHasGoneItsDraftAndRowGo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = newDraft()
        let sendID = try schedule(draft, at: Date().addingTimeInterval(60), harness)
        harness.controller.sendLaterOutbox.refresh()
        XCTAssertTrue(harness.controller.localDrafts.summaries.contains { $0.id == row(sendID) })
        var send = try XCTUnwrap(sends(harness).first { $0.id == sendID })
        send.status = .sent
        try harness.environment.store.updateSend(send)
        // Told now, before the draft store has removed the draft on its own queue: the row leaves without turning back
        // into its draft for a moment.
        harness.controller.sendLaterOutbox.refresh()
        XCTAssertFalse(harness.controller.localDrafts.summaries.contains { $0.id == row(sendID) || $0.id == draftRow(draft) })
        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: draft.id), "no draft left of a message that went")
        ListTestSupport.spin(until: { false }, timeout: 0.3)
        XCTAssertFalse(harness.controller.localDrafts.summaries.contains { $0.id == draftRow(draft) })
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
