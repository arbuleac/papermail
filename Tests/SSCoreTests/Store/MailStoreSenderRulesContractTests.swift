import XCTest
import SSCore

/// The `MailStoring` contract for `sender_rules` as the mirror of the server's rules (v23, docs/DATA-MODEL.md "Sender
/// rules"): every transition the user's changes make (`setSenderRule`), what a read of the server writes
/// (`replaceServerSenderRules`), what the engine's writes settle (`settleSenderRule`), and the order the engine sends
/// pending rows in. Written as an extension so `SQLiteMailStoreContractTests` inherits every case and both stores are held
/// to the same semantics.
extension MailStoreContractTests {
    private var deals: String { "deals@shop.example" }
    private var news: String { "news@letter.example" }

    private func rule(_ address: String, account: AccountID? = nil) throws -> SenderRule? {
        try store.senderRules().first { $0.accountID == (account ?? accountA) && $0.address == address }
    }

    /// One line per row of account A, by address: "address action sync [ids]".
    private func rows(_ account: AccountID? = nil) throws -> [String] {
        try store.senderRules().filter { $0.accountID == (account ?? accountA) }
            .map { "\($0.address) \($0.action.rawValue) \($0.sync.rawValue) \($0.serverIDs.joined(separator: ","))" }
    }

    private func set(_ action: SenderRule.Action?, _ address: String, at offset: TimeInterval, account: AccountID? = nil) throws {
        try store.setSenderRule(action, for: address, accountID: account ?? accountA, enqueueing: [], at: date(offset))
    }

    private func read(_ rules: [(id: String, address: String, action: SenderRule.Action)], at offset: TimeInterval = 50,
                      account: AccountID? = nil) throws {
        try store.replaceServerSenderRules(accountID: account ?? accountA,
                                           with: rules.map { ServerSenderRule(serverID: $0.id, address: $0.address, action: $0.action) },
                                           readAt: date(offset))
    }

    @discardableResult
    private func settle(_ address: String, _ outcome: SenderRuleOutcome) throws -> Bool {
        try store.settleSenderRule(for: address, accountID: accountA, outcome)
    }

    // MARK: The user's changes

    func testANewRuleIsCreatingAndAChangeBeforeItReachedTheServerStaysSo() throws {
        try set(.archive, deals, at: 100)
        XCTAssertEqual(try rule(deals), SenderRule(accountID: accountA, address: deals, action: .archive, createdAt: date(100),
                                                   sync: .creating))
        try set(.archive, deals, at: 110)
        XCTAssertEqual(try rule(deals)?.createdAt, date(100), "the same action again changes nothing")
        try set(.trash, deals, at: 120)
        XCTAssertEqual(try rule(deals), SenderRule(accountID: accountA, address: deals, action: .trash, createdAt: date(120),
                                                   sync: .creating), "still one create, of the action now chosen")
        try set(nil, deals, at: 130)
        XCTAssertNil(try rule(deals), "never on the server: removed at once")
        try set(nil, deals, at: 140)
        XCTAssertTrue(try store.senderRules().isEmpty)
    }

    func testChangingARuleTheServerHasReplacesItAndRemovingItDeletesIt() throws {
        try read([("f1", deals, .archive), ("f2", news, .trash)])
        XCTAssertEqual(try rows(), ["\(deals) archive saved f1", "\(news) trash saved f2"])

        try set(.archive, deals, at: 100)
        XCTAssertEqual(try rule(deals)?.sync, .saved, "the action it has already: nothing to do")
        XCTAssertEqual(try rule(deals)?.createdAt, date(50))
        try set(.trash, deals, at: 110)
        XCTAssertEqual(try rule(deals), SenderRule(accountID: accountA, address: deals, action: .trash, createdAt: date(110),
                                                   serverIDs: ["f1"], sync: .replacing), "the old id kept, to delete once replaced")
        try set(nil, deals, at: 120)
        XCTAssertEqual(try rule(deals), SenderRule(accountID: accountA, address: deals, action: .trash, createdAt: date(120),
                                                   serverIDs: ["f1"], sync: .deleting), "removed during its replacement")
        try set(nil, news, at: 130)
        XCTAssertEqual(try rows(), ["\(deals) trash deleting f1", "\(news) trash deleting f2"])
        XCTAssertEqual(try rule(news)?.isActive, false, "no longer the user's rule")
        try set(nil, news, at: 140)
        XCTAssertEqual(try rule(news)?.createdAt, date(130), "removing it again changes nothing")
    }

