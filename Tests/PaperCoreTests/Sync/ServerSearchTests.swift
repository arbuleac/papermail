import Foundation
import XCTest
@testable import PaperCore

/// The engine's search of the server (roadmap Q3.1, docs/ARCHITECTURE.md “Server search”): `MailProvider.search` for
/// each account in scope, metadata only for the hits the store lacks, written in one transaction so the list's search
/// finds them, bodies left for the reader to fetch on open, every request charged as live spend.
final class ServerSearchTests: XCTestCase {
    private let account = Fixtures.accountID

    private func hit(_ providerID: String, subject: String, roles: Set<MailboxRole> = [], account: AccountID = Fixtures.accountID,
                     daysAgo: Double = 400) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account, providerID: providerID),
            conversationID: ConversationID(accountID: account, providerID: "thread-\(providerID)"),
            subject: subject, snippet: "From the archive",
            from: EmailAddress(name: "Priya Raman", address: "priya@example.com"),
            to: [EmailAddress(address: "me@example.com")],
            date: Fixtures.baseDate.addingTimeInterval(-daysAgo * 86_400), roles: roles,
            isRead: true, isStarred: false, hasAttachments: false
        )
    }

    // MARK: What is written

    func testOnlyHitsTheStoreLacksAreFetchedAndWritten() async throws {
        let provider = ScriptedProvider(accountID: account)
        let harness = try EngineHarness(provider: provider)
        // Stored and read here; the server's copy says unread. A stored hit is left exactly as it is.
        var stored = Fixtures.message(1, conversation: "t-stored")
        stored.isRead = true
        try harness.store.upsertMessages([stored])
        var serverCopy = stored
        serverCopy.isRead = false
        provider.metadataByID = ["1": serverCopy, "2": hit("2", subject: "Lisbon photos"), "3": hit("3", subject: "Lisbon receipt")]
        provider.searchResults = [.success(["3", "1", "2", "3"])]

        let result = try await harness.engine.searchServer(for: "  lisbon from:priya ", accountIDs: nil)

        XCTAssertEqual(provider.searchCalls.map(\.text), ["lisbon from:priya"], "the words go as typed, trimmed")
        XCTAssertEqual(provider.searchCalls.map(\.limit), [50])
        XCTAssertEqual(provider.metadataCalls, [["3", "2"]], "metadata only for the hits the store lacks, each once")
        XCTAssertEqual(result.downloaded, 2)
        XCTAssertEqual(result.failedAccounts, [])
        XCTAssertEqual(result.conversations, [ConversationID(accountID: account, providerID: "t-stored"),
                                              ConversationID(accountID: account, providerID: "thread-2"),
                                              ConversationID(accountID: account, providerID: "thread-3")],
                       "stored hits join the results as they are")
        XCTAssertEqual(try harness.store.message(stored.id)?.isRead, true, "a hit already stored changes nothing")
        XCTAssertEqual(try harness.store.message(MessageID(accountID: account, providerID: "2"))?.subject, "Lisbon photos")
        XCTAssertTrue(provider.bodyCalls.isEmpty, "no body is fetched by the search")
        await harness.shutdown()
    }

    /// The hits are full rows of the SQLite store: their subject, people and snippet (until the body replaces it) are in
    /// the full-text index at once, so the list's own search finds them with no server matches at all.
    func testHitsAreSearchableInTheStoreAtOnce() async throws {
        let sqlite = try SQLiteMailStore.inMemory()
        try sqlite.upsertAccount(Fixtures.account())
        let provider = ScriptedProvider(accountID: account)
        provider.metadataByID = ["2": hit("2", subject: "Lisbon photos, finally")]
        provider.searchResults = [.success(["2"])]
        let harness = try EngineHarness(provider: provider, seedAccount: false, engineStore: sqlite)

        let before = try sqlite.conversations(ConversationQuery(view: .all, searchText: "lisbon"))
        XCTAssertTrue(before.isEmpty)
        _ = try await harness.engine.searchServer(for: "lisbon", accountIDs: [account])

        XCTAssertEqual(try sqlite.conversations(ConversationQuery(view: .all, searchText: "lisbon")).map(\.id.providerID), ["thread-2"])
        XCTAssertEqual(try sqlite.conversations(ConversationQuery(view: .all, searchText: "priya")).map(\.id.providerID), ["thread-2"])
        XCTAssertEqual(try sqlite.conversations(ConversationQuery(view: .all, searchText: "archive")).map(\.id.providerID), ["thread-2"],
                       "words only its snippet holds find it too, so it outlives the search that found it")
        XCTAssertNil(try sqlite.body(for: MessageID(accountID: account, providerID: "2")))
        try sqlite.verifyFullTextIndex()
        await harness.shutdown()
    }

    /// The reader's existing path for mail the backfill has not reached: opening a found message fetches its body.
    func testAFoundMessagesBodyIsFetchedWhenItOpens() async throws {
        let provider = ScriptedProvider(accountID: account)
        let id = MessageID(accountID: account, providerID: "2")
        provider.metadataByID = ["2": hit("2", subject: "Lisbon photos")]
        provider.bodies = ["2": .success(MessageBody(html: "<p>The tram 28 one</p>", text: "The tram 28 one"))]
        provider.searchResults = [.success(["2"])]
        let harness = try EngineHarness(provider: provider)

        _ = try await harness.engine.searchServer(for: "lisbon", accountIDs: nil)
        XCTAssertNil(try harness.store.body(for: id))
        XCTAssertEqual(provider.bodyCalls, [])

        let body = try await harness.engine.ensureBody(for: id)
        XCTAssertEqual(body.plainText, "The tram 28 one")
        XCTAssertEqual(provider.bodyCalls, ["2"])
        await harness.shutdown()
    }

    func testHitsInTrashOrSpamAreLeftOut() async throws {
        let provider = ScriptedProvider(accountID: account, kind: .microsoft)
        provider.metadataByID = ["t": hit("t", subject: "Lisbon (deleted)", roles: [.trash]),
                                 "s": hit("s", subject: "Lisbon deals", roles: [.spam]),
                                 "k": hit("k", subject: "Lisbon agenda")]
        provider.searchResults = [.success(["t", "s", "k"])]
        let harness = try EngineHarness(provider: provider)

        let result = try await harness.engine.searchServer(for: "lisbon", accountIDs: nil)

        XCTAssertEqual(result.conversations, [ConversationID(accountID: account, providerID: "thread-k")])
        XCTAssertEqual(result.downloaded, 1)
        XCTAssertNil(try harness.store.message(MessageID(accountID: account, providerID: "t")))
        XCTAssertNil(try harness.store.message(MessageID(accountID: account, providerID: "s")))
        await harness.shutdown()
    }

    /// While a backfill runs, a message the live lane deleted is marked; a search answered from a stale index must not
    /// bring it back, which the backfill's own write rules guarantee.
    func testAHitTheLiveLaneDeletedIsNotBroughtBack() async throws {
        let provider = ScriptedProvider(accountID: account)
        provider.metadataByID = ["9": hit("9", subject: "Lisbon")]
        provider.searchResults = [.success(["9"])]
        let harness = try EngineHarness(provider: provider)
        try harness.store.markLiveChanges(accountID: account, upserted: [], deleted: ["9"])

        let result = try await harness.engine.searchServer(for: "lisbon", accountIDs: nil)

        XCTAssertEqual(result.downloaded, 0)
        XCTAssertEqual(provider.metadataCalls, [], "nothing to fetch for it")
        XCTAssertNil(try harness.store.message(MessageID(accountID: account, providerID: "9")))
        await harness.shutdown()
    }

    func testBlankWordsAskNothing() async throws {
        let harness = try EngineHarness()
        let result = try await harness.engine.searchServer(for: "  \n", accountIDs: nil)
        XCTAssertEqual(result, ServerSearchResult())
        XCTAssertEqual(harness.provider.searchCalls.count, 0)
        await harness.shutdown()
    }

    // MARK: Quota

    /// Gmail: the listing is `messages.list` (5 units) and each new hit's metadata 20; a stored hit costs nothing more.
    func testAGmailSearchIsChargedTheListingAndNewMetadataAsLiveSpend() async throws {
        let spent = try await liveSpend(kind: .gmail)
        XCTAssertEqual(spent.first, 5 + 2 * 20, accuracy: 0.000_1)
        XCTAssertEqual(spent.again, 5, accuracy: 0.000_1, "the same search again finds everything stored")
    }

    /// Outlook: one request for `$search`, one per message fetched by id.
    func testAGraphSearchIsChargedOneRequestPlusOnePerNewHit() async throws {
        let spent = try await liveSpend(kind: .microsoft)
        XCTAssertEqual(spent.first, 1 + 2, accuracy: 0.000_1)
        XCTAssertEqual(spent.again, 1, accuracy: 0.000_1)
    }

    private func liveSpend(kind: ProviderKind) async throws -> (first: Double, again: Double) {
        let provider = ScriptedProvider(accountID: account, kind: kind)
        provider.metadataByID = ["2": hit("2", subject: "Lisbon photos"), "3": hit("3", subject: "Lisbon receipt")]
        provider.searchResults = [.success(["2", "3"]), .success(["2", "3"])]
        let budgets = SearchBudgetRecorder()
        let start = Date()
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.quota = { .standard(for: $0.kind) }
            tuning.makeBudget = { quota in budgets.add(QuotaBudget(quota: quota, now: { start })) }
        }
        _ = try await harness.engine.searchServer(for: "lisbon", accountIDs: nil)
        let budget = try XCTUnwrap(budgets.first)
        let afterFirst = await budget.liveHeadroom
        _ = try await harness.engine.searchServer(for: "lisbon", accountIDs: nil)
        let afterAgain = await budget.liveHeadroom
        await harness.shutdown()
        return (budget.liveCapacity - afterFirst, afterFirst - afterAgain)
    }

    func testAThrottledSearchPausesTheBackfillAndNamesTheAccount() async throws {
        let provider = ScriptedProvider(accountID: account)
        provider.searchResults = [.failure(ProviderError.throttled(retryAfter: 30))]
        let budgets = SearchBudgetRecorder()
        let start = Date()
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.quota = { .standard(for: $0.kind) }
            tuning.makeBudget = { quota in budgets.add(QuotaBudget(quota: quota, now: { start })) }
        }

        let result = try await harness.engine.searchServer(for: "lisbon", accountIDs: nil)

        XCTAssertEqual(result.failedAccounts, [account], "a failure is reported in the result, never thrown")
        let budget = try XCTUnwrap(budgets.first)
        let paused = await budget.pausedUntil
        XCTAssertEqual(try XCTUnwrap(paused).timeIntervalSince(start), 30, accuracy: 0.5,
                       "the backfill waits out the provider's retry time, as for any live throttle")
        await harness.shutdown()
    }

    // MARK: Several accounts

    func testAFailedAccountIsNamedAndTheOthersStillAnswer() async throws {
        let other = AccountID("22222222-2222-2222-2222-222222222222")
        let failing = ScriptedProvider(accountID: account)
        failing.searchResults = [.failure(ProviderError.network("offline"))]
        let answering = ScriptedProvider(accountID: other, kind: .microsoft)
        answering.metadataByID = ["k": hit("k", subject: "Lisbon agenda", account: other)]
        answering.searchResults = [.success(["k"])]
        let harness = try EngineHarness(provider: failing) { _ in } factory: { $0.id == other ? answering : failing }
        try harness.store.upsertAccount(Account(id: other, kind: .microsoft, email: "me@contoso.test", displayName: "Me",
                                                addedAt: Fixtures.baseDate.addingTimeInterval(60)))

        let result = try await harness.engine.searchServer(for: "lisbon", accountIDs: nil)

        XCTAssertEqual(result.failedAccounts, [account])
        XCTAssertEqual(result.conversations, [ConversationID(accountID: other, providerID: "thread-k")])
        XCTAssertEqual(failing.searchCalls.count, 1)
        XCTAssertEqual(answering.searchCalls.count, 1)

        // A scoped search asks only its account.
        answering.searchResults = [.success([])]
        _ = try await harness.engine.searchServer(for: "lisbon", accountIDs: [other])
        XCTAssertEqual(failing.searchCalls.count, 1)
        XCTAssertEqual(answering.searchCalls.count, 2)
        await harness.shutdown()
    }

    func testAccountsAreSearchedTwoAtATime() async throws {
        let ids = (1...3).map { AccountID("acct-\($0)") }
        let providers = Dictionary(uniqueKeysWithValues: ids.map { id -> (AccountID, ScriptedProvider) in
            let provider = ScriptedProvider(accountID: id)
            provider.holdSearch = true
            return (id, provider)
        })
        let harness = try EngineHarness(seedAccount: false) { _ in } factory: { providers[$0.id] ?? ScriptedProvider(accountID: $0.id) }
        for (index, id) in ids.enumerated() {
            try harness.store.upsertAccount(Account(id: id, kind: .gmail, email: "me\(index)@example.com", displayName: "Me",
                                                    addedAt: Fixtures.baseDate.addingTimeInterval(Double(index))))
        }
        let calls = { providers.values.reduce(0) { $0 + $1.searchCalls.count } }
        let search = Task { try await harness.engine.searchServer(for: "lisbon", accountIDs: nil) }

        try await waitUntil("two searches under way") { calls() == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls(), 2, "the third account waits for a slot")
        for provider in providers.values { provider.releaseSearch() }
        let result = try await search.value
        XCTAssertEqual(calls(), 3)
        XCTAssertEqual(result.failedAccounts, [])
        await harness.shutdown()
    }

    // MARK: Cancellation

    /// The words changed: the list cancels the search, which stops before asking for anything more.
    func testCancellingStopsTheSearchBeforeItFetchesMetadata() async throws {
        let provider = ScriptedProvider(accountID: account)
        provider.holdSearch = true
        provider.metadataByID = ["2": hit("2", subject: "Lisbon photos")]
        provider.searchResults = [.success(["2"])]
        let harness = try EngineHarness(provider: provider)
        let search = Task { try await harness.engine.searchServer(for: "lisbon", accountIDs: nil) }

        try await waitUntil("the search is asked") { provider.searchCalls.count == 1 }
        search.cancel()
        let outcome = await search.result

        guard case .failure(let error) = outcome else { return XCTFail("a cancelled search reports nothing") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertEqual(provider.metadataCalls, [])
        XCTAssertNil(try harness.store.message(MessageID(accountID: account, providerID: "2")))
        await harness.shutdown()
    }

    /// A unified search cancelled while its first two accounts are asked starts no others: they would each record live
    /// spend for a request that never goes out.
    func testACancelledSearchStartsNoMoreAccounts() async throws {
        let ids = (1...3).map { AccountID("acct-\($0)") }
        let providers = Dictionary(uniqueKeysWithValues: ids.map { id -> (AccountID, ScriptedProvider) in
            let provider = ScriptedProvider(accountID: id)
            provider.holdSearch = true
            return (id, provider)
        })
        let budgets = SearchBudgetRecorder()
        let start = Date()
        let harness = try EngineHarness(seedAccount: false) { tuning in
            tuning.quota = { .standard(for: $0.kind) }
            tuning.makeBudget = { quota in budgets.add(QuotaBudget(quota: quota, now: { start })) }
        } factory: { providers[$0.id] ?? ScriptedProvider(accountID: $0.id) }
        for (index, id) in ids.enumerated() {
            try harness.store.upsertAccount(Account(id: id, kind: .gmail, email: "me\(index)@example.com", displayName: "Me",
                                                    addedAt: Fixtures.baseDate.addingTimeInterval(Double(index))))
        }
        let calls = { providers.values.reduce(0) { $0 + $1.searchCalls.count } }
        let search = Task { try await harness.engine.searchServer(for: "lisbon", accountIDs: nil) }

        try await waitUntil("two searches under way") { calls() == 2 }
        search.cancel()
        let outcome = await search.result

        guard case .failure(let error) = outcome else { return XCTFail("a cancelled search reports nothing") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertEqual(calls(), 2, "the third account is never asked")
        var spent = 0.0
        for budget in budgets.all {
            let headroom = await budget.liveHeadroom
            spent += budget.liveCapacity - headroom
        }
        XCTAssertEqual(spent, 2 * 5, accuracy: 0.000_1, "two listings, nothing for the account never asked")
        await harness.shutdown()
    }
}

private final class SearchBudgetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var budgets: [QuotaBudget] = []

    var first: QuotaBudget? { lock.withLock { budgets.first } }
    var all: [QuotaBudget] { lock.withLock { budgets } }

    func add(_ budget: QuotaBudget) -> QuotaBudget {
        lock.withLock { budgets.append(budget) }
        return budget
    }
}
