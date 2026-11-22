import XCTest
@testable import PaperCore

/// The `MailStoring` contract for the read Always Archive Mail from This Sender makes on the click
/// (`inboxMessages(from:)`, docs/ARCHITECTURE.md "Rules"), and for its one transaction (`setSenderRule(enqueueing:)`)
/// taking the sender's mail in several accounts while the rule stays on one. Written as an extension so
/// `SQLiteMailStoreContractTests` inherits every case and both stores are held to the same semantics.
extension MailStoreContractTests {
    private var letter: EmailAddress { EmailAddress(name: "Weekly Letter", address: "news@letter.example") }

    private func inboxIDs(_ address: String) throws -> [String] {
        try store.inboxMessages(from: address).map { "\($0.id.accountID == accountA ? "A" : "B"):\($0.id.providerID)" }
    }

    /// Every kind of mail the sender has, in both accounts: only what the Inbox holds comes back, whatever the address's
    /// case or the name beside it, newest first.
    private func seedTheLettersMail() throws {
        try store.upsertMessages([
            message("a-inbox", in: "t-a1", from: letter, date: date(100)),
            message("a-case", in: "t-a2", from: EmailAddress(name: "The Letter", address: "News@Letter.EXAMPLE"), date: date(90)),
            message("a-spaced", in: "t-a2", from: EmailAddress(address: " news@letter.example\n"), date: date(80)),
            message("a-archived", in: "t-a3", from: letter, date: date(70), roles: []),
            message("a-spam", in: "t-a4", from: letter, date: date(60), roles: [.spam]),
            message("a-spam-inbox", in: "t-a4", from: letter, date: date(59), roles: [.inbox, .spam]),
            message("a-trash", in: "t-a5", from: letter, date: date(50), roles: [.trash]),
            message("a-trash-inbox", in: "t-a5", from: letter, date: date(49), roles: [.inbox, .trash]),
            message("a-snoozed", in: "t-a6", from: letter, date: date(40), roles: []),
            message("a-other", in: "t-a1", from: EmailAddress(name: "Weekly Letter", address: "news@letter.example.org"), date: date(110)),
            message("a-longer", in: "t-a7", from: EmailAddress(address: "the.news@letter.example"), date: date(111)),
            message("a-name", in: "t-a8", from: EmailAddress(name: "news@letter.example", address: "someone@else.example"), date: date(112)),
            message("a-own-sent", in: "t-a9", from: letter, date: date(30), roles: [.sent]),
            message("a-own-draft", in: "t-a9", from: letter, date: date(29), roles: [.drafts]),
            message("a-own-sent-inbox", in: "t-a9", from: letter, date: date(28), roles: [.inbox, .sent]),
            message("a-nobody", in: "t-a10", from: nil, date: date(27)),
            message("b-inbox", in: "t-b1", account: accountB, from: letter, date: date(95)),
            message("b-upper", in: "t-b2", account: accountB, from: EmailAddress(address: "NEWS@LETTER.EXAMPLE"), date: date(85)),
            message("b-archived", in: "t-b3", account: accountB, from: letter, date: date(75), roles: []),
        ])
        try store.setSnoozes([Snooze.Change(conversationID: ConversationID(accountID: accountA, providerID: "t-a6"), until: date(10_000))],
                             enqueueing: [], at: date(200))
    }

    func testTheSendersInboxMailInEveryAccountWhateverTheCaseOrName() throws {
        try seedTheLettersMail()
        let expected = ["A:a-inbox", "B:b-inbox", "A:a-case", "B:b-upper", "A:a-spaced", "A:a-own-sent-inbox"]
        XCTAssertEqual(try inboxIDs("news@letter.example"), expected,
                       "Inbox only, newest first; never Spam, the Trash, the archive or a snoozed conversation's mail")
        XCTAssertEqual(try inboxIDs("  NEWS@Letter.Example "), expected, "the address as a rule normalizes it")
        XCTAssertEqual(try inboxIDs("letter.example"), [], "a part of an address is not the address")
        XCTAssertEqual(try inboxIDs("news@letter"), [])
        XCTAssertEqual(try inboxIDs(""), [])
        XCTAssertEqual(try inboxIDs("   "), [])
        XCTAssertEqual(try inboxIDs("someone@else.example"), ["A:a-name"], "the address, not the name beside it")
        XCTAssertEqual(try store.inboxMessages(from: "news@letter.example").first, try store.message(MessageID(accountID: accountA, providerID: "a-inbox")),
                       "whole messages, as `message(_:)` reads them")
    }

