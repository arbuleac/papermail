import GRDB
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

    /// Letters whose case Unicode settled after 6.1, whose tables unicode61 folds with: Cherokee is written in what
    /// Unicode 8 made capitals, Georgian Mtavruli (11.0) are the capitals of the old Mkhedruli, Adlam and Greek yot came
    /// later, and New Tai Lue's vowel signs were marks in 6.1. The SQLite store's phrase missed every one of them.
    func testAnAddressWhoseCaseUnicodeSettledAfterTheIndexIsFoundInEveryCase() throws {
        try store.upsertMessages([
            message("c1", in: "c1", from: EmailAddress(address: "ᏣᎳᎩ@example.com"), date: date(10)),
            message("c2", in: "c2", account: accountB, from: EmailAddress(address: "ꮳꮃꭹ@example.com"), date: date(20)),
            message("g1", in: "g1", from: EmailAddress(address: "ᲒᲘᲝᲠᲒᲘ@example.ge"), date: date(30)),
            message("g2", in: "g2", from: EmailAddress(address: "გიორგი@example.ge"), date: date(40)),
            message("d1", in: "d1", from: EmailAddress(address: "𞤀𞤁@example.com"), date: date(50)),
            message("y1", in: "y1", from: EmailAddress(address: "Ϳ@example.gr"), date: date(60)),
            message("n1", in: "n1", from: EmailAddress(address: "ᦰᦱ@example.com"), date: date(70)),
            message("o1", in: "o1", from: EmailAddress(address: "other@example.com"), date: date(80)),
        ])
        XCTAssertEqual(try inboxIDs("ᏣᎳᎩ@example.com"), ["B:c2", "A:c1"])
        XCTAssertEqual(try inboxIDs("ꮳꮃꭹ@example.com"), ["B:c2", "A:c1"])
        XCTAssertEqual(try inboxIDs("გიორგი@example.ge"), ["A:g2", "A:g1"])
        XCTAssertEqual(try inboxIDs("ᲒᲘᲝᲠᲒᲘ@EXAMPLE.GE"), ["A:g2", "A:g1"])
        XCTAssertEqual(try inboxIDs("𞤢𞤣@example.com"), ["A:d1"])
        XCTAssertEqual(try inboxIDs("ϳ@example.gr"), ["A:y1"])
        XCTAssertEqual(try inboxIDs("ᦰᦱ@example.com"), ["A:n1"])
    }

    /// JSON keeps a NUL in a From, and `message(_:)` decodes it whole; the read takes the From out of the JSON in SQL and
    /// must not cut it at the NUL, nor miss an address holding one.
    func testAFromHoldingANulIsReadWhole() throws {
        let named = EmailAddress(name: "Evil\u{0}Name", address: "nul@x.com")
        let inAddress = EmailAddress(address: "nul\u{0}tail@x.com")
        try store.upsertMessages([
            message("n1", in: "n1", from: named, date: date(10)),
            message("n2", in: "n2", from: inAddress, date: date(20)),
        ])
        let found = try store.inboxMessages(from: "nul@x.com")
        XCTAssertEqual(found.first?.from, named)
        XCTAssertEqual(found, [try XCTUnwrap(try store.message(MessageID(accountID: accountA, providerID: "n1")))])
        XCTAssertEqual(try inboxIDs("nul\u{0}tail@x.com"), ["A:n2"])
        XCTAssertEqual(try store.inboxMessages(from: "nul\u{0}tail@x.com").first?.from, inAddress)
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

    /// The summary rows of conversations by id, in every account, as the list reads them: what Always Archive reads of the
    /// conversations it takes mail from, before (their marks of coming back from Later) and after (which left the Inbox).
    func testSummariesOfConversationsByIDInEveryAccount() throws {
        try seedTheLettersMail()
        let a1 = ConversationID(accountID: accountA, providerID: "t-a1"), a3 = ConversationID(accountID: accountA, providerID: "t-a3")
        let b1 = ConversationID(accountID: accountB, providerID: "t-b1")
        let gone = ConversationID(accountID: accountB, providerID: "nowhere")
        let spamOnly = ConversationID(accountID: accountA, providerID: "t-a4")
        let found = try store.summaries(of: [a1, b1, a3, gone, spamOnly, a1])
        XCTAssertEqual(Set(found.keys), [a1, b1, a3], "none for a conversation the store holds no summary of")
        XCTAssertEqual(found[a1], try summary("t-a1"), "the row the list reads")
        XCTAssertEqual(found[b1], try summary("t-b1", account: accountB))
        XCTAssertEqual(found[a3]?.inInbox, false)
        XCTAssertEqual(try store.summaries(of: []), [:])
    }

    /// The undo of Always Archive puts back the marks of the conversations it took back from Later out of the Inbox, in its
    /// transaction, where the inverse steps have put them back in the Inbox; a mark is never put on a conversation still
    /// out of it, nor on one whose newest mail is newer.
    func testASenderRulesUndoPutsBackReturnMarks() throws {
        try seedTheLettersMail()
        let a1 = ConversationID(accountID: accountA, providerID: "t-a1"), b1 = ConversationID(accountID: accountB, providerID: "t-b1")
        let a3 = ConversationID(accountID: accountA, providerID: "t-a3")
        let mark = date(500)
        try store.setSnoozes([a1, b1].map { Snooze.Change(conversationID: $0, until: nil, returnedAt: mark) }, enqueueing: [], at: date(500))
        XCTAssertEqual(try store.summaries(of: [a1, b1]).compactMapValues(\.returnedAt), [a1: mark, b1: mark])
        let a = [MessageID(accountID: accountA, providerID: "a-inbox"), MessageID(accountID: accountA, providerID: "a-other")]
        let b = [MessageID(accountID: accountB, providerID: "b-inbox")]
        try store.setSenderRule(.archive, for: letter.address, accountID: accountA, enqueueing: [
            Operation(accountID: accountA, change: .archive, targets: a, createdAt: date(600)),
            Operation(accountID: accountB, change: .archive, targets: b, createdAt: date(600)),
        ], at: date(600))
        XCTAssertTrue(try store.summaries(of: [a1, b1]).compactMapValues(\.returnedAt).isEmpty, "out of the Inbox, the marks end")

        try store.setSenderRule(nil, for: letter.address, accountID: accountA, enqueueing: [
            Operation(accountID: accountA, change: .moveToInbox, targets: a, createdAt: date(601)),
            Operation(accountID: accountB, change: .moveToInbox, targets: b, createdAt: date(601)),
        ], at: date(601), returnMarks: [a1: mark, b1: mark, a3: mark])
        XCTAssertEqual(try store.summaries(of: [a1, b1, a3]).compactMapValues(\.returnedAt), [a1: mark, b1: mark],
                       "back in both accounts; never on a conversation the undo left archived")
        XCTAssertEqual(try summary("t-a1").returnedAt, mark, "the list sorts it by its mark again")
    }

    /// The outbox writes a live operation again before every attempt and on every narrowing: a conversation's pending
    /// state follows the targets it keeps, so a narrowing settles only the conversations of the targets it drops.
    func testALiveOperationWrittenAgainKeepsItsTargetsPendingAndANarrowingSettlesTheRest() throws {
        try seedTheLettersMail()
        let a = [MessageID(accountID: accountA, providerID: "a-inbox"), MessageID(accountID: accountA, providerID: "a-case")]
        var operation = Operation(accountID: accountA, change: .archive, targets: a, createdAt: date(600))
        try store.enqueue(operation)
        XCTAssertEqual(try summary("t-a1").hasPendingOperations, true)
        XCTAssertEqual(try summary("t-a2").hasPendingOperations, true)

        operation.status = .uncertain
        operation.attempts = 1
        operation.nextAttemptAt = date(700)
        try store.updateOperation(operation)
        XCTAssertEqual(try summary("t-a1").hasPendingOperations, true, "the write-ahead changes nothing the row shows")
        XCTAssertEqual(try summary("t-a2").hasPendingOperations, true)

        operation.targets = [a[1]]
        operation.status = .pending
        try store.updateOperation(operation)
        XCTAssertEqual(try summary("t-a1").hasPendingOperations, false, "its target went out: settled")
        XCTAssertEqual(try summary("t-a2").hasPendingOperations, true)
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10).map(\.targets), [[a[1]]])

        operation.status = .failed
        try store.updateOperation(operation)
        XCTAssertEqual(try summary("t-a2").hasPendingOperations, false)
        XCTAssertEqual(try summary("t-a2").failedOperation, .archive, "given up: the row shows it")
        XCTAssertEqual(try store.message(a[1])?.roles, [.inbox], "and the target it kept is put back")
        XCTAssertEqual(try store.message(a[0])?.roles, [], "never one that went out")
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
        // So does one the index cannot fold as Foundation lowercases it.
        for address in ["ᏣᎳᎩ@example.com", "გიორგი@example.ge"] {
            XCTAssertTrue(try store.inboxMessagesQueryPlan(from: address).contains { $0.contains("conversations_inbox") }, address)
        }
        for address in ["иван@пример.рф", "αλέξης@παράδειγμα.gr", "山田@例え.jp", "i̇lker@x.tr"] {
            XCTAssertTrue(try store.inboxMessagesQueryPlan(from: address).contains { $0.contains("VIRTUAL TABLE INDEX") }, address)
        }
    }

    /// Every capital Foundation lowercases, in an address (`q<capital>z@t.test`): either unicode61's phrase for the
    /// lowercased address finds it, or `indexFoldsLikeLowercasing` sends the read to walk the Inbox; and the walk is taken
    /// only where the phrase would miss. Measured against the tokenizer itself, with `message_fts`'s options.
    func testTheReadWalksExactlyWhereTheIndexFoldsOtherwise() throws {
        let capitals = (UInt32(0)...0x10FFFF).compactMap(Unicode.Scalar.init).filter(\.properties.changesWhenLowercased)
        XCTAssertGreaterThan(capitals.count, 1_000)
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE t USING fts5(x, tokenize='unicode61 remove_diacritics 2')")
            for (index, capital) in capitals.enumerated() {
                try db.execute(sql: "INSERT INTO t(rowid, x) VALUES (?, ?)", arguments: [index, "q\(Character(capital))z@t.test"])
            }
        }
        var missed: [String] = []
        var walkedForNothing: [String] = []
        try queue.read { db in
            for (index, capital) in capitals.enumerated() {
                let sender = SenderRule.normalizedAddress("q\(Character(capital))z@t.test")
                let local = String(sender[..<sender.lastIndex(of: "@")!])
                let found = try Int64.fetchAll(db, sql: "SELECT rowid FROM t WHERE t MATCH ?",
                                               arguments: ["x : \"\(FullTextIndex.stringContent(local))\""]).contains(Int64(index))
                let label = String(format: "U+%04X", capital.value)
                switch (found, MessageTable.indexFoldsLikeLowercasing(sender)) {
                case (false, true): missed.append(label)
                case (true, false): walkedForNothing.append(label)
                default: break
                }
            }
        }
        XCTAssertEqual(missed, [], "the phrase would miss these and the read would not walk")
        XCTAssertEqual(walkedForNothing, [], "the read would walk for these, which the phrase finds")
    }

    /// `FullTextMatcher.startsToken` reads a scalar as SQLite's unicode61 does where Unicode changed its category after
    /// 6.1, so both stores split an address (and a search) there alike, and a phrase never ends up with no word.
    func testScalarsWhoseCategoryChangedSinceTheIndexSplitAsItDoes() throws {
        let changed: [UInt32] = [0x1885, 0x1886] + Array(0x19B0...0x19C0) + [0x19C8, 0x19C9, 0x1CF2, 0x1CF3, 0xFFFE, 0xFFFF]
        let neighbours: [UInt32] = [0x1884, 0x1887, 0x19AB, 0x19C1, 0x19C7, 0x19CA, 0x1CF1, 0x1CF4, 0xFFFD, 0x41, 0x300]
        let queue = try DatabaseQueue()
        let scalars = (changed + neighbours).compactMap(Unicode.Scalar.init)
        try queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE t USING fts5(x, tokenize='unicode61 remove_diacritics 2')")
            try db.execute(sql: "CREATE VIRTUAL TABLE v USING fts5vocab(t, 'instance')")
            for scalar in scalars {
                try db.execute(sql: "INSERT INTO t(rowid, x) VALUES (?, ?)", arguments: [Int64(scalar.value), "q\(Character(scalar))z"])
            }
        }
        try queue.read { db in
            for scalar in scalars {
                let terms = try Int.fetchOne(db, sql: "SELECT count(*) FROM v WHERE doc = ?", arguments: [Int64(scalar.value)]) ?? 0
                let label = String(format: "U+%04X", scalar.value)
                XCTAssertEqual(FullTextMatcher.tokens("q\(Character(scalar))z").count, terms, label)
            }
        }
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