    /// Setting a rule again on one being deleted (an undo of the removal, or the other action) is a replacement: the row
    /// never claims a rule the server lacks, and the engine's read finds and adopts the server's own rule when it is the same.
    func testARuleSetAgainWhileItIsBeingDeletedIsAReplacement() throws {
        try read([("f1", deals, .archive)])
        try set(nil, deals, at: 100)
        try set(.archive, deals, at: 110)
        XCTAssertEqual(try rows(), ["\(deals) archive replacing f1"])
        try set(nil, deals, at: 120)
        try set(.trash, deals, at: 130)
        XCTAssertEqual(try rows(), ["\(deals) trash replacing f1"])
    }

    func testPendingRowsAreListedOldestFirstPerAccount() throws {
        try read([("f1", "a@x.example", .archive), ("f2", "b@x.example", .archive), ("f3", "c@x.example", .trash)])
        try set(.trash, "z@x.example", at: 100)
        try set(nil, "c@x.example", at: 90)
        try set(.trash, "b@x.example", at: 100)
        try set(.archive, "y@x.example", at: 80, account: accountB)
        XCTAssertEqual(try store.pendingSenderRules(accountID: accountA).map { "\($0.address) \($0.sync.rawValue)" },
                       ["c@x.example deleting", "b@x.example replacing", "z@x.example creating"],
                       "by when each took its state, then by address; the saved row is not listed")
        XCTAssertEqual(try store.pendingSenderRules(accountID: accountB).map(\.address), ["y@x.example"])
    }

    // MARK: A read of the server

    func testAReadReplacesTheSavedRowsWithTheServersList() throws {
        try read([("f1", deals, .archive), ("f2", news, .trash)], at: 50)
        try read([("f1", deals, .trash), ("f3", "Promo@Shop.Example", .archive)], at: 60)
        XCTAssertEqual(try rows(), ["\(deals) trash saved f1", "promo@shop.example archive saved f3"],
                       "a rule changed elsewhere is changed here, one gone goes, one new comes")
        XCTAssertEqual(try rule(deals)?.createdAt, date(50), "a rule the read knew keeps when it was first found")
        XCTAssertEqual(try rule("promo@shop.example")?.createdAt, date(60))
        try read([], at: 70)
        XCTAssertTrue(try store.senderRules().isEmpty)
    }

    /// Gmail can hold an archive filter and a trash filter for one sender, and runs both: one row, the block, with both
    /// ids, so removing it deletes both.
    func testSeveralRulesForOneSenderFoldIntoTheBlockWithEveryID() throws {
        try read([("f1", deals, .archive), ("f2", deals, .trash), ("f3", news, .archive), ("f4", news, .archive)])
        XCTAssertEqual(try rows(), ["\(deals) trash saved f1,f2", "\(news) archive saved f3,f4"])
        try set(nil, deals, at: 100)
        XCTAssertEqual(try rule(deals)?.serverIDs, ["f1", "f2"])
    }

    func testAReadLeavesTheRowsOnTheirWayAloneButAdoptsAnIdenticalRule() throws {
        try read([("f1", "r@x.example", .archive), ("f2", "d@x.example", .archive), ("f3", "g@x.example", .trash)])
        try set(.archive, deals, at: 100)
        try set(.trash, news, at: 100)
        try set(.trash, "r@x.example", at: 100)
        try set(nil, "d@x.example", at: 100)
        try set(nil, "g@x.example", at: 100)

        try read([("f1", "r@x.example", .archive), ("f2", "d@x.example", .archive), ("f9", deals, .archive),
                  ("f8", news, .archive), ("f7", "g@x.example", .archive)], at: 200)
        XCTAssertEqual(try rows(), [
            "d@x.example archive deleting f2",
            "\(deals) archive saved f9",
            "g@x.example archive saved f7",
            "\(news) trash creating ",
            "r@x.example trash replacing f1",
        ])
        XCTAssertEqual(try rule(deals)?.createdAt, date(100), "adopted: the server has the very rule set here")
        XCTAssertEqual(try rule("g@x.example")?.createdAt, date(200),
                       "the rule being deleted is gone, and the server's own rule for the sender takes its place")

        try read([("f1", "r@x.example", .archive), ("f9", deals, .archive)], at: 300)
        XCTAssertEqual(try rows(), ["\(deals) archive saved f9", "\(news) trash creating ", "r@x.example trash replacing f1"],
                       "a rule being deleted that the server no longer has is gone")
    }

