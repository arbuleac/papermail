import XCTest
import SSCore

/// The `MailStoring` contract for the arrival rules (roadmap Q3.7 Mute and Q4.2 Sender rules, docs/DATA-MODEL.md
/// "Arrival rules"): the mute on the summary row and mail new to a muted conversation archived in the write that stores
/// it, its operation queued in that transaction; sender rules, kept on the server since v23, taking no mail at arrival
/// and only keeping a snooze. The mirror's own transitions are `MailStoreSenderRulesContractTests`. Written as an extension so
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

    // MARK: What a notification is about

    /// The newest unread message in the Inbox of each conversation asked about, in one read: not the conversation's newest
    /// when a rule archived that, nor a read one, nor one in the Trash or Spam; none for a conversation without one.
    func testTheNewestUnreadInboxMessageOfEachConversation() throws {
        try store.upsertMessages([
            message("old", in: "c1", date: date(10), roles: [.inbox], isRead: false),
            message("arrival", in: "c1", date: date(20), roles: [.inbox], isRead: false),
            message("read", in: "c1", date: date(30), roles: [.inbox], isRead: true),
            message("ruled", in: "c1", date: date(40), roles: [], isRead: false),
            message("trashed", in: "c1", date: date(50), roles: [.inbox, .trash], isRead: false),
            message("reply", in: "c2", date: date(10), roles: [.sent], isRead: true),
            message("archived", in: "c2", date: date(5), roles: [], isRead: false),
        ])
        let newest = try store.newestUnreadInboxMessages(in: [conversation("c1"), conversation("c2"), conversation("nowhere")])
        XCTAssertEqual(newest.mapValues(\.id.providerID), [conversation("c1"): "arrival"])
        XCTAssertEqual(try store.newestUnreadInboxMessages(in: []), [:])
    }

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

    /// `isMuted` reads the flag of one conversation, as a reader window asks it for its own (spec, Reader window (Q3.5)),
    /// whether or not any list holds the row.
    func testIsMutedReadsOneConversationsFlag() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10)), message("m2", in: "c2", date: date(20))])
        XCTAssertFalse(try store.isMuted(conversation("c1")))
        try mute("c1", archiving: ["m1"])
        XCTAssertTrue(try store.isMuted(conversation("c1")))
        XCTAssertFalse(try store.isMuted(conversation("c2")))
        XCTAssertFalse(try store.isMuted(conversation("nowhere")), "no summary, not muted")
        try store.setMuted(false, conversations: [conversation("c1")], enqueueing: [])
        XCTAssertFalse(try store.isMuted(conversation("c1")))
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

    /// Undoing a mute that took a conversation back from Later out of the Inbox puts its return mark back with the
    /// inverse steps, in the same write, as an undone archive does (`setSnoozes` with a `returnedAt`).
    func testAnUndoneMutePutsTheReturnMarkBack() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: date(500))],
                             enqueueing: [archive(["m1"], at: 100)], at: date(100))
        try store.returnDueSnoozes(at: date(600), limit: 10) { id, messages in
            [SSCore.Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.map(\.id), createdAt: self.date(600))]
        }
        XCTAssertEqual(try summary("c1", view: .inbox).returnedAt, date(600))

        try store.setMuted(true, conversations: [conversation("c1")], enqueueing: [archive(["m1"], at: 700)])
        XCTAssertNil(try summary("c1").returnedAt, "out of the Inbox, the mark goes")
        let back = SSCore.Operation(accountID: accountA, change: .moveToInbox, targets: [id("m1")], createdAt: date(800))
        try store.setMuted(false, conversations: [conversation("c1")], enqueueing: [back], returnMarks: [conversation("c1"): date(600)])
        let row = try summary("c1", view: .inbox)
        XCTAssertFalse(row.isMuted)
        XCTAssertEqual(row.returnedAt, date(600), "back under the time it came back")

        // As `setSnoozes` keeps it: never on a conversation out of the Inbox.
        try store.setMuted(true, conversations: [conversation("c1")], enqueueing: [archive(["m1"], at: 900)])
        try store.setMuted(false, conversations: [conversation("c1")], enqueueing: [], returnMarks: [conversation("c1"): date(600)])
        XCTAssertNil(try summary("c1").returnedAt)
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

    /// Snoozed (L) and then muted, the conversation keeps its snooze through a reply: the mute says new mail in it is not
    /// news, and the reply it archives brings nothing back, so ending the snooze would leave it archived for good. It
    /// still comes back at its time.
    func testAMutedArrivalLeavesTheSnoozeToComeDue() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: date(9_000))],
                             enqueueing: [archive(["m1"], at: 100)], at: date(100))
        try mute("c1", archiving: [])
        try store.upsertMessages([message("m2", in: "c1", date: date(200), isRead: false)])
        XCTAssertEqual(try store.message(id("m2"))?.roles, [], "archived as it arrived")
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("c1")], "still snoozed")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later)), ["c1"])

        let returned = try store.returnDueSnoozes(at: date(9_000), limit: 10) { id, messages in
            [SSCore.Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.map(\.id), createdAt: self.date(9_000))]
        }
        XCTAssertEqual(returned, [conversation("c1")], "it comes back at its time")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
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

    // MARK: Sender rules: on the server, not at arrival

    func testSenderRulesAreKeptPerAccountByAddressWithoutCase() throws {
        try store.setSenderRule(.trash, for: "  Deals@Shop.Example ", accountID: accountA, enqueueing: [], at: date(100))
        try store.setSenderRule(.archive, for: "news@letter.example", accountID: accountA, enqueueing: [], at: date(110))
        try store.setSenderRule(.archive, for: "deals@shop.example", accountID: accountB, enqueueing: [], at: date(120))
        XCTAssertEqual(try store.senderRules(), [
            SenderRule(accountID: accountA, address: "deals@shop.example", action: .trash, createdAt: date(100), sync: .creating),
            SenderRule(accountID: accountA, address: "news@letter.example", action: .archive, createdAt: date(110), sync: .creating),
            SenderRule(accountID: accountB, address: "deals@shop.example", action: .archive, createdAt: date(120), sync: .creating),
        ], "each on its way to the server")

        // One rule per address: setting the other replaces it, nil removes it (neither reached the server, so at once).
        try store.setSenderRule(.archive, for: "DEALS@shop.example", accountID: accountA, enqueueing: [], at: date(130))
        try store.setSenderRule(nil, for: "news@letter.example", accountID: accountA, enqueueing: [], at: date(140))
        XCTAssertEqual(try store.senderRules().filter { $0.accountID == accountA },
                       [SenderRule(accountID: accountA, address: "deals@shop.example", action: .archive, createdAt: date(130),
                                   sync: .creating)])
    }

    /// The server archives or trashes a sender's mail before this Mac sees it, so the store does nothing to mail at
    /// arrival for a rule, whatever its state: mail is stored where the provider put it and nothing is queued. (A rule's
    /// mail the provider reports in the Inbox is mail the server rule did not take, which this Mac does not second-guess.)
    func testSenderRulesTakeNoMailAsItArrives() throws {
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.replaceServerSenderRules(accountID: accountA,
                                           with: [ServerSenderRule(serverID: "f1", address: newsletter.address, action: .archive)],
                                           readAt: date(105))
        XCTAssertEqual(try store.senderRules().map(\.sync), [.creating, .saved])
        try store.upsertMessages([
            message("m1", in: "c1", from: EmailAddress(name: "Deals", address: "DEALS@shop.example"), date: date(200), isRead: false),
            message("m2", in: "c2", from: newsletter, date: date(210), isRead: false),
            message("m3", in: "c3", from: newsletter, date: date(220), roles: []),
            message("m4", in: "c4", from: spammer, date: date(230), roles: [.trash]),
            message("m5", in: "c5", date: date(240)),
        ])
        XCTAssertEqual(try store.message(id("m1"))?.roles, [.inbox], "the block's rule is not on the server yet")
        XCTAssertEqual(try store.message(id("m2"))?.roles, [.inbox], "as the provider reported it")
        XCTAssertEqual(try store.message(id("m3"))?.roles, [], "archived by the server before it arrived")
        XCTAssertEqual(try store.message(id("m4"))?.roles, [.trash], "moved to the Trash by the server")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c5", "c2", "c1"])
        XCTAssertTrue(try pending().isEmpty, "nothing queued for a rule")
    }

    /// The row shows the conversation's newest mail, the message a server rule archived included: an archived sender's
    /// mail in a conversation the Inbox holds for someone else's leaves the row there with that message's time, snippet
    /// and unread count, as any archived message in it would. Only the notification is held back (the window's
    /// `NewMailNotifier`).
    func testMailAServerRuleArchivedInAConversationTheInboxHoldsStillShowsOnItsRow() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10), isRead: true)])
        try store.replaceServerSenderRules(accountID: accountA,
                                           with: [ServerSenderRule(serverID: "f1", address: newsletter.address, action: .archive)],
                                           readAt: date(100))
        try store.upsertMessages([message("m2", in: "c1", from: newsletter, date: date(200), roles: [], isRead: false)])
        XCTAssertEqual(try store.message(id("m2"))?.roles, [])
        let row = try summary("c1", view: .inbox)
        XCTAssertEqual(row.latestMessageID, id("m2"))
        XCTAssertEqual(row.latestDate, date(200))
        XCTAssertEqual(row.snippet, "snippet of m2")
        XCTAssertEqual(row.unreadCount, 1)
    }

    /// Mail from a sender with a rule leaves a snooze alone, as the mute's does: the server put a blocked sender's reply in
    /// the Trash, and an always-archived sender's message out of the Inbox, before it arrived. Mail from anyone else still
    /// ends it. A rule counts in every state: one on its way to the server, or being removed there, is still one the
    /// user set.
    func testMailFromASenderWithARuleLeavesTheSnooze() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10)), message("n1", in: "c2", date: date(20))])
        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: date(9_000)),
                              Snooze.Change(conversationID: conversation("c2"), until: date(9_000))],
                             enqueueing: [archive(["m1", "n1"], at: 100)], at: date(100))
        try store.replaceServerSenderRules(accountID: accountA,
                                           with: [ServerSenderRule(serverID: "f1", address: spammer.address, action: .trash)],
                                           readAt: date(105))
        try store.setSenderRule(.archive, for: newsletter.address, accountID: accountA, enqueueing: [], at: date(110))
        try store.setSenderRule(nil, for: spammer.address, accountID: accountA, enqueueing: [], at: date(115))
        XCTAssertEqual(try store.senderRules().map(\.sync), [.deleting, .creating])
        try store.upsertMessages([message("m2", in: "c1", from: spammer, date: date(200), roles: [.trash]),
                                  message("n2", in: "c2", from: newsletter, date: date(210), roles: [])])
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("c1"), conversation("c2")])

        try store.upsertMessages([message("m3", in: "c1", date: date(300), roles: [])])
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("c2")])
    }

    func testARemovedRuleThatNeverReachedTheServerGoesAtOnce() throws {
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.setSenderRule(nil, for: spammer.address, accountID: accountA, enqueueing: [], at: date(110))
        XCTAssertTrue(try store.senderRules().isEmpty)
        XCTAssertTrue(try store.pendingSenderRules(accountID: accountA).isEmpty, "nothing for the server to do")
    }

    /// Setting a rule takes the sender's mail where it was set from, in the rule's own transaction, and its undo puts
    /// both back.
    func testSettingARuleQueuesItsStepsInTheSameWrite() throws {
        try store.upsertMessages([message("m1", in: "c1", from: spammer, date: date(10))])
        let trash = SSCore.Operation(accountID: accountA, change: .trash, targets: [id("m1")], createdAt: date(100))
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [trash], at: date(100))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .trash)), ["c1"])
        XCTAssertEqual(try store.senderRules().map(\.action), [.trash])
        XCTAssertEqual(try store.senderRules().map(\.sync), [.creating])

        let restore = SSCore.Operation(accountID: accountA, change: .restoreFromTrash, targets: [id("m1")], createdAt: date(110))
        try store.setSenderRule(nil, for: spammer.address, accountID: accountA, enqueueing: [restore], at: date(110))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
        XCTAssertTrue(try store.senderRules().isEmpty)
    }

    /// The mute archives whatever arrives in a muted conversation's Inbox, a blocked sender's mail included: that the
    /// server's block did not take it is the server's business.
    func testTheMuteArchivesABlockedSendersMailThatReachedTheInbox() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try mute("c1", archiving: [])
        try store.replaceServerSenderRules(accountID: accountA,
                                           with: [ServerSenderRule(serverID: "f1", address: spammer.address, action: .trash)],
                                           readAt: date(100))
        try store.upsertMessages([message("m2", in: "c1", from: spammer, date: date(200))])
        XCTAssertEqual(try store.message(id("m2"))?.roles, [])
        XCTAssertEqual(try pending().map(\.change), [.archive], "the mute's archive, of the Inbox's mail")
        XCTAssertEqual(try pending().first?.targets, [id("m1"), id("m2")])
    }

    /// A burst: with rules set and nothing muted, nothing is queued however much arrives; into muted conversations, one
    /// archive per account.
    func testABurstQueuesNothingForRulesAndOneArchivePerAccountForTheMute() throws {
        try store.setSenderRule(.trash, for: spammer.address, accountID: accountA, enqueueing: [], at: date(100))
        try store.replaceServerSenderRules(accountID: accountA,
                                           with: [ServerSenderRule(serverID: "f1", address: newsletter.address, action: .archive)],
                                           readAt: date(100))
        var burst: [MessageMetadata] = []
        for n in 0..<60 {
            let from = n % 3 == 0 ? spammer : n % 3 == 1 ? newsletter : EmailAddress(name: "Ann", address: "ann@example.com")
            burst.append(message("m\(n)", in: "c\(n)", from: from, date: date(200 + Double(n))))
        }
        try store.upsertMessages(burst)
        XCTAssertTrue(try pending().isEmpty)
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .inbox, limit: 100)).count, 60)

        for n in 0..<3 { try mute("c\(n)", archiving: ["m\(n)"]) }
        for operation in try pending() { try store.confirmOperation(id: operation.id) }
        try store.upsertMessages((0..<30).map { n in message("x\(n)", in: "c\(n % 3)", date: date(400 + Double(n))) })
        XCTAssertEqual(try pending().map(\.change), [.archive])
        XCTAssertEqual(try pending().first?.targets.count, 30)
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
