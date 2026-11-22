import Foundation
import PaperCore
import XCTest
@testable import PaperGmail

/// Throttled batch parts are sent again on their own and the rest of the batch is kept; Google's refill
/// time is read from Retry-After or, failing that, from its error message.
final class GmailThrottleTests: XCTestCase {
    private let server = StubServer.shared
    private let ids = (0..<10).map { "id\($0)" }

    override func setUp() {
        super.setUp()
        server.reset()
    }

    override func tearDown() {
        server.reset()
        super.tearDown()
    }

    private func success(_ index: Int, _ id: String) -> StubBatchPart {
        StubBatchPart(index: index, status: 200, json: GmailFixtures.metadata(id: id))
    }

    private func tooManyRequests(_ index: Int, retryAfter: String? = nil) -> StubBatchPart {
        StubBatchPart(index: index, status: 429, json: GmailFixtures.tooManyRequestsError,
                      headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
    }

    private func batchIDs() -> [[String]] {
        server.requests(to: "/batch/gmail/v1").map { TestSupport.batchRequestIDs(in: $0.bodyText) }
    }

    private func singleGets() -> [RecordedRequest] {
        server.requests.filter { $0.method == "GET" && $0.path.hasPrefix("/gmail/v1/users/me/messages/") }
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: Batch parts

    func testThrottledPartIsSentAgainAloneAndEveryPartIsKept() async throws {
        TestSupport.stubBatchRounds { round, index, id in
            round == 0 && id == "id6" ? self.tooManyRequests(index) : self.success(index, id)
        }
        let sleeps = SleepRecorder()
        let provider = TestSupport.makeProvider(throttleRetry: sleeps.retry())

        let messages = try await provider.metadata(for: ids)

        XCTAssertEqual(messages.map(\.id.providerID), ids, "every message, in the order asked for")
        XCTAssertEqual(batchIDs(), [ids, ["id6"]], "the nine answered parts are never fetched again")
        XCTAssertTrue(singleGets().isEmpty)
        XCTAssertEqual(sleeps.delays, [1], "no Retry-After: the first wait of the schedule")
    }

    func testRateLimitForbiddenPartIsSentAgainLikeTooManyRequests() async throws {
        TestSupport.stubBatchRounds { round, index, id in
            guard round == 0, id == "id2" else { return self.success(index, id) }
            return StubBatchPart(index: index, status: 403, json: GmailFixtures.userRateLimitError)
        }
        let provider = TestSupport.makeProvider()

        let messages = try await provider.metadata(for: ids)

        XCTAssertEqual(messages.map(\.id.providerID), ids)
        XCTAssertEqual(batchIDs(), [ids, ["id2"]])
    }

    func testPartsStillThrottledAfterTheScheduleAreReportedAsThrottled() async throws {
        TestSupport.stubBatchRounds { _, index, id in
            id == "id0" || id == "id5" ? self.tooManyRequests(index) : self.success(index, id)
        }
        let sleeps = SleepRecorder()
        let provider = TestSupport.makeProvider(throttleRetry: sleeps.retry(delays: [1, 2, 4]))

        let error = await TestSupport.providerError { _ = try await provider.metadata(for: self.ids) }

        guard case .throttled(let retryAfter)? = error else { return XCTFail("expected throttled, got \(String(describing: error))") }
        XCTAssertNil(retryAfter, "no part said when to come back")
        XCTAssertEqual(batchIDs(), [ids, ["id0", "id5"], ["id0", "id5"], ["id0", "id5"]], "one send, then one per scheduled wait")
        XCTAssertEqual(sleeps.delays, [1, 2, 4])
        XCTAssertTrue(singleGets().isEmpty, "a throttled id is not hammered one by one")
    }

    func testWaitsForTheLongestRetryAfterAmongThrottledParts() async throws {
        TestSupport.stubBatchRounds { round, index, id in
            switch (round, id) {
            case (0, "id1"): return self.tooManyRequests(index, retryAfter: "3")
            case (0, "id2"): return self.tooManyRequests(index, retryAfter: "5")
            case (0, "id3"): return self.tooManyRequests(index)
            default: return self.success(index, id)
            }
        }
        let sleeps = SleepRecorder()
        let provider = TestSupport.makeProvider(throttleRetry: sleeps.retry(delays: [1, 2, 4]))

        let messages = try await provider.metadata(for: ids)

        XCTAssertEqual(messages.map(\.id.providerID), ids)
        XCTAssertEqual(sleeps.delays, [5])
        XCTAssertEqual(batchIDs().last, ["id1", "id2", "id3"])
    }

    func testRetryAfterShorterThanTheScheduleDoesNotShortenTheWait() async throws {
        TestSupport.stubBatchRounds { round, index, id in
            round == 0 && id == "id4" ? self.tooManyRequests(index, retryAfter: "0") : self.success(index, id)
        }
        let sleeps = SleepRecorder()
        let provider = TestSupport.makeProvider(throttleRetry: sleeps.retry(delays: [1, 2, 4]))

        _ = try await provider.metadata(for: ids)

        XCTAssertEqual(sleeps.delays, [1], "a refill time already past (clock skew) still waits the schedule")
    }

    func testLongRetryAfterIsWaitedOutOnceSomeMessagesAreIn() async throws {
        TestSupport.stubBatchRounds { round, index, id in
            round == 0 && id == "id9" ? self.tooManyRequests(index, retryAfter: "30") : self.success(index, id)
        }
        let sleeps = SleepRecorder()
        let provider = TestSupport.makeProvider(throttleRetry: sleeps.retry())

        let messages = try await provider.metadata(for: ids)

        XCTAssertEqual(messages.map(\.id.providerID), ids, "reporting would throw the nine answered parts away")
        XCTAssertEqual(sleeps.delays, [30], "a per-minute quota refusal is waited out")
        XCTAssertEqual(batchIDs(), [ids, ["id9"]])
    }

    func testLongRetryAfterInALaterChunkKeepsTheEarlierChunks() async throws {
        let ids = (0..<25).map { "id\($0)" }
        TestSupport.stubBatchRounds { round, index, id in
            // Send 1 is the second chunk, refused whole: nothing of it is in, but the first chunk is.
            round == 1 ? self.tooManyRequests(index, retryAfter: "30") : self.success(index, id)
        }
        let sleeps = SleepRecorder()
        let provider = TestSupport.makeProvider(throttleRetry: sleeps.retry())

        let messages = try await provider.metadata(for: ids)

        XCTAssertEqual(messages.map(\.id.providerID), ids)
        XCTAssertEqual(sleeps.delays, [30])
        XCTAssertEqual(batchIDs(), [Array(ids[0..<10]), Array(ids[10..<20]), Array(ids[10..<20]), Array(ids[20..<25])],
                       "the first chunk is never fetched again")
    }

    func testLongRetryAfterWithNothingFetchedIsReportedAtOnce() async throws {
        TestSupport.stubBatchRounds { _, index, _ in self.tooManyRequests(index, retryAfter: "30") }
        let sleeps = SleepRecorder()
        let provider = TestSupport.makeProvider(throttleRetry: sleeps.retry())

        let error = await TestSupport.providerError { _ = try await provider.metadata(for: self.ids) }

        guard case .throttled(let retryAfter)? = error else { return XCTFail("expected throttled, got \(String(describing: error))") }
        XCTAssertEqual(retryAfter, 30, "the engine pauses the lane until then and shows it")
        XCTAssertEqual(batchIDs().count, 1)
        XCTAssertTrue(sleeps.delays.isEmpty, "stopping loses nothing, so the throttle goes to the engine")
    }

    func testRetryAfterBeyondTheQuotaWindowIsReportedAtOnce() async throws {
        TestSupport.stubBatchRounds { _, index, id in
            id == "id9" ? self.tooManyRequests(index, retryAfter: "120") : self.success(index, id)
        }
        let sleeps = SleepRecorder()
        let provider = TestSupport.makeProvider(throttleRetry: sleeps.retry())

        let error = await TestSupport.providerError { _ = try await provider.metadata(for: self.ids) }

        guard case .throttled(let retryAfter)? = error else { return XCTFail("expected throttled, got \(String(describing: error))") }
        XCTAssertEqual(retryAfter, 120, "longer than a quota minute: the engine pauses the lane and shows it")
        XCTAssertEqual(batchIDs().count, 1)
        XCTAssertTrue(sleeps.delays.isEmpty, "the provider does not sit unseen on a spent quota")
    }

    func testScheduleCeilingsDecideBetweenWaitingAndReporting() {
        let retry = SleepRecorder().retry(delays: [1, 2, 4], maxInlineWait: 60, maxWaitWithNothingFetched: 10)

        XCTAssertEqual(retry.delay(beforeRetry: 0, retryAfter: nil, hasFetched: false), 1)
        XCTAssertEqual(retry.delay(beforeRetry: 2, retryAfter: nil, hasFetched: true), 4)
        XCTAssertNil(retry.delay(beforeRetry: 3, retryAfter: nil, hasFetched: true), "the schedule is used up")
        XCTAssertEqual(retry.delay(beforeRetry: 1, retryAfter: 0.5, hasFetched: true), 2, "never shorter than the schedule")
        XCTAssertEqual(retry.delay(beforeRetry: 0, retryAfter: 10, hasFetched: false), 10)
        XCTAssertNil(retry.delay(beforeRetry: 0, retryAfter: 11, hasFetched: false))
        XCTAssertEqual(retry.delay(beforeRetry: 0, retryAfter: 60, hasFetched: true), 60)
        XCTAssertNil(retry.delay(beforeRetry: 0, retryAfter: 61, hasFetched: true))
    }

    func testCancellingDuringAThrottleWaitEndsTheCallAtOnce() async throws {
        TestSupport.stubBatchRounds { _, index, id in
            id == "id3" ? self.tooManyRequests(index) : self.success(index, id)
        }
        let waiting = expectation(description: "the throttle wait has begun")
        // The real sleep, so the test covers Task.sleep's cancellation and its mapping to the provider error.
        let retry = GmailThrottleRetry(delays: [30], maxInlineWait: 60, maxWaitWithNothingFetched: 10) { seconds in
            waiting.fulfill()
            try await GmailThrottleRetry.taskSleep(seconds)
        }
        let provider = TestSupport.makeProvider(throttleRetry: retry)
        let ids = self.ids
        let call = Task { try await provider.metadata(for: ids) }

        await fulfillment(of: [waiting], timeout: 5)
        let cancelledAt = Date()
        call.cancel()
        let error = await TestSupport.providerError { _ = try await call.value }

        guard case .cancelled? = error else { return XCTFail("expected cancelled, got \(String(describing: error))") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5, "the 30 s wait ends with the task")
        XCTAssertEqual(batchIDs(), [ids], "nothing is sent after the cancel")
        XCTAssertTrue(singleGets().isEmpty)
    }

    func testRefillTimeInAPartsMessageSetsTheWait() async throws {
        let stamp = Self.rfc3339(Date().addingTimeInterval(6))
        TestSupport.stubBatchRounds { round, index, id in
            guard round == 0, id == "id7" else { return self.success(index, id) }
            return StubBatchPart(index: index, status: 403, json: GmailFixtures.userRateLimitError(retryAt: stamp))
        }
        let sleeps = SleepRecorder()
        let provider = TestSupport.makeProvider(throttleRetry: sleeps.retry(delays: [0, 0, 0]))

        let messages = try await provider.metadata(for: ids)

        XCTAssertEqual(messages.map(\.id.providerID), ids)
        let wait = try XCTUnwrap(sleeps.delays.first)
        XCTAssertGreaterThan(wait, 4)
        XCTAssertLessThanOrEqual(wait, 6)
    }

    func testOtherFailedPartsAreFetchedOneByOneAfterTheThrottledOnes() async throws {
        TestSupport.stubBatchRounds { round, index, id in
            switch (round, id) {
            case (0, "id1"): return self.tooManyRequests(index)
            case (0, "id8"): return StubBatchPart(index: index, status: 500, json: GmailFixtures.serverError)
            default: return self.success(index, id)
            }
        }
        server.on("GET", "/users/me/messages/id8", .json(GmailFixtures.metadata(id: "id8")))
        let provider = TestSupport.makeProvider()

        let messages = try await provider.metadata(for: ids)

        XCTAssertEqual(messages.map(\.id.providerID), ids)
        XCTAssertEqual(batchIDs(), [ids, ["id1"]])
        XCTAssertEqual(singleGets().map(\.path), ["/gmail/v1/users/me/messages/id8"])
    }

    func testIDsTheReplyNeverAnsweredAreFetchedRatherThanDropped() async throws {
        server.on("POST", "/batch/gmail/v1", .batch(parts: [(0, 200, GmailFixtures.metadata(id: "a"))]))
        server.on("GET", "/users/me/messages/b", .json(GmailFixtures.metadata(id: "b")))
        let provider = TestSupport.makeProvider()

        let messages = try await provider.metadata(for: ["a", "b"])

        XCTAssertEqual(messages.map(\.id.providerID), ["a", "b"], "a missing id would read as deleted to changes")
        XCTAssertEqual(singleGets().map(\.path), ["/gmail/v1/users/me/messages/b"])
    }

    func testUnreadablePartBesideAnUnauthorizedOneRefreshesTheToken() async throws {
        server.sequence("POST", "/batch/gmail/v1", [
            .batch(parts: [(0, 200, "{\"not\":\"a message\"}"), (1, 401, GmailFixtures.unauthorizedError)]),
            .batch(parts: [(0, 200, GmailFixtures.metadataM1), (1, 200, GmailFixtures.metadataM2)]),
        ])
        let tokens = FakeTokenProvider()
        let provider = TestSupport.makeProvider(tokens: tokens)

        let messages = try await provider.metadata(for: ["m1", "m2"])

        XCTAssertEqual(messages.map(\.id.providerID), ["m1", "m2"])
        XCTAssertEqual(tokens.invalidations, 1)
        XCTAssertEqual(server.requests(to: "/batch/gmail/v1").map { $0.header("Authorization") }, ["Bearer token-1", "Bearer token-2"])
        XCTAssertTrue(singleGets().isEmpty, "one-by-one gets would be refused with the same token")
    }

    func testNonRateLimitForbiddenPartStillFailsTheCall() async {
        TestSupport.stubBatchRounds { _, index, id in
            id == "id3" ? StubBatchPart(index: index, status: 403, json: GmailFixtures.forbiddenError) : self.success(index, id)
        }
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.metadata(for: self.ids) }

        guard case .server(let status, _)? = error else { return XCTFail("expected server, got \(String(describing: error))") }
        XCTAssertEqual(status, 403)
        XCTAssertEqual(batchIDs().count, 1)
    }

    // MARK: A message Gmail will not return

    /// A message whose metadata Gmail kept failing on its own (a 500 for that one message) failed every changes call
    /// after it had paged the whole history: the cursor never moved and the account stayed on "Couldn't sync". It is
    /// left out now and kept as the store has it, since only a 404 says Gmail no longer has it, and the history moves
    /// on. A 500 is Gmail's passing backendError, so the cursor carries the message and a call `recheckSpacing` later
    /// asks for it again: new mail is not lost to a blip.
    func testAMessageGmailFailsForNowIsCarriedAndAskedAgain() async throws {
        server.on("GET", "/users/me/history", .json(GmailFixtures.history))
        var m2Fails = true
        TestSupport.stubBatchRounds { _, index, id in
            switch id {
            case "m4": return StubBatchPart(index: index, status: 200, json: GmailFixtures.metadataM4)
            case "m2" where !m2Fails: return StubBatchPart(index: index, status: 200, json: GmailFixtures.metadataM2)
            case "m2": return StubBatchPart(index: index, status: 500, json: GmailFixtures.serverError)
            default: return StubBatchPart(index: index, status: 404, json: GmailFixtures.notFoundError)
            }
        }
        server.on("GET", "/users/me/messages/m2", .json(GmailFixtures.serverError, status: 500))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let page = try await TestSupport.makeProvider(now: start).changes(since: "8675309", limit: 100)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m4"])
        XCTAssertEqual(Set(page.deletedIDs), ["m9", "m5"], "m2 failing says nothing about it; m5's 404 does")
        let carried = GmailHistoryCursor(parsing: page.cursor)
        XCTAssertEqual(carried.startHistoryID, "8675320", "the history moves on")
        XCTAssertEqual(carried.recheck, ["m2": 1])

        // A call in the same burst (the engine calls again at once while a page says hasMore) does not ask yet.
        server.on("GET", "/users/me/history", .json(GmailFixtures.emptyHistory))
        let burst = try await TestSupport.makeProvider(now: start.addingTimeInterval(1)).changes(since: page.cursor, limit: 100)
        XCTAssertEqual(burst.upserts.map(\.id.providerID), [])
        XCTAssertEqual(GmailHistoryCursor(parsing: burst.cursor).recheck, ["m2": 1])

        m2Fails = false
        let later = start.addingTimeInterval(GmailProvider.recheckSpacing + 1)
        let again = try await TestSupport.makeProvider(now: later).changes(since: burst.cursor, limit: 100)
        XCTAssertEqual(again.upserts.map(\.id.providerID), ["m2"])
        XCTAssertEqual(again.deletedIDs, [])
        XCTAssertEqual(again.cursor, "8675330", "nothing left to carry: a bare history id again")
    }

    /// One Gmail refuses for that message alone (a 400) would meet the same answer again: it keeps what the store has
    /// and is not carried. One that keeps failing is carried for `maxRecheckTries` tries, then left as stored.
    func testARefusedMessageIsNotCarriedAndOneThatKeepsFailingIsLetGo() async throws {
        server.on("GET", "/users/me/history", .json(GmailFixtures.history))
        TestSupport.stubBatchRounds { _, index, id in
            switch id {
            case "m4": return StubBatchPart(index: index, status: 400, json: GmailFixtures.serverError)
            case "m2": return StubBatchPart(index: index, status: 500, json: GmailFixtures.serverError)
            default: return StubBatchPart(index: index, status: 404, json: GmailFixtures.notFoundError)
            }
        }
        server.on("GET", "/users/me/messages/m4", .json(GmailFixtures.serverError, status: 400))
        server.on("GET", "/users/me/messages/m2", .json(GmailFixtures.serverError, status: 500))

        let page = try await TestSupport.makeProvider().changes(since: "8675309", limit: 100)
        XCTAssertEqual(Set(page.deletedIDs), ["m9", "m5"])
        XCTAssertEqual(GmailHistoryCursor(parsing: page.cursor).recheck, ["m2": 1], "m4 is refused, not carried")

        var start = GmailHistoryCursor(parsing: page.cursor)
        start.recheck = ["m2": GmailProvider.maxRecheckTries - 1]
        start.recheckAt = nil
        server.on("GET", "/users/me/history", .json(GmailFixtures.emptyHistory))
        let last = try await TestSupport.makeProvider().changes(since: start.encoded, limit: 100)
        XCTAssertEqual(last.cursor, "8675330", "given up: left as the store has it")
        XCTAssertEqual(last.deletedIDs, [])
    }

    /// A head page whose message Gmail failed or refused left it out silently, and a reconcile marked only the messages
    /// it hydrated as seen, so its sweep deleted mail Gmail still had. The page names them now, and the cursor carries
    /// the one that failed for now so the first polls ask for it again.
    func testABootstrapSaysWhichListedMessagesItCouldNotHydrate() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        server.on("GET", "/users/me/messages", .json(
            #"{"messages":[{"id":"m1","threadId":"t1"},{"id":"m2","threadId":"t2"},{"id":"m3","threadId":"t3"}]}"#))
        TestSupport.stubBatchRounds { _, index, id in
            switch id {
            case "m1": return StubBatchPart(index: index, status: 200, json: GmailFixtures.metadataM1)
            case "m2": return StubBatchPart(index: index, status: 500, json: GmailFixtures.serverError)
            default: return StubBatchPart(index: index, status: 400, json: GmailFixtures.serverError)
            }
        }
        server.on("GET", "/users/me/messages/m2", .json(GmailFixtures.serverError, status: 500))
        server.on("GET", "/users/me/messages/m3", .json(GmailFixtures.serverError, status: 400))

        let page = try await TestSupport.makeProvider().bootstrap(page: nil, limit: 100)

        XCTAssertEqual(page.messages.map(\.id.providerID), ["m1"])
        XCTAssertEqual(Set(page.unreadableIDs), ["m2", "m3"])
        XCTAssertEqual(Set(page.listedIDs), ["m1", "m2", "m3"])
        let cursor = GmailHistoryCursor(parsing: try XCTUnwrap(page.changeCursor))
        XCTAssertEqual(cursor.startHistoryID, "8675309")
        XCTAssertEqual(cursor.recheck, ["m2": 1], "the refused one is not asked again")
    }

    /// The same message no longer fails a backfill page or a server search: it is left out like an unknown one, and a
    /// lookup says which, so a reconcile keeps it rather than deleting it.
    func testMetadataLeavesOutAMessageGmailWillNotReturnAndSaysWhich() async throws {
        TestSupport.stubBatchRounds { _, index, id in
            id == "id3" ? StubBatchPart(index: index, status: 500, json: GmailFixtures.serverError) : self.success(index, id)
        }
        server.on("GET", "/users/me/messages/id3", .json(#"{"not":"a message"}"#))
        let provider = TestSupport.makeProvider()

        let messages = try await provider.metadata(for: ids)
        XCTAssertEqual(messages.map(\.id.providerID), ids.filter { $0 != "id3" })
        let lookup = try await provider.lookUpMetadata(for: ids)
        XCTAssertEqual(lookup.unreadable, ["id3"])
        XCTAssertEqual(lookup.refused, ["id3"], "a reply that does not decode would not decode next time either")
    }

    /// What the next request would meet too still fails the call: the network, here on the one-by-one fetch.
    func testTheNetworkFailingTheOneByOneFetchStillFailsTheCall() async {
        TestSupport.stubBatchRounds { _, index, id in
            id == "id3" ? StubBatchPart(index: index, status: 500, json: GmailFixtures.serverError) : self.success(index, id)
        }
        server.on("GET", "/users/me/messages/id3", .failure(URLError(.notConnectedToInternet)))
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.metadata(for: self.ids) }

        guard case .network? = error else { return XCTFail("expected network, got \(String(describing: error))") }
    }

    func testThrottledChangesHydrationKeepsTheAnsweredParts() async throws {
        server.on("GET", "/users/me/history", .json(GmailFixtures.history))
        TestSupport.stubBatchRounds { round, index, id in
            guard let json = [
                "m1": GmailFixtures.metadataM1, "m2": GmailFixtures.metadataM2, "m4": GmailFixtures.metadataM4,
            ][id] else {
                return StubBatchPart(index: index, status: 404, json: GmailFixtures.notFoundError)
            }
            return round == 0 && index == 0 ? self.tooManyRequests(index) : StubBatchPart(index: index, status: 200, json: json)
        }
        let provider = TestSupport.makeProvider()

        let page = try await provider.changes(since: "8675309", limit: 100)

        XCTAssertEqual(batchIDs().count, 2)
        XCTAssertEqual(batchIDs()[1].count, 1, "only the throttled part goes out again")
        let throttledID = batchIDs()[0][0]
        XCTAssertTrue(page.upserts.map(\.id.providerID).contains(throttledID))
        XCTAssertFalse(page.deletedIDs.contains(throttledID), "a throttled message is not mistaken for a deleted one")
    }

    // MARK: Retry time in the message

    func testRetryAfterTimestampInGooglesMessageIsParsed() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-07T10:29:15Z"))

        XCTAssertEqual(GmailHTTPClient.retryDelay(inMessage: "User-rate limit exceeded.  Retry after 2026-11-07T10:30:00.000Z", now: now), 45)
        XCTAssertEqual(GmailHTTPClient.retryDelay(inMessage: "Retry after 2026-11-07T10:30:00Z", now: now), 45, "fractional seconds are optional")
        XCTAssertEqual(GmailHTTPClient.retryDelay(inMessage: "Quota spent. Retry after 2026-11-07T11:30:00+01:00.", now: now), 45,
                       "an offset and a closing full stop")
        XCTAssertEqual(GmailHTTPClient.retryDelay(inMessage: "retry after 2026-11-07T10:29:45.500Z", now: now), 30.5)
        XCTAssertNil(GmailHTTPClient.retryDelay(inMessage: "Retry after 2026-11-07T10:00:00.000Z", now: now),
                     "a time already past says nothing, so the engine backs off rather than retrying at once")
        XCTAssertNil(GmailHTTPClient.retryDelay(inMessage: "Retry after 2026-11-07T10:29:15Z", now: now))
        XCTAssertNil(GmailHTTPClient.retryDelay(inMessage: "Too many concurrent requests for user", now: now))
        XCTAssertNil(GmailHTTPClient.retryDelay(inMessage: "Retry after a while", now: now))
        XCTAssertNil(GmailHTTPClient.retryDelay(inMessage: "Retry after", now: now))
    }

    func testRetryTimeIsReadFromTheErrorDetailsWhenTheTopMessageHasNone() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-07T10:29:15Z"))
        let body = """
        {"error":{"code":403,"message":"Rate Limit Exceeded","errors":[{"message":"Rate Limit Exceeded. Retry after 2026-11-07T10:29:25Z","reason":"rateLimitExceeded"}]}}
        """

        XCTAssertEqual(GmailHTTPClient.retryDelay(inBody: Data(body.utf8), now: now), 10)
        XCTAssertNil(GmailHTTPClient.retryDelay(inBody: Data("not json".utf8), now: now))
    }

    func testThrottledResponseTakesItsRetryTimeFromTheMessage() async throws {
        let stamp = Self.rfc3339(Date().addingTimeInterval(90))
        server.on("GET", "/users/me/profile", .json(GmailFixtures.userRateLimitError(retryAt: stamp), status: 403))
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.profile() }

        guard case .throttled(let retryAfter)? = error else { return XCTFail("expected throttled, got \(String(describing: error))") }
        let seconds = try XCTUnwrap(retryAfter)
        XCTAssertGreaterThan(seconds, 85)
        // The stamp is written with fractional seconds, rounded to the millisecond, so it can land a fraction of a
        // millisecond past 90 s from the moment the client reads the clock.
        XCTAssertLessThanOrEqual(seconds, 90.01)
    }

