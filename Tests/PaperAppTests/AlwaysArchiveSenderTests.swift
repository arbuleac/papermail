import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// Always Archive Mail from This Sender empties every Inbox of that sender's mail (spec §5.52): set from the list's
/// context menu, the Message menu or a reader window, after the permission's alert or at once, it archives their mail in
/// the Inbox of both accounts in one step, rows leaving in both, while the rule stays on the account of the message it
/// was set from; the toast counts the rows that left the Inbox when they go beyond the open one (never one that keeps
/// someone else's mail there), and Z, or ⌘Z long after, puts back the previous rule, every message in its own account
/// and the rows' marks of coming back from Later. Block Sender still acts on its conversation alone. The engine never
/// starts and no test reaches a server: the grant and the sign-in are the controller's callbacks.
@MainActor
final class AlwaysArchiveSenderTests: XCTestCase {
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB
    private let letter = EmailAddress(name: "Weekly Letter", address: "news@letter.example")
    private var folder: URL!

    override func setUp() {
        super.setUp()
        // Reader windows keep their quick replies' drafts; never in the user's folders.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperAlwaysArchive-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Fixture

    /// The letter's mail across both accounts, newest at the top of the Inbox: in each Inbox (one under another case
    /// and name), beside someone else's mail in one conversation, and out of the Inbox in every other way.
    private struct Letters {
        let inbox: [MessageID]
        let leaving: [ConversationID]
        let mixed: ConversationID
        let untouched: [MessageID: Set<MailboxRole>]
        let snoozed: ConversationID
        var open: ConversationID { leaving[0] }
    }

    private func id(_ account: Account, _ providerID: String) -> MessageID {
        MessageID(accountID: account.id, providerID: providerID)
    }

    private func mail(_ providerID: String, in conversation: String, _ account: Account, from: EmailAddress? = nil, ago: TimeInterval,
                      roles: Set<MailboxRole> = [.inbox]) -> MessageMetadata {
        MessageMetadata(id: id(account, providerID), conversationID: ConversationID(accountID: account.id, providerID: conversation),
                        subject: "The weekly letter", snippet: "This week", from: from ?? letter,
                        to: [EmailAddress(address: account.email)], date: Date().addingTimeInterval(-ago), roles: roles,
                        isRead: false, isStarred: false, hasAttachments: false)
    }

    private func seedLetters(_ harness: MainWindowHarness) throws -> Letters {
        let store = harness.environment.store
        let ben = EmailAddress(name: "Ben", address: "ben@example.com")
        try store.upsertMessages([
            mail("a1", in: "letter-a1", a, ago: 10),
            mail("b1", in: "letter-b1", b, ago: 15),
            mail("a2", in: "letter-a2", a, from: EmailAddress(name: "The Letter", address: "News@Letter.Example"), ago: 20),
            mail("mixed-news", in: "letter-mixed", a, ago: 25),
            mail("mixed-ben", in: "letter-mixed", a, from: ben, ago: 30),
            mail("b2", in: "letter-b2", b, from: EmailAddress(address: "NEWS@letter.example"), ago: 35),
            mail("old", in: "letter-old", a, ago: 40, roles: []),
            mail("spam", in: "letter-spam", a, ago: 45, roles: [.spam]),
            mail("trash", in: "letter-trash", b, ago: 50, roles: [.trash]),
            mail("later", in: "letter-later", a, ago: 55, roles: []),
        ])
        let snoozed = ConversationID(accountID: a.id, providerID: "letter-later")
        try store.setSnoozes([Snooze.Change(conversationID: snoozed, until: Date().addingTimeInterval(86_400))], enqueueing: [], at: Date())
        let leaving = [("letter-a1", a), ("letter-a2", a), ("letter-b1", b), ("letter-b2", b)]
            .map { ConversationID(accountID: $0.1.id, providerID: $0.0) }
        harness.spin { Set(leaving).isSubset(of: Set(harness.list.conversations.map(\.id))) }
        return Letters(inbox: [id(a, "a1"), id(a, "a2"), id(a, "mixed-news"), id(b, "b1"), id(b, "b2")], leaving: leaving,
                       mixed: ConversationID(accountID: a.id, providerID: "letter-mixed"),
                       untouched: [id(a, "old"): [], id(a, "spam"): [.spam], id(b, "trash"): [.trash], id(a, "later"): [],
                                   id(a, "mixed-ben"): [.inbox]],
                       snoozed: snoozed)
    }

    private func open(_ id: ConversationID, in harness: MainWindowHarness) {
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentConversationID == id && !harness.reader.currentMessages.isEmpty }
    }

