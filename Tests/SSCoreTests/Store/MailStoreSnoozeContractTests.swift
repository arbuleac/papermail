import XCTest
// For `SnoozeRunner.operations`, so the return cases run on the operations the runner really queues.
@testable import SSCore

/// The `MailStoring` contract for Later (roadmap Q2.1, docs/DATA-MODEL.md "Snoozes"): the `snoozes` timer, the
/// conversation's `returned_at`, the rules that end a snooze early and the Later and Inbox queries. Written as an
/// extension so `SQLiteMailStoreContractTests` inherits every case and both stores are held to the same semantics.
extension MailStoreContractTests {
    private func conversation(_ providerID: String, account: AccountID? = nil) -> ConversationID {
        ConversationID(accountID: account ?? accountA, providerID: providerID)
    }

    private func archive(_ providerIDs: [String], account: AccountID? = nil, at offset: TimeInterval = 0) -> SSCore.Operation {
        let accountID = account ?? accountA
        return SSCore.Operation(accountID: accountID, change: .archive,
                                targets: providerIDs.map { MessageID(accountID: accountID, providerID: $0) }, createdAt: date(offset))
    }

    /// What the snooze runner queues when a conversation comes back: its messages to the Inbox, the latest unread.
    private func returning(_ id: ConversationID, _ messages: [MessageMetadata], at offset: TimeInterval) -> [SSCore.Operation] {
        var operations = [SSCore.Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.map(\.id), createdAt: date(offset))]
        if let latest = messages.last {
            operations.append(SSCore.Operation(accountID: id.accountID, change: .setRead(false), targets: [latest.id],
                                               createdAt: date(offset + 0.001)))
        }
        return operations
    }

    /// Snoozes conversation `c` (its messages `ids`, in the Inbox) until `due`, archiving them, as the window does.
    private func snooze(_ c: String, messages ids: [String], until due: TimeInterval, at offset: TimeInterval = 100,
                        account: AccountID? = nil) throws {
        try store.setSnoozes([Snooze.Change(conversationID: conversation(c, account: account), until: date(due))],
                             enqueueing: [archive(ids, account: account, at: offset)], at: date(offset))
    }

    // MARK: Snoozing

    func testSnoozingArchivesAndKeepsTheTimeInOneWrite() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10)), message("m2", in: "c1", date: date(20)),
                                  message("m3", in: "c2", date: date(30))])
        try snooze("c1", messages: ["m1", "m2"], until: 3_600)

        XCTAssertEqual(try store.snoozes(), [Snooze(conversationID: conversation("c1"), dueAt: date(3_600), createdAt: date(100))])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2"], "archived with it")
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10).map(\.change), [.archive], "the ordinary archive, queued")
        let later = try store.conversations(ConversationQuery(view: .later))
        XCTAssertEqual(later.map(\.id.providerID), ["c1"])
        XCTAssertEqual(later.first?.snoozedUntil, date(3_600), "Later's rows carry the time")
        XCTAssertNil(try summary("c1").snoozedUntil, "no other view reads the snooze")
        XCTAssertNil(try summary("c1").returnedAt)
    }

    func testAConversationOutsideTheInboxJustGetsItsSnooze() throws {
        try store.upsertMessages([message("m1", in: "c1", roles: [])])
        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: date(600))], enqueueing: [], at: date(100))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("c1")])
        XCTAssertTrue(try store.pendingOperations(accountID: accountA, limit: 10).isEmpty)
    }

    /// A conversation still in the Inbox, or in the Trash (on Microsoft, all of it but the user's own copies), or not
    /// stored, cannot be snoozed: a snooze always stands for mail put away.
    func testOnlyMailOutOfTheInboxAndTheTrashCanBeSnoozed() throws {
        try store.upsertMessages([message("m1", in: "inbox"), message("m2", in: "trashed", roles: [.trash]),
                                  message("m3", in: "own", roles: [.trash]), message("m4", in: "own", roles: [.sent])])
        try store.setSnoozes([
            Snooze.Change(conversationID: conversation("inbox"), until: date(600)),
            Snooze.Change(conversationID: conversation("trashed"), until: date(600)),
            Snooze.Change(conversationID: conversation("own"), until: date(600)),
            Snooze.Change(conversationID: conversation("unknown"), until: date(600)),
        ], enqueueing: [], at: date(100))
        XCTAssertTrue(try store.snoozes().isEmpty)
    }

    func testReschedulingMovesTheTimeAndEndingRemovesIt() throws {
        try store.upsertMessages([message("m1", in: "c1"), message("m2", in: "c2", date: date(5))])
        try snooze("c1", messages: ["m1"], until: 7_200)
        try snooze("c2", messages: ["m2"], until: 3_600)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later)), ["c2", "c1"], "soonest first")

        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: date(1_800))], enqueueing: [], at: date(200))
        XCTAssertEqual(try store.snoozes().map(\.dueAt), [date(1_800), date(3_600)])
        XCTAssertEqual(try store.snoozes().first?.createdAt, date(200), "a reschedule starts the snooze over")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later)), ["c1", "c2"])

        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: nil)], enqueueing: [], at: date(300))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later)), ["c2"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), ["c2", "c1"], "ending a snooze leaves the mail archived")
    }

    func testLaterIsScopedAndUnpaged() throws {
        try store.upsertMessages([message("a1", in: "ca"), message("b1", in: "cb", account: accountB, from: bea)])
        try snooze("ca", messages: ["a1"], until: 600)
        try snooze("cb", messages: ["b1"], until: 300, account: accountB)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later)), ["cb", "ca"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(accountIDs: [accountA], view: .later)), ["ca"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later, before: date(-1_000))), ["cb", "ca"], "Later reads whole")
    }

    /// A search over Later (the field makes none: a search typed there looks through All Mail) keeps Later's order and
    /// reads whole; Later as a search term, which no typed text makes either, reads the snoozes without Later's join.
    func testASearchOverLaterKeepsItsOrder() throws {
        try store.upsertMessages([message("a1", in: "ca", subject: "Lisbon flat"), message("b1", in: "cb", subject: "Lisbon keys"),
                                  message("c1", in: "cc", subject: "Lisbon trip")])
        try snooze("ca", messages: ["a1"], until: 600)
        try snooze("cb", messages: ["b1"], until: 300)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later, searchText: "lisbon", before: date(-1_000))), ["cb", "ca"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later, searchText: "flat")), ["ca"])
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .later, searchText: "flat")).first?.snoozedUntil, date(600))
        var query = ConversationQuery(view: .all)
        query.search = SearchQuery(text: "snoozed", terms: [SearchTerm(.mailbox(.later))])
        XCTAssertEqual(Set(try conversationIDs(query)), ["ca", "cb"])
        query.search = SearchQuery(text: "-snoozed", terms: [SearchTerm(.mailbox(.later), negated: true)])
        XCTAssertEqual(try conversationIDs(query), ["cc"])
    }

    // MARK: Returning

    func testReturningMovesBackMarksUnreadAndSortsUnderTheReturn() throws {
        try store.upsertMessages([message("old1", in: "old", date: date(10)), message("old2", in: "old", date: date(20)),
                                  message("new", in: "fresh", date: date(5_000))])
        try snooze("old", messages: ["old1", "old2"], until: 9_000)
        XCTAssertTrue(try store.returnDueSnoozes(at: date(8_999), limit: 10) { self.returning($0, $1, at: 8_999) }.isEmpty, "not yet due")

        let returned = try store.returnDueSnoozes(at: date(9_000), limit: 10) { id, messages in
            XCTAssertEqual(messages.map(\.id.providerID), ["old1", "old2"], "oldest first")
            return self.returning(id, messages, at: 9_000)
        }
        XCTAssertEqual(returned, [conversation("old")])
        XCTAssertTrue(try store.snoozes().isEmpty)
        let inbox = try store.conversations(ConversationQuery(view: .inbox))
        XCTAssertEqual(inbox.map(\.id.providerID), ["old", "fresh"], "it sorts by the time it came back, above newer mail")
        XCTAssertEqual(inbox.first?.returnedAt, date(9_000))
        XCTAssertEqual(inbox.first?.inboxDate, date(9_000))
        XCTAssertEqual(inbox.first?.latestDate, date(20), "the mail keeps its own date")
        XCTAssertEqual(inbox.first?.unreadCount, 1, "its latest message is unread")
        XCTAssertEqual(try store.message(MessageID(accountID: accountA, providerID: "old2"))?.isRead, false)
        let queued = try store.pendingOperations(accountID: accountA, limit: 10).map(\.change)
        XCTAssertEqual(queued, [.archive, .moveToInbox, .setRead(false)], "the ordinary operations, so every device agrees")

        // Paging walks the same order.
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox, limit: 1)), ["old"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox, before: date(9_000))), ["fresh"])
        // Every other view keeps the mail's own date, and so does a search, an `in:inbox` one too, whose rows show it.
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), ["fresh", "old"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox, searchText: "in:inbox")), ["fresh", "old"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox, searchText: "in:inbox", before: date(5_000))), ["old"])
    }

    /// Reading it moves no row; leaving the Inbox or newer mail ends the return's place.
    func testTheReturnHoldsUntilItLeavesTheInboxOrNewerMailComes() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10)), message("m2", in: "c2", date: date(20)),
                                  message("x", in: "other", date: date(5_000))])
        try snooze("c1", messages: ["m1"], until: 6_000)
        try snooze("c2", messages: ["m2"], until: 6_000, at: 101)
        try store.returnDueSnoozes(at: date(6_000), limit: 10) { self.returning($0, $1, at: 6_000) }
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2", "c1", "other"])

        try store.enqueue(SSCore.Operation(accountID: accountA, change: .setRead(true), targets: [MessageID(accountID: accountA, providerID: "m1")],
                                           createdAt: date(6_100)))
        XCTAssertEqual(try summary("c1", view: .inbox).returnedAt, date(6_000), "read, it keeps its place")

        try store.enqueue(archive(["m1"], at: 6_200))
        try store.enqueue(SSCore.Operation(accountID: accountA, change: .moveToInbox, targets: [MessageID(accountID: accountA, providerID: "m1")],
                                           createdAt: date(6_300)))
        XCTAssertNil(try summary("c1", view: .inbox).returnedAt, "it left the Inbox: back under its own date")

        try store.upsertMessages([message("m2b", in: "c2", date: date(7_000))])
        let c2 = try summary("c2", view: .inbox)
        XCTAssertNil(c2.returnedAt, "newer mail came: the conversation is about that now")
        XCTAssertEqual(c2.inboxDate, date(7_000))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2", "other", "c1"])
    }

    /// An undo of what took a returned conversation out of the Inbox puts its mark back with the inverse operations, in
    /// the same write; a mark is put back only where the conversation is in the Inbox again with older mail.
    func testAnUndoPutsTheReturnMarkBack() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10)), message("m2", in: "c2", date: date(20)),
                                  message("x", in: "other", date: date(5_000))])
        try snooze("c1", messages: ["m1"], until: 6_000)
        try snooze("c2", messages: ["m2"], until: 6_000, at: 101)
        try store.returnDueSnoozes(at: date(6_000), limit: 10) { self.returning($0, $1, at: 6_000) }
        let m1 = MessageID(accountID: accountA, providerID: "m1")
        try store.enqueue(archive(["m1"], at: 6_100))
        XCTAssertNil(try summary("c1").returnedAt, "archived: the mark goes")

        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: nil, returnedAt: date(6_000))],
                             enqueueing: [SSCore.Operation(accountID: accountA, change: .moveToInbox, targets: [m1], createdAt: date(6_200))],
                             at: date(6_200))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2", "c1", "other"], "back under the time it came back")
        XCTAssertEqual(try summary("c1", view: .inbox).returnedAt, date(6_000))
        XCTAssertTrue(try store.snoozes().isEmpty)

        // Not in the Inbox (an undo whose steps left it archived), or with newer mail: no mark.
        try store.enqueue(archive(["m2"], at: 6_300))
        try store.setSnoozes([Snooze.Change(conversationID: conversation("c2"), until: nil, returnedAt: date(6_000))], enqueueing: [],
                             at: date(6_300))
        XCTAssertNil(try summary("c2").returnedAt)
        try store.setSnoozes([Snooze.Change(conversationID: conversation("other"), until: nil, returnedAt: date(4_000))], enqueueing: [],
                             at: date(6_300))
        XCTAssertNil(try summary("other", view: .inbox).returnedAt, "its newest mail is later than the mark")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1", "other"])
    }

    func testOnlyWhatIsDueReturnsAndAGoneConversationJustLosesItsSnooze() throws {
        try store.upsertMessages([message("m1", in: "c1"), message("m2", in: "c2"), message("m3", in: "c3")])
        try snooze("c1", messages: ["m1"], until: 100)
        try snooze("c2", messages: ["m2"], until: 200)
        try snooze("c3", messages: ["m3"], until: 9_000)
        try store.deleteMessages([MessageID(accountID: accountA, providerID: "m2")])
        let returned = try store.returnDueSnoozes(at: date(500), limit: 10) { self.returning($0, $1, at: 500) }
        XCTAssertEqual(returned, [conversation("c1")])
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("c3")])

        // The limit leaves the rest for the next batch, soonest first.
        try snooze("c1", messages: ["m1"], until: 50, at: 600)
        XCTAssertEqual(try store.returnDueSnoozes(at: date(9_000), limit: 1) { self.returning($0, $1, at: 9_000) }, [conversation("c1")])
        XCTAssertEqual(try store.returnDueSnoozes(at: date(9_000), limit: 1) { self.returning($0, $1, at: 9_000) }, [conversation("c3")])
    }

    /// An account in `dueBy` returns only what its date covers (the runner holds back a time its account has not checked
    /// past yet); the others return as usual, and the batch is counted after the held rows are left out.
    func testAnAccountHeldBackReturnsOnlyWhatItsDateCovers() throws {
        try store.upsertMessages([message("a1", in: "ca"), message("a2", in: "ca2"), message("b1", in: "cb", account: accountB, from: bea)])
        try snooze("ca", messages: ["a1"], until: 150)
        try snooze("ca2", messages: ["a2"], until: 300)
        try snooze("cb", messages: ["b1"], until: 300, account: accountB)
        let held = [accountA: date(200)]
        XCTAssertEqual(try store.returnDueSnoozes(at: date(500), dueBy: held, limit: 1) { self.returning($0, $1, at: 500) }, [conversation("ca")])
        XCTAssertEqual(try store.returnDueSnoozes(at: date(500), dueBy: held, limit: 1) { self.returning($0, $1, at: 500) },
                       [conversation("cb", account: accountB)], "ca2 is held, and does not take the batch")
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("ca2")])
        XCTAssertEqual(try store.returnDueSnoozes(at: date(500), dueBy: [:], limit: 10) { self.returning($0, $1, at: 500) }, [conversation("ca2")])
    }

    /// A conversation with a message in the Trash (deleted on the web, or a server draft the Mac continued and sent):
    /// the return brings back the mail the snooze put away, and marks the latest of that unread, never the deleted one.
    func testAPartlyTrashedConversationReturnsWhatWasPutAway() throws {
        try store.upsertMessages([message("keep", in: "c1", date: date(10)), message("gone", in: "c1", date: date(20), roles: [.trash])])
        try snooze("c1", messages: ["keep"], until: 600)
        XCTAssertEqual(try store.snoozes().count, 1, "mail is still put away: it stays snoozed")

        try store.returnDueSnoozes(at: date(600), limit: 10) { id, messages in
            let operations = SnoozeRunner.operations(returning: messages, of: id, kind: .gmail, at: self.date(600))
            XCTAssertEqual(operations.map(\.change), [.moveToInbox, .setRead(false)])
            XCTAssertEqual(operations.map { $0.targets.map(\.providerID) }, [["keep"], ["keep"]])
            return operations
        }
        XCTAssertEqual(try store.message(MessageID(accountID: accountA, providerID: "keep"))?.roles, [.inbox])
        XCTAssertEqual(try store.message(MessageID(accountID: accountA, providerID: "keep"))?.isRead, false)
        XCTAssertEqual(try store.message(MessageID(accountID: accountA, providerID: "gone"))?.roles, [.trash], "deleted mail stays deleted")
        let back = try summary("c1", view: .inbox)
        XCTAssertEqual(back.returnedAt, date(600))
        XCTAssertEqual(back.unreadCount, 1)
    }

    /// On Microsoft the user's reply stays in Sent Items, as Move to Inbox leaves it, so the message moved to the Inbox
    /// is the one marked unread: the phone and the web show the same unread message the Mac does.
    func testOnMicrosoftTheReturnMarksTheMessageInTheInboxUnread() throws {
        try store.upsertMessages([message("in1", in: "c1", date: date(10)),
                                  message("reply", in: "c1", date: date(20), roles: [.sent])])
        try snooze("c1", messages: ["in1"], until: 600)

        try store.returnDueSnoozes(at: date(600), limit: 10) { id, messages in
            let operations = SnoozeRunner.operations(returning: messages, of: id, kind: .microsoft, at: self.date(600))
            XCTAssertEqual(operations.map(\.change), [.moveToInbox, .setRead(false)])
            XCTAssertEqual(operations.map { $0.targets.map(\.providerID) }, [["in1"], ["in1"]])
            return operations
        }
        let reply = try XCTUnwrap(try store.message(MessageID(accountID: accountA, providerID: "reply")))
        XCTAssertEqual(reply.roles, [.sent], "the reply stays in Sent Items")
        XCTAssertTrue(reply.isRead)
        XCTAssertEqual(try store.message(MessageID(accountID: accountA, providerID: "in1"))?.isRead, false)
        XCTAssertEqual(try summary("c1", view: .inbox).unreadCount, 1)
    }

    // MARK: Ending early

    func testMailArrivingAfterTheSnoozeEndsIt() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try snooze("c1", messages: ["m1"], until: 9_000, at: 100)
        // Older mail the backfill lists, the user's own reply and spam leave it alone.
        try store.writeBackfillMessages([message("older", in: "c1", date: date(5), roles: [])], refreshExisting: false)
        try store.upsertMessages([message("reply", in: "c1", date: date(200), roles: [.sent])])
        try store.upsertMessages([message("junk", in: "c1", date: date(210), roles: [.spam])])
        XCTAssertEqual(try store.snoozes().count, 1)
        // A reply from someone else, even one a provider rule kept out of the Inbox, ends it.
        try store.upsertMessages([message("answer", in: "c1", date: date(300), roles: [])])
        XCTAssertTrue(try store.snoozes().isEmpty)
        XCTAssertNil(try summary("c1").returnedAt, "ended early, it is not a return")
    }

    func testBackInTheInboxFromAnywhereEndsIt() throws {
        try store.upsertMessages([message("a", in: "ca"), message("b", in: "cb"), message("c", in: "cc", date: date(10))])
        try snooze("ca", messages: ["a"], until: 9_000)
        try snooze("cb", messages: ["b"], until: 9_000)
        try snooze("cc", messages: ["c"], until: 9_000)
        // ⇧I (or a drop on the Inbox tile): the ordinary move.
        try store.enqueue(SSCore.Operation(accountID: accountA, change: .moveToInbox, targets: [MessageID(accountID: accountA, providerID: "a")],
                                           createdAt: date(200)))
        // Another device put it back: the provider reports it in the Inbox once the archive has landed.
        let archiveOfB = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 10).first { $0.targets.map(\.providerID) == ["b"] })
        try store.confirmOperation(id: archiveOfB.id)
        try store.upsertMessages([message("b", in: "cb", roles: [.inbox])])
        // New mail delivered straight to the Inbox, older than the snooze by its own clock.
        try store.upsertMessages([message("c2", in: "cc", date: date(50))])
        XCTAssertTrue(try store.snoozes().isEmpty)
        for c in ["ca", "cb", "cc"] { XCTAssertNil(try summary(c, view: .inbox).returnedAt, c) }
    }

    func testTrashOrDeletionEndsItAndTheAccountTakesItsSnoozes() throws {
        try store.upsertMessages([message("a", in: "ca"), message("d", in: "cd"), message("b1", in: "cb", account: accountB, from: bea)])
        try snooze("ca", messages: ["a"], until: 9_000)
        try snooze("cd", messages: ["d"], until: 9_000)
        try snooze("cb", messages: ["b1"], until: 9_000, account: accountB)
        try store.enqueue(SSCore.Operation(accountID: accountA, change: .trash, targets: [MessageID(accountID: accountA, providerID: "a")],
                                           createdAt: date(200)))
        try store.deleteMessages([MessageID(accountID: accountA, providerID: "d")])
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("cb", account: accountB)])
        try store.deleteAccount(accountB)
        XCTAssertTrue(try store.snoozes().isEmpty)
        // Neither leaves a snooze behind to come back with the mail later.
        try store.upsertMessages([message("d", in: "cd", roles: [])])
        XCTAssertTrue(try store.snoozes().isEmpty)
    }

    /// Move to Trash on Microsoft leaves the user's own copies in Sent Items and Drafts, so the conversation is not in the
    /// Trash as a whole; with every other message deleted, here or on another device, the snooze ends all the same. Left
    /// standing, its return would move the deleted mail out of Deleted Items to the Inbox on every device.
    func testOnMicrosoftTrashingAllButTheUsersOwnCopiesEndsIt() throws {
        try store.upsertMessages([message("in1", in: "c1", date: date(10)), message("reply1", in: "c1", date: date(20), roles: [.sent]),
                                  message("in2", in: "c2", date: date(10)), message("reply2", in: "c2", date: date(20), roles: [.sent])])
        try snooze("c1", messages: ["in1"], until: 9_000)
        try snooze("c2", messages: ["in2"], until: 9_000, at: 101)

        // # in Later: Microsoft's targets leave the reply in Sent Items.
        let messages = try store.messages(in: conversation("c1"))
        let record = try XCTUnwrap(MailActionRecord.make(.trash, on: MailActionRecord.targets(for: .trash, in: messages, kind: .microsoft),
                                                         conversation: conversation("c1")))
        XCTAssertEqual(record.targets.map(\.providerID), ["in1"])
        try store.enqueue(SSCore.Operation(accountID: accountA, change: .trash, targets: record.targets, createdAt: date(200)))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("c2")], "c1 leaves Later")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later)), ["c2"])
        let returned = try store.returnDueSnoozes(at: date(9_000), limit: 10) { id, messages in
            SnoozeRunner.operations(returning: messages, of: id, kind: .microsoft, at: self.date(9_000))
        }
        XCTAssertEqual(returned, [conversation("c2")])
        XCTAssertEqual(try store.message(MessageID(accountID: accountA, providerID: "in1"))?.roles, [.trash], "deleted mail stays deleted")

        // Nor can it be snoozed again, as a conversation in the Trash cannot.
        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: date(20_000))], enqueueing: [], at: date(300))
        XCTAssertFalse(try store.snoozes().contains { $0.conversationID == conversation("c1") })

        // The undo restores the mail and the snooze together.
        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: date(20_000))],
                             enqueueing: record.inverse.enumerated().map { index, step in
                                 SSCore.Operation(accountID: accountA, change: step.change, targets: step.targets, createdAt: date(400 + Double(index)))
                             }, at: date(400))
        XCTAssertTrue(try store.snoozes().contains { $0.conversationID == conversation("c1") })
    }

    /// A deletion on another device, reported once the archive has landed, ends it the same way.
    func testOnMicrosoftADeletionElsewhereThatLeavesTheUsersCopiesEndsIt() throws {
        try store.upsertMessages([message("in1", in: "c1", date: date(10)), message("reply", in: "c1", date: date(20), roles: [.sent])])
        try snooze("c1", messages: ["in1"], until: 9_000)
        let archive = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 1).first)
        try store.confirmOperation(id: archive.id)
        try store.upsertMessages([message("in1", in: "c1", date: date(10), roles: [.trash])])
        XCTAssertTrue(try store.snoozes().isEmpty)
        XCTAssertTrue(try store.conversations(ConversationQuery(view: .later)).isEmpty)
    }

    /// A conversation made only of the user's own mail (a follow-up to a message they sent) is snoozed whole, and stays
    /// snoozed with a draft of theirs in the Trash.
    func testTheUsersOwnConversationStaysSnoozed() throws {
        try store.upsertMessages([message("sent", in: "c1", date: date(10), roles: [.sent]),
                                  message("draft", in: "c1", date: date(20), roles: [.drafts, .trash])])
        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: date(9_000))], enqueueing: [], at: date(100))
        try store.enqueue(SSCore.Operation(accountID: accountA, change: .setStarred(true), targets: [MessageID(accountID: accountA, providerID: "sent")],
                                           createdAt: date(200)))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("c1")])
    }

    /// A failed archive puts the conversation back in the Inbox, and that ends the snooze with it.
    func testAGivenUpArchiveEndsTheSnooze() throws {
        try store.upsertMessages([message("m1", in: "c1")])
        try snooze("c1", messages: ["m1"], until: 9_000)
        var operation = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 1).first)
        operation.status = .failed
        try store.updateOperation(operation)
        XCTAssertTrue(try store.snoozes().isEmpty)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
    }

    /// A wipe drops the conversation but keeps the snooze, as it keeps the queued operations: it is the user's intent.
    /// Out of sight while the mail is gone, it is there again once the mail is.
    func testAWipeKeepsTheSnoozeOutOfSightUntilTheMailIsBack() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try snooze("c1", messages: ["m1"], until: 9_000)
        try store.wipeMailData(for: accountA)
        XCTAssertTrue(try store.snoozes().isEmpty)
        XCTAssertTrue(try store.conversations(ConversationQuery(view: .later)).isEmpty)
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        XCTAssertEqual(try store.snoozes().map(\.dueAt), [date(9_000)], "the archive still wins, and the snooze is back")
    }

    // MARK: Observation

    func testObservingSnoozesDeliversEachChange() throws {
        try store.upsertMessages([message("m1", in: "c1"), message("m2", in: "c2")])
        let seen = SnoozeLog()
        let observation = store.observeSnoozes { seen.append($0) }
        defer { observation.cancel() }
        try snooze("c1", messages: ["m1"], until: 600)
        try snooze("c2", messages: ["m2"], until: 300)
        try store.setSnoozes([Snooze.Change(conversationID: conversation("c1"), until: nil)], enqueueing: [], at: date(200))
        let expected: [[ConversationID]] = [[], [conversation("c1")], [conversation("c2"), conversation("c1")], [conversation("c2")]]
        let deadline = Date().addingTimeInterval(3)
        while seen.values.map({ $0.map(\.conversationID) }) != expected, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(seen.values.map { $0.map(\.conversationID) }, expected)
        // Mail arriving in an unsnoozed conversation changes nothing a subscriber sees.
        try store.upsertMessages([message("m9", in: "c9")])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(seen.values.count, expected.count)
    }
}

/// What an observation delivered, in order, on the main thread.
private final class SnoozeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Snooze]] = []
    var values: [[Snooze]] { lock.withLock { storage } }
    func append(_ value: [Snooze]) { lock.withLock { storage.append(value) } }
}
