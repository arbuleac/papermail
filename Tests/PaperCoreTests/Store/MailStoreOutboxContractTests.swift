import XCTest
import PaperCore

/// The `MailStoring` contract for the Outbox view (spec §5.53): the store holds no conversation for it, whatever mail it
/// holds and whatever waits in the outbox, since its rows are the outbox's (`SendLaterConversation.outboxSummary`). Written
/// as an extension so `SQLiteMailStoreContractTests` inherits every case and both stores are held to the same semantics.
extension MailStoreContractTests {
    func testTheOutboxViewListsNoConversation() throws {
        try store.upsertMessages([
            message("m1", in: "inbox"), message("m2", in: "sent", roles: [.sent]), message("m3", in: "draft", roles: [.drafts]),
            message("m4", in: "trash", roles: [.trash]), message("m5", in: "other", account: accountB, roles: [.sent]),
        ])
        try store.enqueueSend(PendingSend(id: "s1", message: outgoing(from: accountA), createdAt: date(10), sendAfter: date(15)))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .sent)), ["sent", "other"], "the mail is there")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .outbox)), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(accountIDs: [accountB], view: .outbox)), [], "in one account's scope too")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .outbox, before: date(1_000))), [], "nor on a later page")
        XCTAssertEqual(try store.pendingSendSummaries().map(\.id), ["s1"], "the outbox is read on its own")
    }

    /// Its observation delivers the empty list once and is never woken by mail arriving: it reads no table.
    func testObservingTheOutboxViewDeliversNothingButItsFirstValue() throws {
        try store.upsertMessages([message("m1", in: "c1", roles: [.sent])])
        let initial = expectation(description: "initial value")
        let box = ObservedValues()
        let observation = store.observeConversations(ConversationQuery(view: .outbox)) { summaries in
            XCTAssertTrue(summaries.isEmpty)
            if box.append(summaries.map(\.id.providerID)) == 1 { initial.fulfill() }
        }
        wait(for: [initial], timeout: 2)
        try store.upsertMessages([message("m2", in: "c2", date: date(100), roles: [.sent])])
        try store.enqueueSend(PendingSend(id: "s1", message: outgoing(from: accountA), createdAt: date(10), sendAfter: date(15)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(box.values.allSatisfy(\.isEmpty), "never a conversation")
        observation.cancel()
    }
}