    private func roles(_ id: MessageID, _ harness: MainWindowHarness) throws -> Set<MailboxRole>? {
        try harness.environment.store.message(id)?.roles
    }

    private func rules(_ harness: MainWindowHarness) throws -> [String] {
        try harness.environment.store.senderRules().map { "\($0.accountID.rawValue) \($0.address) \($0.action) \($0.sync)" }
    }

    /// The four rows that leave, the mixed conversation's staying: what the toast says, whatever the window's width.
    private let gmailToast = "Archived 4 · Gmail filter for news@letter.example"
    private let outlookToast = "Archived 4 · Outlook rule for news@letter.example"

    private func listed(_ harness: MainWindowHarness) -> Set<ConversationID> {
        Set(harness.list.conversations.map(\.id))
    }

    /// Every message of the letter's in either Inbox is archived, one operation per account, the rest as it was, the rows
    /// gone from the unified Inbox but the one someone else's mail keeps there.
    private func assertArchivedEverywhere(_ letters: Letters, _ harness: MainWindowHarness, file: StaticString = #filePath,
                                          line: UInt = #line) throws {
        for message in letters.inbox {
            XCTAssertEqual(try roles(message, harness), [], "\(message.providerID) archived", file: file, line: line)
        }
        for (message, before) in letters.untouched {
            XCTAssertEqual(try roles(message, harness), before, "\(message.providerID) as it was", file: file, line: line)
        }
        let store = harness.environment.store
        XCTAssertEqual(try store.pendingOperations(accountID: a.id, limit: 10).map { $0.targets.map(\.providerID) },
                       [["a1", "a2", "mixed-news"]], file: file, line: line)
        XCTAssertEqual(try store.pendingOperations(accountID: b.id, limit: 10).map { $0.targets.map(\.providerID) }, [["b1", "b2"]],
                       file: file, line: line)
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [letters.snoozed], "Later's mail stays snoozed", file: file, line: line)
        harness.spin { self.listed(harness).isDisjoint(with: letters.leaving) }
        XCTAssertTrue(listed(harness).isDisjoint(with: letters.leaving), "the rows leave, in both accounts", file: file, line: line)
        XCTAssertTrue(listed(harness).contains(letters.mixed), "someone else's mail keeps its conversation in the Inbox",
                      file: file, line: line)
    }

    private func assertBack(_ letters: Letters, _ harness: MainWindowHarness, file: StaticString = #filePath, line: UInt = #line) throws {
        for message in letters.inbox {
            XCTAssertEqual(try roles(message, harness), [.inbox], "\(message.providerID) back", file: file, line: line)
        }
        harness.spin { Set(letters.leaving).isSubset(of: self.listed(harness)) }
        XCTAssertTrue(Set(letters.leaving).isSubset(of: listed(harness)), "every row back, in both accounts", file: file, line: line)
    }

    // MARK: From the list

    func testFromTheListItArchivesTheSendersMailInEveryInboxAndZBringsItBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let letters = try seedLetters(harness)
        open(letters.open, in: harness)
        let item = try XCTUnwrap(harness.controller.selectionContextMenu().items.first {
            $0.action == #selector(MainWindowController.alwaysArchiveSender(_:))
        })
        XCTAssertTrue(harness.controller.validateMenuItem(item))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        harness.spin { (try? self.rules(harness).isEmpty) == false }

        XCTAssertEqual(try rules(harness), ["acct-a news@letter.example archive creating"], "the rule is the Gmail account's alone")
        try assertArchivedEverywhere(letters, harness)
        XCTAssertEqual(harness.toastMessage, gmailToast, "four rows left; the mixed one stays and is not counted")
        XCTAssertEqual(harness.toasts.visibleKind, .undoable)
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Always Archive Mail from This Sender")

        // The same rule again is the rule the sender has: nothing more to do.
        let operations = try harness.environment.store.pendingOperations(accountID: a.id, limit: 10).count
        XCTAssertTrue(harness.controller.setSenderRule(.archive, from: id(a, "a1")))
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(try harness.environment.store.pendingOperations(accountID: a.id, limit: 10).count, operations)
        XCTAssertEqual(harness.toastMessage, gmailToast)

        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertTrue(try rules(harness).isEmpty, "no rule before: a rule not on the server yet just goes")
        try assertBack(letters, harness)
        XCTAssertEqual(try harness.environment.store.pendingOperations(accountID: b.id, limit: 10).map(\.change), [.archive, .moveToInbox],
                       "each account's own share comes back in that account")
        XCTAssertEqual(harness.toastMessage, "Undid Always Archive Mail from This Sender")
        XCTAssertEqual(harness.list.selectedConversationIDs, [letters.open], "the conversation it was set from is selected again")
    }

    /// ⌘Z long after the toast went: the messages deleted since have nothing to put back, the rest come back.
    func testADeepUndoPutsBackWhatIsStillThere() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let letters = try seedLetters(harness)
        open(letters.open, in: harness)
        harness.controller.alwaysArchiveSender(nil)
        harness.spin { (try? self.rules(harness).isEmpty) == false }
        try harness.environment.store.deleteMessages([id(b, "b2")])
        harness.toasts.dismiss()
        harness.controller.performUndo(harness.controller.commandZTarget(textCanUndo: false))

        XCTAssertTrue(try rules(harness).isEmpty)
        for message in letters.inbox where message != id(b, "b2") {
            XCTAssertEqual(try roles(message, harness), [.inbox], "\(message.providerID) back")
        }
        let undo = try harness.environment.store.pendingOperations(accountID: b.id, limit: 10).filter { $0.change == .moveToInbox }
        XCTAssertEqual(undo.map { $0.targets.map(\.providerID) }, [["b1"]], "nothing asked of the provider for the deleted message")
    }

    /// Only the open conversation's mail in the Inbox: the toast stays as it was.
    func testWhenTheSenderHasNoOtherInboxMailTheToastIsTheRulesAlone() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let first = try XCTUnwrap(harness.list.conversations.first { $0.id.accountID == a.id }).id
        open(first, in: harness)
        let target = try XCTUnwrap(harness.reader.senderRuleTarget)
        let address = SenderRule.normalizedAddress(try XCTUnwrap(target.from?.address))
        XCTAssertEqual(try harness.environment.store.inboxMessages(from: address).map(\.conversationID), [first], "their only Inbox mail")
        harness.controller.alwaysArchiveSender(nil)
        harness.spin { (try? self.rules(harness).isEmpty) == false }
        XCTAssertEqual(harness.toastMessage, "Gmail will archive mail from \(address)")
        XCTAssertEqual(try roles(target.id, harness)?.contains(.inbox), false)
        XCTAssertTrue(try harness.environment.store.pendingOperations(accountID: b.id, limit: 10).isEmpty, "nothing in the other account")
    }

    // MARK: From a reader window

    /// From a reader window, on the Microsoft account, whose server blocks the letter already: the rule replaces the block
    /// there and nowhere else, both Inboxes are emptied of the letter, the toast is the window's, and its Z puts the block
    /// and every message back.
    func testFromAReaderWindowItReplacesTheRuleAndEmptiesBothInboxes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let letters = try seedLetters(harness)
        let store = harness.environment.store
        try store.replaceServerSenderRules(accountID: b.id, with: [ServerSenderRule(serverID: "r1", address: letter.address, action: .trash)],
                                           readAt: Date())
        let opened = ConversationID(accountID: b.id, providerID: "letter-b1")
        let reader = try XCTUnwrap(harness.controller.openInNewWindow(opened))
        defer { reader.close() }
        harness.spin { reader.conversation.senderRuleTarget != nil }
        let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.alwaysArchiveSender(_:)), keyEquivalent: "")
        XCTAssertTrue(reader.validateMenuItem(item), "the other rule replaces the block")
        reader.alwaysArchiveSender(nil)
        harness.spin { (try? self.rules(harness)) == ["acct-b news@letter.example archive replacing"] }

        XCTAssertEqual(try rules(harness), ["acct-b news@letter.example archive replacing"], "on the Outlook account alone")
        try assertArchivedEverywhere(letters, harness)
        XCTAssertEqual(reader.toastView.slip?.message, outlookToast, "the window's step, its toast there")
        XCTAssertTrue(harness.controller.readerWindows.contains { $0 === reader }, "the window stays")

        XCTAssertTrue(reader.perform(.undo))
        XCTAssertEqual(try harness.environment.store.senderRules().map { "\($0.accountID.rawValue) \($0.action)" }, ["acct-b trash"],
                       "the block back, which the engine finds the server holds")
        try assertBack(letters, harness)
    }

    // MARK: After the permission's alert

    func testAfterThePermissionsAlertAndSignInEveryInboxIsEmptiedAndCancelMovesNothing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let letters = try seedLetters(harness)
        open(letters.open, in: harness)
        var granted = false
        harness.controller.hasRulesPermission = { _ in granted }
        var answer = 1
        var titles: [String] = []
        harness.controller.presentAlert = { alert, _, done in
            titles.append(alert.title)
            done(answer)
        }
        var finish: ((Bool) -> Void)?
        harness.controller.onConnectRules = { _, done in finish = done }

        // Cancel: nothing stored, nothing moved, in either account.
        harness.controller.alwaysArchiveSender(nil)
        harness.spin { titles.count == 1 }
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(titles, ["Save sender rules in Gmail?"])
        XCTAssertTrue(try rules(harness).isEmpty)
        for message in letters.inbox { XCTAssertEqual(try roles(message, harness), [.inbox]) }
        XCTAssertTrue(try harness.environment.store.pendingOperations(accountID: b.id, limit: 10).isEmpty)

        // Continue, then the sign-in that grants it.
        answer = 0
        harness.controller.alwaysArchiveSender(nil)
        harness.spin { finish != nil }
        XCTAssertTrue(try rules(harness).isEmpty, "nothing while the browser asks")
        granted = true
        finish?(true)
        harness.spin { (try? self.rules(harness).isEmpty) == false }
        XCTAssertEqual(try rules(harness), ["acct-a news@letter.example archive creating"])
        try assertArchivedEverywhere(letters, harness)
        XCTAssertEqual(harness.toastMessage, gmailToast)
        harness.controller.performUndo(harness.controller.zTarget)
        try assertBack(letters, harness)
    }

    // MARK: Block Sender

    /// Block Sender is unchanged: the sender's mail in its conversation alone goes to the Trash.
    func testBlockSenderStillActsOnItsConversationAlone() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let letters = try seedLetters(harness)
        open(letters.open, in: harness)
        harness.controller.blockSender(nil)
        harness.spin { (try? self.rules(harness).isEmpty) == false }
        XCTAssertEqual(try rules(harness), ["acct-a news@letter.example trash creating"])
        XCTAssertEqual(try roles(id(a, "a1"), harness)?.contains(.trash), true)
        for message in letters.inbox where message != id(a, "a1") {
            XCTAssertEqual(try roles(message, harness), [.inbox], "\(message.providerID) stays in its Inbox")
        }
        XCTAssertEqual(harness.toastMessage, "Gmail will block news@letter.example")
        XCTAssertTrue(try harness.environment.store.pendingOperations(accountID: b.id, limit: 10).isEmpty)
    }

    // MARK: Rows that stay

    /// The sender's only other Inbox mail sits beside someone else's: their message is archived, but the row stays, so the
    /// step took no row beyond the open one and the toast is the rule's alone.
    func testAConversationThatKeepsSomeoneElsesMailIsNotCounted() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let store = harness.environment.store
        let ben = EmailAddress(name: "Ben", address: "ben@example.com")
        try store.upsertMessages([
            mail("solo", in: "letter-solo", a, ago: 10),
            mail("mixed-news", in: "letter-mixed", b, ago: 20),
            mail("mixed-ben", in: "letter-mixed", b, from: ben, ago: 30),
        ])
        let solo = ConversationID(accountID: a.id, providerID: "letter-solo")
        let mixed = ConversationID(accountID: b.id, providerID: "letter-mixed")
        open(solo, in: harness)
        harness.controller.alwaysArchiveSender(nil)
        harness.spin { (try? self.rules(harness).isEmpty) == false }

        XCTAssertEqual(try roles(id(b, "mixed-news"), harness), [], "their mail in the other account archived")
        XCTAssertEqual(try roles(id(b, "mixed-ben"), harness), [.inbox])
        harness.spin { !self.listed(harness).contains(solo) }
        XCTAssertTrue(listed(harness).contains(mixed), "the row stays for Ben's mail")
        XCTAssertEqual(harness.toastMessage, "Gmail will archive mail from news@letter.example", "no row left beyond the open one")
    }

    // MARK: Back from Later

    /// Rows that had come back from Later sort under Today by their mark, which leaving the Inbox ends: Z puts every mark
    /// back with its row, in both accounts, listed or not, as Z after E does.
    func testZPutsBackTheMarksOfRowsThatCameBackFromLater() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let letters = try seedLetters(harness)
        let store = harness.environment.store
        let back = Date().addingTimeInterval(-2)
        let marked = [letters.leaving[1], letters.leaving[3]] // one in each account
        try store.setSnoozes(marked.map { Snooze.Change(conversationID: $0, until: nil, returnedAt: back) }, enqueueing: [], at: Date())
        func marks() throws -> [ConversationID: Date] {
            try store.summaries(of: letters.leaving).compactMapValues(\.returnedAt)
        }
        let before = try marks()
        XCTAssertEqual(Set(before.keys), Set(marked), "back from Later")
        open(letters.open, in: harness)
        harness.controller.alwaysArchiveSender(nil)
        harness.spin { (try? self.rules(harness).isEmpty) == false }
        XCTAssertTrue(try marks().isEmpty, "out of the Inbox, no longer back from Later")

        harness.controller.performUndo(harness.controller.zTarget)
        try assertBack(letters, harness)
        XCTAssertEqual(try marks(), before, "every mark back with its row")
        harness.spin { self.listed(harness).contains(marked[0]) }
        XCTAssertNotNil(harness.list.conversations.first { $0.id == marked[0] }?.returnedAt, "the row sorts by its mark again")
    }

    // MARK: Words

    func testTheToastCountsTheRowsAndNamesTheRuleWithTheAddressLast() {
        XCTAssertEqual(SenderRuleCopy.toast(.archive, address: "news@letter.example", kind: .gmail, archived: 12),
                       "Archived 12 · Gmail filter for news@letter.example")
        XCTAssertEqual(SenderRuleCopy.toast(.archive, address: "news@letter.example", kind: .microsoft, archived: 1),
                       "Archived 1 · Outlook rule for news@letter.example")
        XCTAssertEqual(SenderRuleCopy.toast(.archive, address: "news@letter.example", kind: .gmail, archived: 1_234),
                       "Archived \(1_234.formatted()) · Gmail filter for news@letter.example")
        XCTAssertEqual(SenderRuleCopy.toast(.archive, address: "news@letter.example", kind: .gmail, archived: nil),
                       "Gmail will archive mail from news@letter.example")
        XCTAssertEqual(SenderRuleCopy.toast(.archive, address: "news@letter.example", kind: .gmail, archived: 0),
                       "Gmail will archive mail from news@letter.example")
        XCTAssertEqual(SenderRuleCopy.toast(.trash, address: "deals@shop.example", kind: .gmail, archived: 5),
                       "Gmail will block deals@shop.example", "Block counts nothing")
    }

    /// The list's toast, beside Undo and Z, at the default width and the widest: the count and the rule always show whole,
    /// and only the address can be cut, never a word before it; at the widest its start shows too.
    func testTheCountAndTheRuleShowWholeAtTheDefaultAndTheWidestListWidth() {
        func fits(_ words: String, in width: CGFloat) -> Bool {
            let slip = QuireSlipView(kind: .undoable, message: words, symbolName: Quire.Icon.alwaysArchiveSender)
            _ = slip.setAction("Undo", keycap: "Z")
            return slip.intrinsicContentSize.width <= width - 2 * Quire.Layout.Toast.sideMargin
        }
        for width in [Quire.Layout.List.defaultWidth, Quire.Layout.List.maxWidth] {
            for kind in [ProviderKind.gmail, .microsoft] {
                for count in [1, 12, 999, 1_234] {
                    let words = SenderRuleCopy.toast(.archive, address: letter.address, kind: kind, archived: count)
                    let beforeAddress = String(words[..<words.range(of: " for ")!.lowerBound])
                    XCTAssertTrue(fits(beforeAddress, in: width), "“\(beforeAddress)” whole at \(width) pt")
                }
            }
        }
        let widest = SenderRuleCopy.toast(.archive, address: letter.address, kind: .microsoft, archived: 1_234)
        XCTAssertTrue(fits(String(widest.prefix(widest.count - letter.address.count + 6)), in: Quire.Layout.List.maxWidth),
                      "the address's start too at the widest list")
    }
}
