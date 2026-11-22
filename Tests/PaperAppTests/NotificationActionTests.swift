import AppKit
import PaperCore
import UserNotifications
import XCTest
@testable import PaperApp

/// Actions on a new-mail notification (spec §5.41, roadmap Q1.4): Archive and Mark as Read change the conversation
/// through the window's own path (store first, queued to sync) with no toast, no undo and no window brought forward;
/// Reply brings the app forward with a reply composer from the conversation's account. An action on a conversation
/// that is gone, or on an account the window does not show, does nothing, and one that comes before there is a main
/// window waits for it. The center is a fake and the windows are a throwaway store's: no test reaches the real
/// notification center, the app's store or the network.
@MainActor
final class NotificationActionTests: XCTestCase {
    private var folder: URL!
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperNotificationActions-\(UUID().uuidString)")
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

    /// Stands in for `UNUserNotificationCenter`, which raises in a process without a bundle.
    private final class FakeCenter: NotificationCenterRegistering {
        weak var delegate: UNUserNotificationCenterDelegate?
        var registered: [Set<UNNotificationCategory>] = []
        func setNotificationCategories(_ categories: Set<UNNotificationCategory>) { registered.append(categories) }
    }

    private var composers: [ComposeWindowController] { ComposeWindowRegistry.shared.openControllers }

    /// `ListTestSupport`'s thread `n`: even threads are account A's, odd ones B's; every third (0, 3, …) is one unread
    /// message; thread 1 is two read ones; thread 5 is B's with three messages.
    private func thread(_ n: Int) -> ConversationID {
        ConversationID(accountID: n % 2 == 0 ? a.id : b.id, providerID: "thread-\(n)")
    }

    /// A responder answered by `harness`'s window, as `AppDelegate.answerNotifications(in:)` wires it, counting the
    /// times it would bring the app forward.
    private func responder(for harness: MainWindowHarness) -> (NewMailNotificationResponder, activations: () -> Int) {
        let responder = NewMailNotificationResponder()
        var activations = 0
        responder.activate = { activations += 1 }
        responder.receiver = { [weak controller = harness.controller] in controller?.answer($0) }
        return (responder, { activations })
    }

    private func deliver(_ action: NewMailNotificationAction, on id: ConversationID, to responder: NewMailNotificationResponder) {
        responder.receive(actionIdentifier: action.identifier, userInfo: NewMailNotificationResponse.userInfo(for: id))
    }

    private func operations(in harness: MainWindowHarness) throws -> [PaperCore.Operation] {
        let store = harness.environment.store
        return try [a.id, b.id].flatMap { try store.pendingOperations(accountID: $0, limit: 100) }
    }

    private func messages(of id: ConversationID, in harness: MainWindowHarness) throws -> [MessageMetadata] {
        try harness.environment.store.messages(in: id)
    }

    /// Nothing in the window says an action happened, and nothing is left to undo.
    private func assertNoToastAndNoUndo(_ harness: MainWindowHarness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(harness.toastMessage, "no toast", file: file, line: line)
        XCTAssertFalse(harness.toasts.isVisible, file: file, line: line)
        XCTAssertEqual(harness.controller.zTarget, .nothing, "Z has nothing to undo", file: file, line: line)
        XCTAssertEqual(harness.controller.commandZTarget(textCanUndo: false), .nothing, "nor ⌘Z", file: file, line: line)
    }

    // MARK: The category

    func testTheCategoryOffersArchiveMarkAsReadAndReplyAndOnlyReplyComesForward() throws {
        let categories = NewMailNotificationAction.categories
        XCTAssertEqual(categories.count, 1)
        let category = try XCTUnwrap(categories.first)
        XCTAssertEqual(category.identifier, "newMail")
        XCTAssertEqual(category.actions.map(\.identifier), ["archive", "markRead", "reply"])
        XCTAssertEqual(category.actions.map(\.title), ["Archive", "Mark as Read", "Reply"])
        XCTAssertEqual(category.actions.map(\.options), [[], [], [.foreground]], "Archive and Mark as Read stay in the background")
        XCTAssertFalse(category.actions.contains { $0 is UNTextInputNotificationAction }, "Reply opens the composer, not a text field")
    }

