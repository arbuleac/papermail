import XCTest
import SSCore

/// The `MailStoring` contract for the arrival rules (roadmap Q3.7 Mute and Q4.2 Sender rules, docs/DATA-MODEL.md
/// "Arrival rules"): the mute on the summary row, the `sender_rules` table, and mail new to the store archived or
/// trashed in the write that stores it, its operation queued in that transaction. Written as an extension so
/// `SQLiteMailStoreContractTests` inherits every case and both stores are held to the same semantics.
extension MailStoreContractTests {
    private func conversation(_ providerID: String, account: AccountID? = nil) -> ConversationID {
        ConversationID(accountID: account ?? accountA, providerID: providerID)
    }

    private func id(_ providerID: String, account: AccountID? = nil) -> MessageID {
        MessageID(accountID: account ?? accountA, providerID: providerID)
    }

    private func archive(_ providerIDs: [String], account: AccountID? = nil, at offset: TimeInterval = 0) -> SSCore.Operation {
        let accountID = account ?? accountA
        return SSCore.Operation(accountID: accountID, change: .archive,
                                targets: providerIDs.map { MessageID(accountID: accountID, providerID: $0) }, createdAt: date(offset))
    }

    /// Mutes conversation `c` with the archive of `ids`, as M does.
    private func mute(_ c: String, archiving ids: [String], account: AccountID? = nil) throws {
        try store.setMuted(true, conversations: [conversation(c, account: account)],
                           enqueueing: ids.isEmpty ? [] : [archive(ids, account: account)])
    }

    private func pending(_ account: AccountID? = nil) throws -> [SSCore.Operation] {
        try store.pendingOperations(accountID: account ?? accountA, limit: 100)
    }

    private var spammer: EmailAddress { EmailAddress(name: "Deals", address: "deals@shop.example") }
    private var newsletter: EmailAddress { EmailAddress(name: "Weekly", address: "news@letter.example") }

    // MARK: Mute