    func testRetryAfterHeaderWinsOverTheMessage() {
        let body = Data(GmailFixtures.userRateLimitError(retryAt: Self.rfc3339(Date().addingTimeInterval(600))).utf8)

        guard case .throttled(let retryAfter)? = GmailHTTPClient.error(status: 403, body: body, retryAfter: "7") else {
            return XCTFail("expected throttled")
        }
        XCTAssertEqual(retryAfter, 7)
    }

    // MARK: Log details

    func testThrottleDetailsCarryGooglesReasonsStatusAndMessage() {
        let quota = GmailHTTPClient.ThrottleDetails(status: 403, body: Data(GmailFixtures.userRateLimitError.utf8))
        XCTAssertEqual(quota.status, 403)
        XCTAssertEqual(quota.reasons, ["userRateLimitExceeded"])
        XCTAssertNil(quota.googleStatus)
        XCTAssertEqual(quota.message, "User-rate limit exceeded.  Retry after 2024-11-01T12:00:00.000Z")

        let concurrency = GmailHTTPClient.ThrottleDetails(status: 429, body: Data(GmailFixtures.tooManyRequestsError.utf8))
        XCTAssertEqual(concurrency.reasons, [])
        XCTAssertEqual(concurrency.googleStatus, "RESOURCE_EXHAUSTED")

        let opaque = GmailHTTPClient.ThrottleDetails(status: 429, body: Data("<html>".utf8))
        XCTAssertEqual(opaque.reasons, [])
        XCTAssertNil(opaque.googleStatus)
        XCTAssertNil(opaque.message)
    }

    func testRequestsNameTheirKindForTheThrottleLog() throws {
        XCTAssertEqual(try GmailBatch.request(paths: ["/x"], boundary: "b").kind, .batchMetadata)
        XCTAssertEqual(GmailRequest.Kind.batchMetadata.rawValue, "batch metadata")
    }
}