    func testConnectingRegistersTheCategoryAndAnswersTheCenter() {
        let center = FakeCenter()
        let responder = NewMailNotificationResponder()
        responder.connect(to: center)
        XCTAssertEqual(center.registered.count, 1, "registered once, at launch")
        XCTAssertEqual(center.registered.first?.map(\.identifier), ["newMail"])
        XCTAssertEqual(center.registered.first?.first?.actions.map(\.identifier), ["archive", "markRead", "reply"])
        XCTAssertTrue(center.delegate === responder)
    }

    func testOnlyANotificationForOneConversationCarriesTheActions() throws {
        let settings = ListTestSupport.settings()
        settings.notificationsEnabled = true
        let notifier = NewMailNotifier(settings: settings)
        notifier.isFrontmost = { false }
        func row(_ n: Int) -> ConversationSummary {
            ConversationSummary(
                id: ConversationID(accountID: a.id, providerID: "t\(n)"), subject: "Subject \(n)", snippet: "Snippet",
                participants: [EmailAddress(name: "Ben Carter", address: "ben@example.com")], latestDate: Date(), messageCount: 1,
                unreadCount: 1, isStarred: false, hasAttachments: false, inInbox: true, inboxSection: .focused,
                latestMessageID: MessageID(accountID: a.id, providerID: "m\(n)"), hasPendingOperations: false)
        }
        let accounts = [a.id: a]
        let now = Date()
        XCTAssertTrue(notifier.plan([row(0)], accounts: accounts, now: now).isEmpty, "the first delivery only records")

        let single = try XCTUnwrap(notifier.plan([row(0), row(1)], accounts: accounts, now: now).first)
        let request = NewMailNotifier.request(for: single)
        XCTAssertEqual(request.content.categoryIdentifier, NewMailNotificationAction.categoryIdentifier)
        XCTAssertEqual(NewMailNotificationResponse(actionIdentifier: "archive", userInfo: request.content.userInfo), .archive(row(1).id),
                       "an action names the notification's conversation")

        // Three more within the window make a summary.
        let summary = try XCTUnwrap(notifier.plan((0...4).map(row), accounts: accounts, now: now).first)
        XCTAssertNil(summary.conversation)
        let summaryRequest = NewMailNotifier.request(for: summary)
        XCTAssertEqual(summaryRequest.content.title, "4 new messages")
        XCTAssertEqual(summaryRequest.content.categoryIdentifier, "", "the summary names no conversation to act on")
        XCTAssertTrue(summaryRequest.content.userInfo.isEmpty)
    }

    // MARK: Reading a response