    func testAReadForAnAccountTheStoreNoLongerHasWritesNothing() throws {
        try store.deleteAccount(accountB)
        try read([("f1", deals, .archive)], account: accountB)
        XCTAssertTrue(try store.senderRules().isEmpty)
        try read([("f1", deals, .archive)], account: accountA)
        XCTAssertEqual(try rows(), ["\(deals) archive saved f1"], "and each account's read is its own")
        XCTAssertEqual(try rows(accountB), [])
    }

    // MARK: What the engine did

    func testACreateSettlesTheRuleAsSaved() throws {
        try set(.trash, deals, at: 100)
        XCTAssertTrue(try settle(deals, .written(action: .trash, serverIDs: ["f1"], deleted: [])))
        XCTAssertEqual(try rule(deals), SenderRule(accountID: accountA, address: deals, action: .trash, createdAt: date(100),
                                                   serverIDs: ["f1"], sync: .saved))
        XCTAssertTrue(try store.pendingSenderRules(accountID: accountA).isEmpty)
    }

    /// The user chose the other action while the create was on its way: the server's new rule is the old one of a
    /// replacement now.
    func testACreateSettledAfterTheActionChangedReplacesWhatItMade() throws {
        try set(.trash, deals, at: 100)
        try set(.archive, deals, at: 110)
        XCTAssertTrue(try settle(deals, .written(action: .trash, serverIDs: ["f1"], deleted: [])))
        XCTAssertEqual(try rows(), ["\(deals) archive replacing f1"])
    }

    /// Removed before it reached the server, the row is gone: the settle says so, and the engine deletes what it made.
    func testACreateSettledAfterTheRuleWasRemovedFindsNoRow() throws {
        try set(.trash, deals, at: 100)
        try set(nil, deals, at: 110)
        XCTAssertFalse(try settle(deals, .written(action: .trash, serverIDs: ["f1"], deleted: [])))
        XCTAssertTrue(try store.senderRules().isEmpty, "nothing written")
    }

    /// A replacement records its new rule at once (beside the old, which still waits to be deleted), and is saved once the
    /// old is deleted.
    func testAReplacementRecordsTheNewRuleThenSettlesOnceTheOldIsDeleted() throws {
        try read([("f1", deals, .archive)])
        try set(.trash, deals, at: 100)
        XCTAssertTrue(try settle(deals, .written(action: .trash, serverIDs: ["f2"], deleted: [])))
        XCTAssertEqual(try rows(), ["\(deals) trash replacing f1,f2"], "the new rule known before the old goes")
        XCTAssertTrue(try settle(deals, .written(action: .trash, serverIDs: ["f2"], deleted: ["f1"])))
        XCTAssertEqual(try rows(), ["\(deals) trash saved f2"])
    }

    /// Removed while its replacement was on its way, the rule is deleted whole: the new rule as well as the old.
    func testAReplacementSettledAfterTheRuleWasRemovedLeavesEverythingToDelete() throws {
        try read([("f1", deals, .archive)])
        try set(.trash, deals, at: 100)
        try set(nil, deals, at: 110)
        XCTAssertTrue(try settle(deals, .written(action: .trash, serverIDs: ["f2"], deleted: ["f1"])))
        XCTAssertEqual(try rows(), ["\(deals) trash deleting f2"])
        XCTAssertTrue(try settle(deals, .deleted(serverIDs: ["f2"])))
        XCTAssertTrue(try store.senderRules().isEmpty)
    }