    func testAnAddressTheIndexFoldsOrCannotHoldIsStillFoundExactly() throws {
        // Letters outside ASCII, which the full-text index folds further than an address compares (zoë and zoe are two
        // senders), and an address of nothing but punctuation, which the index holds no word of.
        let accented = EmailAddress(name: "Zoë", address: "zoë@exämple.test")
        let marks = EmailAddress(address: "+-+@!!")
        try store.upsertMessages([
            message("z1", in: "z1", from: accented, date: date(10)),
            message("z2", in: "z2", account: accountB, from: EmailAddress(address: "ZOË@EXÄMPLE.TEST"), date: date(20)),
            message("z3", in: "z3", from: EmailAddress(address: "zoe@example.test"), date: date(30)),
            message("z4", in: "z4", from: accented, date: date(40), roles: []),
            message("m1", in: "m1", from: marks, date: date(50)),
            message("m2", in: "m2", from: EmailAddress(address: "+-+@!!!"), date: date(60)),
        ])
        XCTAssertEqual(try inboxIDs("zoë@exämple.test"), ["B:z2", "A:z1"], "without its accents an address is another one")
        XCTAssertEqual(try inboxIDs("+-+@!!"), ["A:m1"])
    }

    func testAMessageThatLeavesTheInboxOrChangesSenderLeavesTheRead() throws {
        try seedTheLettersMail()
        try store.enqueue(Operation(accountID: accountA, change: .archive, targets: [MessageID(accountID: accountA, providerID: "a-inbox")]))
        var renamed = message("b-inbox", in: "t-b1", account: accountB, from: EmailAddress(address: "other@letter.example"), date: date(95))
        renamed.isRead = false
        try store.upsertMessages([renamed])
        try store.deleteMessages([MessageID(accountID: accountA, providerID: "a-case")])
        XCTAssertEqual(try inboxIDs("news@letter.example"), ["B:b-upper", "A:a-spaced", "A:a-own-sent-inbox"])
        XCTAssertEqual(try inboxIDs("other@letter.example"), ["B:b-inbox"], "found under the From it has now")
    }

    /// Always Archive's one transaction: an operation per account the sender's mail is in, each applied as `enqueue`
    /// applies it, and the rule on the account it was set from alone. Its undo, the inverse in one transaction again.
    func testOneTransactionArchivesInEveryAccountAndKeepsTheRuleOnOne() throws {
        try seedTheLettersMail()
        let a = ["a-inbox", "a-case"].map { MessageID(accountID: accountA, providerID: $0) }
        let b = ["b-inbox", "b-upper"].map { MessageID(accountID: accountB, providerID: $0) }
        try store.setSenderRule(.archive, for: "News@Letter.example", accountID: accountA, enqueueing: [
            Operation(accountID: accountA, change: .archive, targets: a, createdAt: date(300)),
            Operation(accountID: accountB, change: .archive, targets: b, createdAt: date(300)),
        ], at: date(300))

        XCTAssertEqual(try store.senderRules().map { "\($0.accountID.rawValue) \($0.address) \($0.action) \($0.sync)" },
                       ["acct-a news@letter.example archive creating"], "the rule is the one account's")
        for id in a + b { XCTAssertEqual(try store.message(id)?.roles, [], "\(id.providerID) archived") }
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10).map(\.targets), [a])
        XCTAssertEqual(try store.pendingOperations(accountID: accountB, limit: 10).map(\.targets), [b])
        XCTAssertEqual(try summary("t-b1", account: accountB).inInbox, false, "every account's summary refreshed")
        XCTAssertEqual(try summary("t-a2").inInbox, true, "a conversation keeps the Inbox for mail not taken")
        XCTAssertEqual(try inboxIDs("news@letter.example"), ["A:a-spaced", "A:a-own-sent-inbox"])

        try store.setSenderRule(nil, for: "news@letter.example", accountID: accountA, enqueueing: [
            Operation(accountID: accountA, change: .moveToInbox, targets: a, createdAt: date(301)),
            Operation(accountID: accountB, change: .moveToInbox, targets: b, createdAt: date(301)),
        ], at: date(301))
        XCTAssertTrue(try store.senderRules().isEmpty)
        for id in a + b { XCTAssertEqual(try store.message(id)?.roles, [.inbox], "\(id.providerID) back") }
        XCTAssertEqual(try store.pendingOperations(accountID: accountB, limit: 10).map(\.change), [.archive, .moveToInbox])
        XCTAssertEqual(try summary("t-b1", account: accountB).inInbox, true)
    }
}

