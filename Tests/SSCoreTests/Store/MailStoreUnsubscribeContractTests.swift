import XCTest
import SSCore

/// The `MailStoring` contract for the list headers (roadmap Q2.4, docs/DATA-MODEL.md `messages.list_unsubscribe`) and
/// for storing several operations at once. Written as an extension so `SQLiteMailStoreContractTests` inherits every
/// case and both stores are held to the same semantics.
extension MailStoreContractTests {
    private var listHeader: String { "<https://news.example.com/u/42>, <mailto:leave@news.example.com>" }

    private func newsletter(_ providerID: String = "n1", list: String? = nil, post: String? = nil) -> MessageMetadata {
        var metadata = message(providerID, in: "news", subject: "Issue 42")
        metadata.listUnsubscribe = list
        metadata.listUnsubscribePost = post
        return metadata
    }

    private var newsletterID: MessageID { MessageID(accountID: accountA, providerID: "n1") }

    /// Gmail's path: the headers arrive with the metadata and read back as they were written.
    func testListHeadersRoundTripOnTheMessage() throws {
        try store.upsertMessages([newsletter(list: listHeader, post: "List-Unsubscribe=One-Click")])
        let stored = try XCTUnwrap(try store.message(newsletterID))
        XCTAssertEqual(stored.listUnsubscribe, listHeader)
        XCTAssertEqual(stored.listUnsubscribePost, "List-Unsubscribe=One-Click")
        XCTAssertEqual(try store.messages(in: stored.conversationID).first?.listUnsubscribe, listHeader)
        XCTAssertEqual(UnsubscribeMethod(message: stored), .oneClick(URL(string: "https://news.example.com/u/42")!))
    }

    /// Headers never change, and a Graph listing or delta cannot carry them: a write without them keeps the stored
    /// pair (flags and the rest still follow the write), while a write that carries them replaces both.
    func testAWriteWithoutListHeadersKeepsTheStoredPair() throws {
        try store.upsertMessages([newsletter(list: listHeader, post: "List-Unsubscribe=One-Click")])
        var flagged = newsletter()
        flagged.isStarred = true
        try store.upsertMessages([flagged])
        var stored = try XCTUnwrap(try store.message(newsletterID))
        XCTAssertTrue(stored.isStarred, "the rest of the write lands")
        XCTAssertEqual(stored.listUnsubscribe, listHeader, "a write that cannot carry the headers keeps them")
        XCTAssertEqual(stored.listUnsubscribePost, "List-Unsubscribe=One-Click")

        try store.writeBackfillMessages([newsletter()], refreshExisting: true)
        XCTAssertEqual(try store.message(newsletterID)?.listUnsubscribe, listHeader, "so does a reconciling backfill")

        try store.upsertMessages([newsletter(list: "<mailto:other@news.example.com>")])
        stored = try XCTUnwrap(try store.message(newsletterID))
        XCTAssertEqual(stored.listUnsubscribe, "<mailto:other@news.example.com>")
        XCTAssertNil(stored.listUnsubscribePost, "the pair is replaced together")
    }

    /// Graph's path: the body fetch brings the headers, and saving the body writes them on the message (both forms of
    /// the save), never into the body read back.
    func testABodyThatCarriesListHeadersWritesThemOnTheMessage() throws {
        try store.upsertMessages([newsletter()])
        XCTAssertNil(try store.message(newsletterID)?.listUnsubscribe, "none until something brings them")
        let body = StoredBody(
            body: MessageBody(html: "<p>Issue 42</p>", text: nil, listUnsubscribe: listHeader,
                              listUnsubscribePost: "List-Unsubscribe=One-Click"),
            renderedHTML: "<p>Issue 42</p>", plainText: "Issue 42"
        )
        try store.saveBody(body, for: newsletterID)
        let stored = try XCTUnwrap(try store.message(newsletterID))
        XCTAssertEqual(stored.listUnsubscribe, listHeader)
        XCTAssertEqual(stored.listUnsubscribePost, "List-Unsubscribe=One-Click")
        let readBack = try XCTUnwrap(try store.body(for: newsletterID))
        XCTAssertNil(readBack.body.listUnsubscribe, "the headers live on the message, not in the body")
        XCTAssertEqual(readBack.plainText, "Issue 42")

        // A later listing without them keeps them; a body without them leaves them too.
        try store.upsertMessages([newsletter()])
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Again</p>", text: nil), renderedHTML: "<p>Again</p>",
                                      plainText: "Again"), for: newsletterID)
        XCTAssertEqual(try store.message(newsletterID)?.listUnsubscribe, listHeader)

        try store.upsertMessages([newsletter("n2")])
        let n2 = MessageID(accountID: accountA, providerID: "n2")
        try store.saveBody(body, for: n2, evictingIfReceivedBefore: date(3600))
        XCTAssertEqual(try store.message(n2)?.listUnsubscribe, listHeader, "the backfill's save writes them as well, evicted or not")
    }

    /// An unsubscribe stores its request and the conversation's archive with one call: in order, the archive applied at
    /// once, the request carrying its method and changing nothing.
    func testSeveralOperationsAreStoredTogetherInOrder() throws {
        try store.upsertMessages([newsletter(list: listHeader)])
        let method = UnsubscribeMethod.mailto(URL(string: "mailto:leave@news.example.com")!)
        let archive = SSCore.Operation(id: "op-archive", accountID: accountA, change: .archive, targets: [newsletterID],
                                       createdAt: date(10))
        let request = SSCore.Operation(id: "op-unsubscribe", accountID: accountA, change: .unsubscribe(method), targets: [],
                                       createdAt: date(10).addingTimeInterval(0.001))
        try store.enqueue([archive, request])
        XCTAssertFalse(try XCTUnwrap(try store.message(newsletterID)).roles.contains(.inbox), "the archive is applied at once")
        let pending = try store.pendingOperations(accountID: accountA, limit: 10)
        XCTAssertEqual(pending.map(\.id), ["op-archive", "op-unsubscribe"])
        XCTAssertEqual(pending.last?.change, .unsubscribe(method), "the method and its URI travel with the operation")
        XCTAssertEqual(pending.last?.targets, [])
        XCTAssertNil(try store.conversations(ConversationQuery(view: .inbox)).first { $0.id.providerID == "news" })

        // The request changes nothing locally, so a poll that reports the message again leaves it as the archive left it.
        try store.upsertMessages([newsletter()])
        XCTAssertFalse(try XCTUnwrap(try store.message(newsletterID)).roles.contains(.inbox))

        // Deleting a live request (how the runner drops one quietly) marks nothing.
        try store.deleteOperation(id: "op-unsubscribe")
        XCTAssertNil(try store.conversations(ConversationQuery(view: .all)).first { $0.id.providerID == "news" }?.failedOperation)
    }
}