    /// Back to the action the server had (an undo of the change): the engine adopts the server's own rule and deletes
    /// nothing, and the row is as it was.
    func testAReplacementBackToTheServersOwnRuleAdoptsIt() throws {
        try read([("f1", deals, .archive)])
        try set(.trash, deals, at: 100)
        try set(.archive, deals, at: 110)
        XCTAssertTrue(try settle(deals, .written(action: .archive, serverIDs: ["f1"], deleted: [])))
        XCTAssertEqual(try rows(), ["\(deals) archive saved f1"])
    }

    func testADeleteRemovesTheRowOnceEveryIDIsGone() throws {
        try read([("f1", deals, .archive), ("f2", deals, .trash)])
        try set(nil, deals, at: 100)
        XCTAssertTrue(try settle(deals, .deleted(serverIDs: ["f1"])))
        XCTAssertEqual(try rows(), ["\(deals) trash deleting f2"])
        XCTAssertTrue(try settle(deals, .deleted(serverIDs: ["f2"])))
        XCTAssertTrue(try store.senderRules().isEmpty)
        XCTAssertFalse(try settle(deals, .deleted(serverIDs: ["f2"])), "no row left to settle")
    }

    /// The user set the rule again while its delete was on its way: what the server had is gone, so it is made anew.
    func testADeleteSettledAfterTheRuleWasSetAgainMakesItAnew() throws {
        try read([("f1", deals, .archive)])
        try set(nil, deals, at: 100)
        try set(.archive, deals, at: 110)
        XCTAssertTrue(try settle(deals, .deleted(serverIDs: ["f1"])))
        XCTAssertEqual(try rows(), ["\(deals) archive creating "])
    }

    func testARefusedCreateIsGivenUp() throws {
        try set(.trash, deals, at: 100)
        XCTAssertTrue(try settle(deals, .refused(attempted: .creating, serverHas: nil)))
        XCTAssertTrue(try store.senderRules().isEmpty)
    }

    /// A delete or a replacement the server refuses is given up, and the rule is back as the server has it (or gone when the
    /// read found nothing it can show under the row's ids).
    func testARefusedDeleteOrReplacementIsBackAsTheServerHasIt() throws {
        try read([("f1", deals, .archive), ("f2", news, .trash), ("f3", "r@x.example", .archive)])
        try set(nil, deals, at: 100)
        try set(.archive, news, at: 100)
        try set(.trash, "r@x.example", at: 100)
        XCTAssertTrue(try settle(deals, .refused(attempted: .deleting, serverHas: .archive)))
        XCTAssertTrue(try settle(news, .refused(attempted: .replacing, serverHas: .trash)))
        XCTAssertTrue(try settle("r@x.example", .refused(attempted: .replacing, serverHas: nil)))
        XCTAssertEqual(try rows(), ["\(deals) archive saved f1", "\(news) trash saved f2"])
    }

    /// A refusal of a write the row has moved on from (the user changed it again meanwhile) leaves it to the next turn.
    func testARefusalOfAWriteTheRowMovedOnFromChangesNothing() throws {
        try read([("f1", deals, .archive)])
        try set(nil, deals, at: 100)
        try set(.trash, deals, at: 110)
        XCTAssertTrue(try settle(deals, .refused(attempted: .deleting, serverHas: .archive)))
        XCTAssertEqual(try rows(), ["\(deals) trash replacing f1"])
        XCTAssertFalse(try settle(news, .refused(attempted: .creating, serverHas: nil)), "no row")
    }

    func testObservingSenderRulesDeliversEveryStateChange() throws {
        let box = ObservedValues()
        let observation = store.observeSenderRules { box.append($0.map { "\($0.address) \($0.sync.rawValue)" }) }
        defer { observation.cancel() }
        try set(.trash, deals, at: 100)
        try settle(deals, .written(action: .trash, serverIDs: ["f1"], deleted: []))
        try set(nil, deals, at: 110)
        try read([], at: 120)
        let expected: [[String]] = [[], ["\(deals) creating"], ["\(deals) saved"], ["\(deals) deleting"], []]
        let deadline = Date().addingTimeInterval(3)
        while box.values != expected, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(box.values, expected)
        try read([], at: 130)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(box.values.count, expected.count, "a read that changes nothing delivers nothing")
    }
}