/// The SQLite store answers the read from the full-text index, never by walking the mailbox, and writes Always Archive's
/// accounts and rule in one transaction.
final class SQLiteSenderInboxTests: XCTestCase {
    func testTheReadTakesItsCandidatesFromTheIndex() throws {
        let store = try SQLiteMailStore.inMemory()
        let plan = try store.inboxMessagesQueryPlan(from: "news@letter.example")
        XCTAssertTrue(plan.contains { $0.contains("VIRTUAL TABLE INDEX") }, "\(plan)")
        XCTAssertTrue(plan.contains { $0.contains("SEARCH messages USING INTEGER PRIMARY KEY") }, "\(plan)")
        XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN messages") || $0.hasPrefix("SCAN conversations") }, "\(plan)")

        // Letters outside ASCII too: the index folds them.
        XCTAssertTrue(try store.inboxMessagesQueryPlan(from: "zoë@exämple.test").contains { $0.contains("VIRTUAL TABLE INDEX") })
        // An address the index holds no word of walks the Inbox through its index, still not the mailbox.
        let walk = try store.inboxMessagesQueryPlan(from: "+-+@!!")
        XCTAssertTrue(walk.contains { $0.contains("USING INDEX conversations_inbox") || $0.contains("USING COVERING INDEX conversations_inbox") },
                      "\(walk)")
        XCTAssertTrue(walk.contains { $0.contains("messages_by_conversation") }, "\(walk)")
        XCTAssertFalse(walk.contains { $0.hasPrefix("SCAN") }, "\(walk)")
    }

    /// A rule the store refuses (an account it no longer has) leaves every account's mail as it was: the operations
    /// before it in the transaction are rolled back with it.
    func testARefusedRuleTakesNoAccountsMail() throws {
        let store = try SQLiteMailStore.inMemory()
        let a = AccountID("acct-a"), b = AccountID("acct-b")
        for (index, id) in [a, b].enumerated() {
            try store.upsertAccount(Account(id: id, kind: .gmail, email: "me\(index)@example.com", displayName: "Me",
                                            addedAt: Date(timeIntervalSince1970: Double(index))))
        }
        let letter = EmailAddress(address: "news@letter.example")
        let messages = [a, b].map { id in
            MessageMetadata(id: MessageID(accountID: id, providerID: "m"), conversationID: ConversationID(accountID: id, providerID: "t"),
                            subject: "Issue", snippet: "", from: letter, date: Date(timeIntervalSince1970: 100), roles: [.inbox],
                            isRead: false, isStarred: false, hasAttachments: false)
        }
        try store.upsertMessages(messages)
        XCTAssertThrowsError(try store.setSenderRule(.archive, for: letter.address, accountID: AccountID("gone"), enqueueing: [a, b].map {
            Operation(accountID: $0, change: .archive, targets: [MessageID(accountID: $0, providerID: "m")])
        }, at: Date()))
        XCTAssertEqual(try store.inboxMessages(from: letter.address).count, 2, "both still in their Inbox")
        XCTAssertTrue(try store.pendingOperations(accountID: a, limit: 10).isEmpty)
        XCTAssertTrue(try store.pendingOperations(accountID: b, limit: 10).isEmpty)
        XCTAssertTrue(try store.senderRules().isEmpty)
    }

    /// A local part many senders share (`news@`, `noreply@`) is too common to narrow by alone: past
    /// `localPartCandidates` messages the whole address is the phrase, and the answer is the same.
    func testALocalPartManySendersShareIsNarrowedByTheWholeAddress() throws {
        let store = try SQLiteMailStore.inMemory()
        let account = AccountID("acct-a")
        try store.upsertAccount(Account(id: account, kind: .gmail, email: "me@example.com", displayName: "Me", addedAt: Date()))
        func mail(_ index: Int, from address: String) -> MessageMetadata {
            MessageMetadata(id: MessageID(accountID: account, providerID: "m\(index)"),
                            conversationID: ConversationID(accountID: account, providerID: "t\(index)"), subject: "Issue", snippet: "",
                            from: EmailAddress(address: address), date: Date(timeIntervalSince1970: Double(index)), roles: [.inbox],
                            isRead: true, isStarred: false, hasAttachments: false)
        }
        let others = (0..<MessageTable.localPartCandidates).map { mail($0, from: "news@sender\($0 % 50).example") }
        let ours = (0..<3).map { mail(10_000 + $0, from: "News@Letter.example") }
        try store.upsertMessages(others + ours)
        XCTAssertEqual(try store.inboxMessages(from: "news@letter.example").map(\.id.providerID), ["m10002", "m10001", "m10000"])
        XCTAssertEqual(try store.inboxMessages(from: "news@sender7.example").count, MessageTable.localPartCandidates / 50)
    }
}