    func testAResponseIsReadFromItsActionAndItsConversation() {
        let id = thread(5)
        let info = NewMailNotificationResponse.userInfo(for: id)
        XCTAssertEqual(NewMailNotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info), .open(id))
        XCTAssertEqual(NewMailNotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:]), .open(nil),
                       "a click on the summary")
        XCTAssertEqual(NewMailNotificationResponse(actionIdentifier: "archive", userInfo: info), .archive(id))
        XCTAssertEqual(NewMailNotificationResponse(actionIdentifier: "markRead", userInfo: info), .markRead(id))
        XCTAssertEqual(NewMailNotificationResponse(actionIdentifier: "reply", userInfo: info), .reply(id))
        XCTAssertNil(NewMailNotificationResponse(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: info))
        XCTAssertNil(NewMailNotificationResponse(actionIdentifier: "snooze", userInfo: info), "nothing this app registered")
        XCTAssertNil(NewMailNotificationResponse(actionIdentifier: "archive", userInfo: [:]), "an action needs a conversation")
    }

    // MARK: Archive and Mark as Read

    func testArchiveArchivesAndQueuesWithNoToastNoUndoAndNoWindow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        XCTAssertFalse(window.isVisible)
        let (responder, activations) = responder(for: harness)
        let id = thread(1)
        XCTAssertTrue(harness.list.conversations.contains { $0.id == id })

        deliver(.archive, on: id, to: responder)
        let archived = try messages(of: id, in: harness)
        XCTAssertFalse(archived.isEmpty)
        XCTAssertFalse(archived.contains { $0.roles.contains(.inbox) }, "archived in the store at once")
        let queued = try operations(in: harness)
        XCTAssertEqual(queued.map(\.change), [.archive], "one operation, queued to sync")
        XCTAssertEqual(Set(queued.flatMap(\.targets)), Set(archived.map(\.id)))
        XCTAssertEqual(queued.first?.accountID, b.id)
        assertNoToastAndNoUndo(harness)
        XCTAssertEqual(activations(), 0, "the app stays in the background")
        XCTAssertFalse(window.isVisible, "no window comes forward")
        harness.spin { !harness.list.conversations.contains { $0.id == id } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == id }, "the row leaves the inbox as a synced change would")
    }

    func testMarkAsReadMarksTheWholeConversationReadAndQueuesWithNoToastOrUndo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (responder, activations) = responder(for: harness)
        let id = thread(3)
        XCTAssertTrue(try messages(of: id, in: harness).contains { !$0.isRead }, "an unread conversation")

        deliver(.markRead, on: id, to: responder)
        let read = try messages(of: id, in: harness)
        XCTAssertTrue(read.allSatisfy(\.isRead), "read in the store at once")
        XCTAssertTrue(read.allSatisfy { $0.roles.contains(.inbox) }, "and still in the inbox")
        let queued = try operations(in: harness)
        XCTAssertEqual(queued.map(\.change), [.setRead(true)])
        XCTAssertEqual(Set(queued.flatMap(\.targets)), Set(read.map(\.id)))
        XCTAssertEqual(queued.first?.accountID, b.id)
        assertNoToastAndNoUndo(harness)
        XCTAssertEqual(activations(), 0)
        XCTAssertFalse(harness.controller.window?.isVisible ?? true)
    }

    func testAnActionThatChangesNothingDoesNothing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (responder, _) = responder(for: harness)
        // Thread 1 is read throughout; archive it, then archive it again.
        deliver(.markRead, on: thread(1), to: responder)
        XCTAssertTrue(try operations(in: harness).isEmpty, "already read: nothing queued")
        deliver(.archive, on: thread(1), to: responder)
        deliver(.archive, on: thread(1), to: responder)
        XCTAssertEqual(try operations(in: harness).count, 1, "already archived: nothing more queued")
        assertNoToastAndNoUndo(harness)
    }

    // MARK: Reply

    func testReplyOpensAReplyToTheLatestMessageFromItsAccountAndComesForward() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        // Scoped to the other account: a reply follows the conversation, not the window.
        harness.controller.strip.select(.account(a.id), notify: true)
        let (responder, activations) = responder(for: harness)
        let id = thread(5)
        let latest = try XCTUnwrap(try messages(of: id, in: harness).last)
        XCTAssertEqual(latest.id.providerID, "msg-5-2")

        deliver(.reply, on: id, to: responder)
        XCTAssertEqual(activations(), 1, "the app comes forward")
        XCTAssertEqual(composers.count, 1, "one composer")
        let composer = try XCTUnwrap(composers.first)
        XCTAssertEqual(composer.mode, .reply(latest.id, all: false), "a reply to the latest message, as R makes")
        XCTAssertEqual(composer.accountID, b.id, "from the conversation's account")
        XCTAssertTrue(try operations(in: harness).isEmpty, "nothing is sent or queued")
        assertNoToastAndNoUndo(harness)
    }

    // MARK: Nothing to act on

    func testAGoneConversationOrAnAccountNotOpenDoesNothing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (responder, _) = responder(for: harness)
        let gone = ConversationID(accountID: a.id, providerID: "thread-gone")
        // A demo notification once the real accounts are back: the conversation id exists, under another account.
        let elsewhere = ConversationID(accountID: AccountID("demo-gmail"), providerID: "thread-0")
        let before = try [thread(0), thread(1)].flatMap { try messages(of: $0, in: harness) }
        for id in [gone, elsewhere] {
            for action in NewMailNotificationAction.allCases { deliver(action, on: id, to: responder) }
        }
        XCTAssertTrue(try operations(in: harness).isEmpty, "nothing queued")
        XCTAssertEqual(try [thread(0), thread(1)].flatMap { try messages(of: $0, in: harness) }, before, "nothing changed")
        XCTAssertTrue(composers.isEmpty, "no composer")
        assertNoToastAndNoUndo(harness)
        XCTAssertFalse(harness.controller.window?.isVisible ?? true)
    }

    // MARK: Before the window

    /// An action that launches the app reaches the delegate before there is a main window: it waits, then is applied
    /// once `install` hands over the window, and later ones are applied at once.
    func testAnActionThatComesBeforeTheWindowIsAppliedOnceItIsThere() throws {
        let delegate = AppDelegate(options: LaunchOptions(arguments: ["Paper"]))
        let responder = delegate.notificationResponses
        var activations = 0
        responder.activate = { activations += 1 }
        let id = thread(0)
        deliver(.archive, on: id, to: responder)
        XCTAssertEqual(responder.pending, [.archive(id)], "held")

        // What `install` does once the main window is on screen.
        let harness = try MainWindowHarness()
        defer { harness.close() }
        delegate.answerNotifications(in: harness.controller)
        XCTAssertTrue(responder.pending.isEmpty)
        XCTAssertFalse(try messages(of: id, in: harness).contains { $0.roles.contains(.inbox) }, "applied once the window is there")
        XCTAssertEqual(try operations(in: harness).map(\.change), [.archive])
        XCTAssertEqual(activations, 0)

        deliver(.markRead, on: thread(3), to: responder)
        XCTAssertTrue(responder.pending.isEmpty)
        XCTAssertTrue(try messages(of: thread(3), in: harness).allSatisfy(\.isRead), "later ones at once")
        assertNoToastAndNoUndo(harness)
    }

    func testHeldResponsesAreAppliedInOrderAndOnce() {
        let responder = NewMailNotificationResponder()
        responder.activate = {}
        let first = thread(0), second = thread(1)
        deliver(.archive, on: first, to: responder)
        responder.receive(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: NewMailNotificationResponse.userInfo(for: first))
        deliver(.markRead, on: second, to: responder)
        var applied: [NewMailNotificationResponse] = []
        responder.receiver = { applied.append($0) }
        XCTAssertEqual(applied, [.archive(first), .markRead(second)], "in order; a dismissal is nothing to apply")
        responder.receiver = { _ in XCTFail("each response is applied once") }
        XCTAssertTrue(responder.pending.isEmpty)
    }

    /// A click still opens and selects the conversation in All Inboxes, and brings the app forward.
    func testAClickStillOpensAndSelectsTheConversation() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.strip.select(.account(a.id), notify: true)
        let (responder, activations) = responder(for: harness)
        let id = thread(5)
        responder.receive(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: NewMailNotificationResponse.userInfo(for: id))
        XCTAssertEqual(activations(), 1)
        XCTAssertEqual(harness.controller.strip.scope, .unified)
        harness.spin { harness.list.selectedConversationID == id && harness.list.conversations.contains { $0.id == id } }
        XCTAssertEqual(harness.list.selectedConversationID, id)
        XCTAssertTrue(harness.controller.window?.isVisible ?? false)
        XCTAssertTrue(try operations(in: harness).isEmpty)
    }
}