    func testMutingArchivesAndMarksTheConversationInOneWrite() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10)), message("m2", in: "c2", date: date(20))])
        try mute("c1", archiving: ["m1"])

        XCTAssertTrue(try summary("c1").isMuted)
        XCTAssertFalse(try summary("c2").isMuted)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2"], "archived with it")
        XCTAssertEqual(try pending().map(\.change), [.archive], "the ordinary archive, queued")

        try store.setMuted(false, conversations: [conversation("c1")], enqueueing: [])
        XCTAssertFalse(try summary("c1").isMuted)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2"], "unmuting moves nothing back")
    }

    func testTheMuteShowsInEveryViewAndOutlivesWritesToItsMessages() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10), isRead: false)])
        try mute("c1", archiving: ["m1"])
        try store.upsertMessages([message("m1", in: "c1", date: date(10), roles: [], isRead: true, isStarred: true)])
        try store.enqueue(SSCore.Operation(accountID: accountA, change: .setRead(false), targets: [id("m1")], createdAt: date(30)))
        XCTAssertTrue(try summary("c1", view: .all).isMuted)
        XCTAssertTrue(try summary("c1", view: .starred).isMuted)
        XCTAssertTrue(try store.conversations(ConversationQuery(view: .all, searchText: "subject")).first?.isMuted == true)
    }

    func testTheMuteGoesWithTheConversationsLastMessage() throws {
        try store.upsertMessages([message("m1", in: "c1")])
        try mute("c1", archiving: ["m1"])
        try store.deleteMessages([id("m1")])
        try store.upsertMessages([message("m2", in: "c1", date: date(50))])
        XCTAssertFalse(try summary("c1", view: .inbox).isMuted, "a conversation that came back starts unmuted")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
    }

    func testAConversationTheStoreLacksIsNotMuted() throws {
        try store.setMuted(true, conversations: [conversation("nowhere")], enqueueing: [])
        try store.upsertMessages([message("m1", in: "nowhere")])
        XCTAssertFalse(try summary("nowhere", view: .inbox).isMuted)
        XCTAssertTrue(try pending().isEmpty)
    }

    func testMailArrivingInAMutedConversationIsArchivedInTheWriteThatStoresIt() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try mute("c1", archiving: ["m1"])
        try store.confirmOperation(id: XCTUnwrap(try pending().first).id)

        try store.upsertMessages([message("m2", in: "c1", date: date(60), isRead: false), message("m3", in: "c2", date: date(70))])
        XCTAssertEqual(try store.message(id("m2"))?.roles, [], "archived as it arrived")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2"], "never in the Inbox")
        let queued = try pending()
        XCTAssertEqual(queued.map(\.change), [.archive], "the ordinary archive, queued in the same write")
        XCTAssertEqual(queued.first?.targets, [id("m2")])
        XCTAssertTrue(try summary("c1").isMuted)
        XCTAssertTrue(try summary("c1").hasPendingOperations)
        XCTAssertEqual(try summary("c1").unreadCount, 1, "archived, not read")
    }

    /// The provider reports the arrival in the Inbox until the archive lands; the queued archive wins over that report.
    func testTheArrivalsArchiveWinsOverLaterReportsUntilItLands() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10), roles: [])])
        try mute("c1", archiving: [])
        try store.upsertMessages([message("m2", in: "c1", date: date(60))])
        try store.upsertMessages([message("m2", in: "c1", date: date(60))])
        XCTAssertTrue(try conversationIDs(ConversationQuery(view: .inbox)).isEmpty)
        XCTAssertEqual(try pending().count, 1, "a report of a stored message queues nothing more")
    }

    /// The archive keeps the provider's report as what it replaced, so a refused archive puts the message back in the Inbox.
    func testAGivenUpArrivalArchiveBringsTheMessageBack() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10), roles: [])])
        try mute("c1", archiving: [])
        try store.upsertMessages([message("m2", in: "c1", date: date(60))])
        var operation = try XCTUnwrap(try pending().first)
        operation.status = .failed
        try store.updateOperation(operation)
        XCTAssertEqual(try store.message(id("m2"))?.roles, [.inbox])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
        XCTAssertTrue(try summary("c1", view: .inbox).isMuted, "the mute stays")
    }

    /// Moved back to the Inbox while muted (⇧I, another device), the conversation leaves it again with the next arrival:
    /// its older mail is archived with the new.
    func testAnArrivalTakesAMutedConversationsOlderInboxMailWithIt() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10)), message("m2", in: "c1", date: date(20), roles: [.sent]),
                                  message("m3", in: "c1", date: date(30), roles: [.trash])])
        try mute("c1", archiving: [])
        try store.upsertMessages([message("m4", in: "c1", date: date(60))])
        XCTAssertEqual(try pending().first?.targets, [id("m1"), id("m4")], "the Inbox's mail, not the Sent copy or the Trash")
        XCTAssertTrue(try conversationIDs(ConversationQuery(view: .inbox)).isEmpty)
        XCTAssertEqual(try store.message(id("m3"))?.roles, [.trash])
    }

    func testOnlyMailNewToTheStoreAndInTheInboxIsTaken() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try mute("c1", archiving: [])
        // Reported in the Inbox again (another device moved it back): not an arrival.
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        // The user's reply, and spam, arrive outside the Inbox.
        try store.upsertMessages([message("m2", in: "c1", date: date(20), roles: [.sent]),
                                  message("m3", in: "c1", date: date(30), roles: [.spam, .inbox])])
        XCTAssertTrue(try pending().isEmpty)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
    }

    /// The backfill's older mail is old, but a muted conversation's mail still in the provider's Inbox would bring it back.
    func testTheBackfillsMailInAMutedConversationIsArchivedToo() throws {
        try store.upsertMessages([message("m2", in: "c1", date: date(20))])
        try mute("c1", archiving: ["m2"])
        XCTAssertEqual(try store.writeBackfillMessages([message("m1", in: "c1", date: date(10))], refreshExisting: false), 1)
        XCTAssertEqual(try store.message(id("m1"))?.roles, [])
        XCTAssertEqual(try pending().map(\.change), [.archive, .archive])
        XCTAssertTrue(try conversationIDs(ConversationQuery(view: .inbox)).isEmpty)
    }

    func testAMuteInOneAccountTakesNothingFromAnother() throws {
        try store.upsertMessages([message("m1", in: "c1"), message("b1", in: "c1", account: accountB, from: bea)])
        try mute("c1", archiving: ["m1"])
        try store.upsertMessages([message("b2", in: "c1", account: accountB, from: bea, date: date(40))])
        XCTAssertEqual(try store.message(id("b2", account: accountB))?.roles, [.inbox])
        XCTAssertTrue(try pending(accountB).isEmpty)
    }

    /// No subscriber ever sees the arrival in the Inbox: the archive is in the transaction that stores it.
    func testAnInboxObserverNeverSeesAMutedArrival() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10)), message("m0", in: "c0", date: date(5))])
        try mute("c1", archiving: ["m1"])
        let box = ObservedValues()
        let observation = store.observeConversations(ConversationQuery(view: .inbox)) { box.append($0.map(\.id.providerID)) }
        defer { observation.cancel() }
        try store.upsertMessages([message("m2", in: "c1", date: date(60), isRead: false)])
        try store.upsertMessages([message("m3", in: "c3", date: date(70))])
        let deadline = Date().addingTimeInterval(3)
        while box.values.last != ["c3", "c0"], Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(box.values.last, ["c3", "c0"])
        XCTAssertFalse(box.values.contains { $0.contains("c1") }, "every delivery: \(box.values)")
    }

    // MARK: Sender rules

    func testSenderRulesAreKeptPerAccountByAddressWithoutCase() throws {
        try store.setSenderRule(.trash, for: "  Deals@Shop.Example ", accountID: accountA, enqueueing: [], at: date(100))
        try store.setSenderRule(.archive, for: "news@letter.example", accountID: accountA, enqueueing: [], at: date(110))
        try store.setSenderRule(.archive, for: "deals@shop.example", accountID: accountB, enqueueing: [], at: date(120))
        XCTAssertEqual(try store.senderRules(), [
            SenderRule(accountID: accountA, address: "deals@shop.example", action: .trash, createdAt: date(100)),
            SenderRule(accountID: accountA, address: "news@letter.example", action: .archive, createdAt: date(110)),
            SenderRule(accountID: accountB, address: "deals@shop.example", action: .archive, createdAt: date(120)),
        ])

        // One rule per address: setting the other replaces it, nil removes it.
        try store.setSenderRule(.archive, for: "DEALS@shop.example", accountID: accountA, enqueueing: [], at: date(130))
        try store.setSenderRule(nil, for: "news@letter.example", accountID: accountA, enqueueing: [], at: date(140))
        XCTAssertEqual(try store.senderRules().filter { $0.accountID == accountA },
                       [SenderRule(accountID: accountA, address: "deals@shop.example", action: .archive, createdAt: date(130))])
    }

    func testABlockedSendersMailGoesToTheTrashAsItArrives() throws {
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.upsertMessages([
            message("m1", in: "c1", from: EmailAddress(name: "Deals", address: "DEALS@shop.example"), date: date(200), isRead: false),
            message("m2", in: "c2", date: date(210)),
        ])
        XCTAssertEqual(try store.message(id("m1"))?.roles, [.trash])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .trash)), ["c1"])
        XCTAssertEqual(try pending().map(\.change), [.trash])
        XCTAssertEqual(try pending().first?.targets, [id("m1")])
    }

    func testAlwaysArchiveTakesTheSendersMailOutOfTheInboxAsItArrives() throws {
        try store.setSenderRule(.archive, for: newsletter.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.upsertMessages([message("m1", in: "c1", from: newsletter, date: date(200), isRead: false)])
        XCTAssertEqual(try store.message(id("m1"))?.roles, [])
        XCTAssertTrue(try conversationIDs(ConversationQuery(view: .inbox)).isEmpty)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), ["c1"], "archived, unread, in All Mail")
        XCTAssertEqual(try pending().map(\.change), [.archive])
    }

    /// A sender's archive takes that sender's message, not the conversation: someone else's mail in it stays in the Inbox.
    func testASendersArchiveTakesOnlyTheirMessage() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try store.setSenderRule(.archive, for: newsletter.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.upsertMessages([message("m2", in: "c1", from: newsletter, date: date(200))])
        XCTAssertEqual(try pending().first?.targets, [id("m2")])
        XCTAssertEqual(try store.message(id("m1"))?.roles, [.inbox])
    }

    func testRulesLeaveTheUsersOwnMailSpamOtherAccountsAndStoredMailAlone() throws {
        try store.upsertMessages([message("m0", in: "c0", from: spammer, date: date(10))])
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.upsertMessages([
            message("m0", in: "c0", from: spammer, date: date(10)),
            message("m1", in: "c1", from: spammer, date: date(200), roles: [.sent]),
            message("m2", in: "c2", from: spammer, date: date(210), roles: [.drafts]),
            message("m3", in: "c3", from: spammer, date: date(220), roles: [.spam]),
            message("b1", in: "c4", account: accountB, from: spammer, date: date(230)),
        ])
        XCTAssertTrue(try pending().isEmpty)
        XCTAssertTrue(try pending(accountB).isEmpty)
        XCTAssertEqual(try store.message(id("m0"))?.roles, [.inbox], "mail stored before the rule stays where it is")
    }

    /// The backfill and a search of the server write old mail, not arrivals: a rule set today does not move it.
    func testSenderRulesTakeNoMailTheBackfillWrites() throws {
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        XCTAssertEqual(try store.writeBackfillMessages([message("m1", in: "c1", from: spammer, date: date(10))], refreshExisting: false), 1)
        XCTAssertEqual(try store.message(id("m1"))?.roles, [.inbox])
        XCTAssertTrue(try pending().isEmpty)
    }

    func testARemovedRuleTakesNothingMore() throws {
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.setSenderRule(nil, for: spammer.address, accountID: accountA, enqueueing: [], at: date(110))
        try store.upsertMessages([message("m1", in: "c1", from: spammer, date: date(200))])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
        XCTAssertTrue(try store.senderRules().isEmpty)
    }

    /// Setting a rule takes the sender's mail where it was set from, in the rule's own transaction, and its undo puts
    /// both back.
    func testSettingARuleQueuesItsStepsInTheSameWrite() throws {
        try store.upsertMessages([message("m1", in: "c1", from: spammer, date: date(10))])
        let trash = SSCore.Operation(accountID: accountA, change: .trash, targets: [id("m1")], createdAt: date(100))
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [trash], at: date(100))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .trash)), ["c1"])
        XCTAssertEqual(try store.senderRules().map(\.action), [.trash])

        let restore = SSCore.Operation(accountID: accountA, change: .restoreFromTrash, targets: [id("m1")], createdAt: date(110))
        try store.setSenderRule(nil, for: spammer.address, accountID: accountA, enqueueing: [restore], at: date(110))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
        XCTAssertTrue(try store.senderRules().isEmpty)
    }

    /// Block is further out than the archive: a blocked sender's mail into a muted conversation goes to the Trash.
    func testBlockWinsOverMute() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try mute("c1", archiving: [])
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.upsertMessages([message("m2", in: "c1", from: spammer, date: date(200))])
        XCTAssertEqual(try store.message(id("m2"))?.roles, [.trash])
        XCTAssertEqual(try pending().map(\.change), [.trash], "nothing archived on top: the older mail was not an arrival")
    }

    /// A burst: one archive and one trash per account, whatever arrived, and the rest untouched.
    func testABurstQueuesOneOperationPerAccountAndChange() throws {
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.setSenderRule(.archive, for: newsletter.address, accountID: accountA, enqueueing: [], at: date(100))
        var burst: [MessageMetadata] = []
        for n in 0..<60 {
            let from = n % 3 == 0 ? spammer : n % 3 == 1 ? newsletter : EmailAddress(name: "Ann", address: "ann@example.com")
            burst.append(message("m\(n)", in: "c\(n)", from: from, date: date(200 + Double(n))))
        }
        try store.upsertMessages(burst)
        let queued = try pending()
        XCTAssertEqual(queued.map(\.change), [.archive, .trash])
        XCTAssertEqual(queued.first?.targets.count, 20)
        XCTAssertEqual(queued.last?.targets.count, 20)
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .inbox, limit: 100)).count, 20)
    }

    func testRemovingTheAccountRemovesItsRules() throws {
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountB, enqueueing: [], at: date(100))
        try store.deleteAccount(accountA)
        XCTAssertEqual(try store.senderRules().map(\.accountID), [accountB])
    }

    func testObservingSenderRulesDeliversEachChangeAndNoMail() throws {
        let box = ObservedValues()
        let observation = store.observeSenderRules { box.append($0.map { "\($0.address) \($0.action.rawValue)" }) }
        defer { observation.cancel() }
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.setSenderRule(nil, for: spammer.address, accountID: accountA, enqueueing: [], at: date(110))
        let expected: [[String]] = [[], ["deals@shop.example trash"], []]
        let deadline = Date().addingTimeInterval(3)
        while box.values != expected, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(box.values, expected)
        try store.upsertMessages([message("m9", in: "c9")])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(box.values.count, expected.count, "mail arriving changes nothing a subscriber sees")
    }
}
