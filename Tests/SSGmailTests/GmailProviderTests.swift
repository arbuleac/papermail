import Foundation
import SSCore
import XCTest
@testable import SSGmail

final class GmailProviderTests: XCTestCase {
    private let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
    }

    override func tearDown() {
        server.reset()
        super.tearDown()
    }

    // MARK: Profile

    func testProfileFallsBackToLocalPartAndSendsBearerToken() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        let provider = TestSupport.makeProvider()

        let profile = try await provider.profile()

        XCTAssertEqual(profile.email, "ada@example.com")
        XCTAssertEqual(profile.displayName, "ada")
        let request = try XCTUnwrap(server.requests(to: "/users/me/profile").first)
        XCTAssertEqual(request.header("Authorization"), "Bearer token-1")
        XCTAssertEqual(request.url.host, "gmail.googleapis.com")
        XCTAssertEqual(request.path, "/gmail/v1/users/me/profile")
    }

    // MARK: Bootstrap

    func testBootstrapFirstPageCapturesCursorAndHydratesInListOrder() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        server.on("GET", "/users/me/messages", .json(GmailFixtures.messageList))
        TestSupport.stubBatch(messages: ["m1": GmailFixtures.metadataM1, "m2": GmailFixtures.metadataM2])
        let provider = TestSupport.makeProvider()

        let page = try await provider.bootstrap(page: nil, limit: 100)

        XCTAssertEqual(page.changeCursor, "8675309")
        XCTAssertEqual(page.nextPage, "page-2")
        XCTAssertEqual(page.messages.map(\.id.providerID), ["m1", "m2"])
        XCTAssertEqual(page.messages[0].subject, "Analytical Engine \u{2014} notes")
        XCTAssertEqual(page.messages[1].inboxSection, .other)

        let list = try XCTUnwrap(server.requests(to: "/users/me/messages").first)
        XCTAssertEqual(list.query["q"], ["-in:spam -in:trash"])
        XCTAssertEqual(list.query["maxResults"], ["100"])
        XCTAssertNil(list.query["pageToken"])

        let batch = try XCTUnwrap(server.requests(to: "/batch/gmail/v1").first)
        XCTAssertEqual(batch.url.host, "www.googleapis.com")
        XCTAssertTrue(batch.header("Content-Type")?.hasPrefix("multipart/mixed; boundary=") ?? false)
        XCTAssertEqual(batch.header("Authorization"), "Bearer token-1")
        XCTAssertEqual(TestSupport.batchRequestIDs(in: batch.bodyText), ["m1", "m2"])
        XCTAssertTrue(batch.bodyText.contains("Content-Type: application/http"))
        XCTAssertTrue(batch.bodyText.contains("GET /gmail/v1/users/me/messages/m1?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Bcc&metadataHeaders=Reply-To&metadataHeaders=Subject&metadataHeaders=Date&metadataHeaders=Message-ID&metadataHeaders=In-Reply-To&metadataHeaders=References HTTP/1.1"))
    }

    func testBootstrapLaterPagePassesTokenAndCapturesNoCursor() async throws {
        server.on("GET", "/users/me/messages", .json(GmailFixtures.lastMessageList))
        TestSupport.stubBatch(messages: ["m2": GmailFixtures.metadataM2])
        let provider = TestSupport.makeProvider()

        let page = try await provider.bootstrap(page: "page-2", limit: 50)

        XCTAssertNil(page.changeCursor)
        XCTAssertNil(page.nextPage)
        XCTAssertEqual(page.messages.map(\.id.providerID), ["m2"])
        XCTAssertTrue(server.requests(to: "/users/me/profile").isEmpty, "later pages must not re-read the profile")
        let list = try XCTUnwrap(server.requests(to: "/users/me/messages").first)
        XCTAssertEqual(list.query["pageToken"], ["page-2"])
    }

    func testBootstrapClampsLimitToGmailMaximum() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        server.on("GET", "/users/me/messages", .json("{}"))
        let provider = TestSupport.makeProvider()

        let page = try await provider.bootstrap(page: nil, limit: 5000)

        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertNil(page.nextPage)
        XCTAssertEqual(server.requests(to: "/users/me/messages").first?.query["maxResults"], ["500"])
        XCTAssertTrue(server.requests(to: "/batch/gmail/v1").isEmpty, "an empty list must not call the batch endpoint")
    }

    func testBootstrapFallsBackToSequentialGetsWhenBatchIsUnparseable() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        server.on("GET", "/users/me/messages", .json(GmailFixtures.messageList))
        server.on("POST", "/batch/gmail/v1", StubResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>oops</html>".utf8)))
        server.on("GET", "/users/me/messages/m1", .json(GmailFixtures.metadataM1))
        server.on("GET", "/users/me/messages/m2", .json(GmailFixtures.metadataM2))
        let provider = TestSupport.makeProvider()

        let page = try await provider.bootstrap(page: nil, limit: 10)

        XCTAssertEqual(page.messages.map(\.id.providerID), ["m1", "m2"])
        let single = try XCTUnwrap(server.requests(to: "/users/me/messages/m1").first)
        XCTAssertEqual(single.query["format"], ["metadata"])
        XCTAssertEqual(single.query["metadataHeaders"]?.count, 10)
    }

    func testBatchInnerUnauthorizedInvalidatesTokenAndRetries() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        server.on("GET", "/users/me/messages", .json(GmailFixtures.lastMessageList))
        server.sequence("POST", "/batch/gmail/v1", [
            .batch(parts: [(0, 401, GmailFixtures.unauthorizedError)]),
            .batch(parts: [(0, 200, GmailFixtures.metadataM2)]),
        ])
        let tokens = FakeTokenProvider()
        let provider = TestSupport.makeProvider(tokens: tokens)

        let page = try await provider.bootstrap(page: nil, limit: 10)

        XCTAssertEqual(page.messages.map(\.id.providerID), ["m2"])
        XCTAssertEqual(tokens.invalidations, 1)
        let batches = server.requests(to: "/batch/gmail/v1")
        XCTAssertEqual(batches.map { $0.header("Authorization") }, ["Bearer token-1", "Bearer token-2"])
    }

    // MARK: Changes

    func testChangesCollectsAddedDeletedAndRelabeledMessages() async throws {
        server.on("GET", "/users/me/history", .json(GmailFixtures.history))
        TestSupport.stubBatch(messages: ["m4": GmailFixtures.metadataM4, "m2": GmailFixtures.metadataM2])
        let provider = TestSupport.makeProvider()

        let page = try await provider.changes(since: "8675309", limit: 100)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m4", "m2"])
        XCTAssertEqual(page.upserts[0].isRead, false)
        XCTAssertEqual(page.upserts[0].providerVersion, "8675310")
        XCTAssertEqual(page.deletedIDs, ["m9", "m5"], "m9 was deleted by history; m5 vanished before hydration")
        XCTAssertEqual(page.cursor, "8675320")
        XCTAssertFalse(page.hasMore)

        let request = try XCTUnwrap(server.requests(to: "/users/me/history").first)
        XCTAssertEqual(request.query["startHistoryId"], ["8675309"])
        XCTAssertEqual(Set(request.query["historyTypes"] ?? []), ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"])
        XCTAssertEqual(request.query["maxResults"], ["100"])
        XCTAssertEqual(TestSupport.batchRequestIDs(in: server.requests(to: "/batch/gmail/v1")[0].bodyText), ["m4", "m2", "m5"])
    }

    func testChangesFollowsHistoryPagesWithinOneCall() async throws {
        server.on("GET", "/users/me/history") { request in
            request.query["pageToken"] == ["history-page-2"] ? .json(GmailFixtures.historyPageTwo) : .json(GmailFixtures.historyPageOne)
        }
        TestSupport.stubBatch(messages: ["m4": GmailFixtures.metadataM4, "m2": GmailFixtures.metadataM2])
        let provider = TestSupport.makeProvider()

        let page = try await provider.changes(since: "8675309", limit: 100)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m4", "m2"])
        XCTAssertEqual(page.cursor, "8675320")
        XCTAssertFalse(page.hasMore)
        let requests = server.requests(to: "/users/me/history")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].query["pageToken"], ["history-page-2"])
        XCTAssertEqual(requests[1].query["startHistoryId"], ["8675309"])
    }

    func testChangesStopsAtLimitAndResumesFromLastRecord() async throws {
        server.on("GET", "/users/me/history", .json(GmailFixtures.historyPageOne))
        TestSupport.stubBatch(messages: ["m4": GmailFixtures.metadataM4])
        let provider = TestSupport.makeProvider()

        let page = try await provider.changes(since: "8675309", limit: 1)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m4"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.cursor, "8675310", "the next poll continues after the last record seen")
        XCTAssertEqual(server.requests(to: "/users/me/history").count, 1)
    }

    func testChangesWithNothingNewAdvancesCursor() async throws {
        server.on("GET", "/users/me/history", .json(GmailFixtures.emptyHistory))
        let provider = TestSupport.makeProvider()

        let page = try await provider.changes(since: "8675309", limit: 100)

        XCTAssertTrue(page.upserts.isEmpty)
        XCTAssertTrue(page.deletedIDs.isEmpty)
        XCTAssertEqual(page.cursor, "8675330")
        XCTAssertFalse(page.hasMore)
        XCTAssertTrue(server.requests(to: "/batch/gmail/v1").isEmpty)
    }

    func testChangesStaleCursorThrowsResetRequired() async {
        server.on("GET", "/users/me/history", .json(GmailFixtures.notFoundError, status: 404))
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.changes(since: "1", limit: 100) }

        guard case .resetRequired? = error else { return XCTFail("expected resetRequired, got \(String(describing: error))") }
    }

    func testChangesWithOnlyEmptyPagesKeepsCursorAndReportsNoMore() async throws {
        server.on("GET", "/users/me/history", .json("{\"nextPageToken\":\"again\",\"historyId\":\"8675340\"}"))
        let provider = TestSupport.makeProvider()

        let page = try await provider.changes(since: "8675309", limit: 100)

        XCTAssertTrue(page.upserts.isEmpty)
        XCTAssertTrue(page.deletedIDs.isEmpty)
        XCTAssertFalse(page.hasMore, "an endless run of empty pages must not make the engine loop")
        XCTAssertEqual(page.cursor, "8675309")
        XCTAssertEqual(server.requests(to: "/users/me/history").count, GmailProvider.maxHistoryPagesPerCall)
    }

    // MARK: Metadata, body, attachment

    func testMetadataOmitsUnknownIDs() async throws {
        TestSupport.stubBatch(messages: ["m1": GmailFixtures.metadataM1])
        let provider = TestSupport.makeProvider()

        let messages = try await provider.metadata(for: ["gone", "m1"])

        XCTAssertEqual(messages.map(\.id.providerID), ["m1"])
    }

    func testMetadataSplitsBatchesOfFifty() async throws {
        let ids = (0..<120).map { "id\($0)" }
        TestSupport.stubBatch(messages: [:])
        let provider = TestSupport.makeProvider()

        let messages = try await provider.metadata(for: ids)

        XCTAssertTrue(messages.isEmpty)
        let batches = server.requests(to: "/batch/gmail/v1")
        XCTAssertEqual(batches.map { TestSupport.batchRequestIDs(in: $0.bodyText).count }, [50, 50, 20])
    }

    func testBodyFetchesFullFormatAndWalksMIMETree() async throws {
        server.on("GET", "/users/me/messages/m1", .json(GmailFixtures.fullMessage))
        let provider = TestSupport.makeProvider()

        let body = try await provider.body(for: "m1")

        XCTAssertEqual(body.html, GmailFixtures.html)
        XCTAssertEqual(body.text, GmailFixtures.plainText)
        XCTAssertEqual(body.attachments.map(\.id), ["ATT_LOGO", "ATT_PDF"])
        XCTAssertEqual(server.requests(to: "/users/me/messages/m1").first?.query["format"], ["full"])
    }

    func testAttachmentDecodesBase64URL() async throws {
        server.on("GET", "/users/me/messages/m1/attachments/ATT_PDF", .json(GmailFixtures.attachment))
        let provider = TestSupport.makeProvider()

        let data = try await provider.attachment(messageID: "m1", attachmentID: "ATT_PDF")

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "%PDF-")
    }

    func testBodyFetchesTextPartsGmailExternalized() async throws {
        server.on("GET", "/users/me/messages/m7", .json(GmailFixtures.externalizedHTMLMessage))
        server.on("GET", "/users/me/messages/m7/attachments/ATT_HTML", .json(GmailFixtures.externalizedHTMLAttachment))
        let provider = TestSupport.makeProvider()

        let body = try await provider.body(for: "m7")

        XCTAssertEqual(body.html, GmailFixtures.bigHTML)
        XCTAssertEqual(body.text, GmailFixtures.plainText)
        XCTAssertTrue(body.attachments.isEmpty, "an externalized body is not an attachment")
        XCTAssertEqual(server.requests(to: "/users/me/messages/m7/attachments/ATT_HTML").count, 1)
    }

    // MARK: Apply

    func testApplySendsBatchModifyWithLabelEdits() async throws {
        server.on("POST", "/users/me/messages/batchModify", .empty())
        let provider = TestSupport.makeProvider()

        try await provider.apply(.archive, to: ["m1", "m2"])
        try await provider.apply(.setRead(false), to: ["m1"])
        try await provider.apply(.moveToInbox, to: ["m3"])

        let calls = server.requests(to: "/users/me/messages/batchModify")
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].header("Content-Type"), "application/json; charset=UTF-8")
        XCTAssertEqual(calls[0].jsonBody["ids"] as? [String], ["m1", "m2"])
        XCTAssertNil(calls[0].jsonBody["addLabelIds"])
        XCTAssertEqual(calls[0].jsonBody["removeLabelIds"] as? [String], ["INBOX"])
        XCTAssertEqual(calls[1].jsonBody["addLabelIds"] as? [String], ["UNREAD"])
        XCTAssertNil(calls[1].jsonBody["removeLabelIds"])
        XCTAssertEqual(calls[2].jsonBody["addLabelIds"] as? [String], ["INBOX"])
        XCTAssertEqual(calls[2].jsonBody["removeLabelIds"] as? [String], ["TRASH", "SPAM"])
    }

    func testApplyChunksIDsByOneThousand() async throws {
        server.on("POST", "/users/me/messages/batchModify", .empty())
        let provider = TestSupport.makeProvider()
        let ids = (0..<2500).map { "id\($0)" }

        try await provider.apply(.trash, to: ids)

        let calls = server.requests(to: "/users/me/messages/batchModify")
        XCTAssertEqual(calls.map { ($0.jsonBody["ids"] as? [String])?.count }, [1000, 1000, 500])
        XCTAssertEqual(calls[2].jsonBody["addLabelIds"] as? [String], ["TRASH"])
        XCTAssertEqual(calls[2].jsonBody["removeLabelIds"] as? [String], ["INBOX"])
    }

    func testApplyWithNoTargetsMakesNoRequest() async throws {
        let provider = TestSupport.makeProvider()
        try await provider.apply(.archive, to: [])
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: Send

    func testSendBuildsRawMIMEAndThreadsReplies() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        server.on("GET", "/users/me/messages/m1", .json(GmailFixtures.metadataM1))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))
        let provider = TestSupport.makeProvider()
        let outgoing = OutgoingMessage(
            accountID: TestSupport.accountID,
            to: [EmailAddress(name: "Charles Babbage", address: "charles@example.com")],
            subject: "Re: Analytical Engine",
            html: "<p>Agreed.</p>",
            text: "Agreed.",
            inReplyTo: MessageID(accountID: TestSupport.accountID, providerID: "m1"),
            inReplyToInternetMessageID: "<m1@example.com>",
            references: ["<root@example.com>", "<m0@example.com>"]
        )

        let receipt = try await provider.send(outgoing)

        XCTAssertEqual(receipt.providerMessageID, "sent-1")
        XCTAssertEqual(receipt.providerConversationID, "t1")
        let send = try XCTUnwrap(server.requests(to: "/users/me/messages/send").first)
        XCTAssertEqual(send.jsonBody["threadId"] as? String, "t1")
        let raw = try XCTUnwrap(send.jsonBody["raw"] as? String)
        XCTAssertFalse(raw.contains("+") || raw.contains("/") || raw.contains("="), "raw must be base64url without padding")
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(raw)), as: UTF8.self)
        XCTAssertTrue(mime.contains("From: ada@example.com\r\n"))
        XCTAssertTrue(mime.contains("To: Charles Babbage <charles@example.com>\r\n"))
        XCTAssertTrue(mime.contains("In-Reply-To: <m1@example.com>\r\n"))
        XCTAssertTrue(mime.contains("References: <root@example.com> <m0@example.com> <m1@example.com>\r\n"))
        XCTAssertEqual(server.requests(to: "/users/me/messages/m1").first?.query["format"], ["metadata"])
    }

    func testSendWithoutReplyOmitsThreadID() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))
        let provider = TestSupport.makeProvider()
        let outgoing = OutgoingMessage(accountID: TestSupport.accountID, to: [EmailAddress(address: "x@example.com")], subject: "Hi", html: "<p>Hi</p>", text: "Hi")

        _ = try await provider.send(outgoing)

        let send = try XCTUnwrap(server.requests(to: "/users/me/messages/send").first)
        XCTAssertNil(send.jsonBody["threadId"])
        XCTAssertNotNil(send.jsonBody["raw"])
    }

    func testSendStillSucceedsWhenRepliedMessageIsGone() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        server.on("GET", "/users/me/messages/gone", .json(GmailFixtures.notFoundError, status: 404))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))
        let provider = TestSupport.makeProvider()
        let outgoing = OutgoingMessage(
            accountID: TestSupport.accountID, to: [EmailAddress(address: "x@example.com")], subject: "Re", html: "<p>Re</p>", text: "Re",
            inReplyTo: MessageID(accountID: TestSupport.accountID, providerID: "gone")
        )

        let receipt = try await provider.send(outgoing)

        XCTAssertEqual(receipt.providerMessageID, "sent-1")
        XCTAssertNil(server.requests(to: "/users/me/messages/send").first?.jsonBody["threadId"])
    }

    func testSendDerivesThreadingHeadersFromTheRepliedMessage() async throws {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.profile))
        server.on("GET", "/users/me/messages/m1", .json(GmailFixtures.metadataM1))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))
        let provider = TestSupport.makeProvider()
        let outgoing = OutgoingMessage(
            accountID: TestSupport.accountID, to: [EmailAddress(address: "x@example.com")], subject: "Re", html: "<p>Re</p>", text: "Re",
            inReplyTo: MessageID(accountID: TestSupport.accountID, providerID: "m1")
        )

        _ = try await provider.send(outgoing)

        let send = try XCTUnwrap(server.requests(to: "/users/me/messages/send").first)
        XCTAssertEqual(send.jsonBody["threadId"] as? String, "t1")
        let raw = try XCTUnwrap(send.jsonBody["raw"] as? String)
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(raw)), as: UTF8.self)
        XCTAssertTrue(mime.contains("In-Reply-To: <m1@example.com>\r\n"))
        XCTAssertTrue(mime.contains("References: <root@example.com> <m0@example.com> <m1@example.com>\r\n"))
    }

    // MARK: Search

    func testSearchPassesQueryAndReturnsIDsInOrder() async throws {
        server.on("GET", "/users/me/messages", .json(GmailFixtures.searchList))
        let provider = TestSupport.makeProvider()

        let ids = try await provider.search("from:ada engine", limit: 25)

        XCTAssertEqual(ids, ["s1", "s2", "s3"])
        let request = try XCTUnwrap(server.requests(to: "/users/me/messages").first)
        XCTAssertEqual(request.query["q"], ["from:ada engine"])
        XCTAssertEqual(request.query["maxResults"], ["25"])
    }

    func testSearchWithBlankTextSkipsTheNetwork() async throws {
        let provider = TestSupport.makeProvider()
        let ids = try await provider.search("   ", limit: 25)
        XCTAssertTrue(ids.isEmpty)
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: Error mapping

    func testUnauthorizedInvalidatesTokenAndRetriesOnce() async throws {
        server.sequence("GET", "/users/me/profile", [
            .json(GmailFixtures.unauthorizedError, status: 401),
            .json(GmailFixtures.profile),
        ])
        let tokens = FakeTokenProvider()
        let provider = TestSupport.makeProvider(tokens: tokens)

        let profile = try await provider.profile()

        XCTAssertEqual(profile.email, "ada@example.com")
        XCTAssertEqual(tokens.invalidations, 1)
        let attempts = server.requests(to: "/users/me/profile")
        XCTAssertEqual(attempts.map { $0.header("Authorization") }, ["Bearer token-1", "Bearer token-2"])
    }

    func testRepeatedUnauthorizedThrowsAfterOneRetry() async {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.unauthorizedError, status: 401))
        let tokens = FakeTokenProvider()
        let provider = TestSupport.makeProvider(tokens: tokens)

        let error = await TestSupport.providerError { _ = try await provider.profile() }

        guard case .unauthorized? = error else { return XCTFail("expected unauthorized, got \(String(describing: error))") }
        XCTAssertEqual(server.requests(to: "/users/me/profile").count, 2)
        XCTAssertEqual(tokens.invalidations, 2)
    }

    func testTooManyRequestsMapsToThrottledWithRetryAfter() async {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.tooManyRequestsError, status: 429, headers: ["Retry-After": "7"]))
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.profile() }

        guard case .throttled(let retryAfter)? = error else { return XCTFail("expected throttled, got \(String(describing: error))") }
        XCTAssertEqual(retryAfter, 7)
        XCTAssertEqual(server.requests.count, 1, "throttling must not be retried by the provider")
    }

    func testUserRateLimitForbiddenMapsToThrottled() async {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.userRateLimitError, status: 403))
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.profile() }

        guard case .throttled(let retryAfter)? = error else { return XCTFail("expected throttled, got \(String(describing: error))") }
        XCTAssertNil(retryAfter)
    }

    func testOtherForbiddenMapsToServerError() async {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.forbiddenError, status: 403))
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.profile() }

        guard case .server(let status, let message)? = error else { return XCTFail("expected server, got \(String(describing: error))") }
        XCTAssertEqual(status, 403)
        XCTAssertEqual(message, "Insufficient Permission")
    }

    func testServerErrorCarriesStatus() async {
        server.on("GET", "/users/me/profile", .json(GmailFixtures.serverError, status: 503))
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.profile() }

        guard case .server(let status, _)? = error else { return XCTFail("expected server, got \(String(describing: error))") }
        XCTAssertEqual(status, 503)
    }

    func testTransportFailureMapsToNetwork() async {
        server.on("GET", "/users/me/profile", .failure(URLError(.notConnectedToInternet)))
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.profile() }

        guard case .network? = error else { return XCTFail("expected network, got \(String(describing: error))") }
    }

    func testMalformedJSONMapsToDecoding() async {
        server.on("GET", "/users/me/profile", .json("{\"emailAddress\": 42}"))
        let provider = TestSupport.makeProvider()

        let error = await TestSupport.providerError { _ = try await provider.profile() }

        guard case .decoding? = error else { return XCTFail("expected decoding, got \(String(describing: error))") }
    }

    func testRetryAfterAcceptsSecondsAndHTTPDates() {
        XCTAssertEqual(GmailHTTPClient.parseRetryAfter("12"), 12)
        XCTAssertEqual(GmailHTTPClient.parseRetryAfter(" 3 "), 3)
        XCTAssertNil(GmailHTTPClient.parseRetryAfter(nil))
        XCTAssertNil(GmailHTTPClient.parseRetryAfter("soon"))
        let future = Date().addingTimeInterval(90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let parsed = GmailHTTPClient.parseRetryAfter(formatter.string(from: future)) ?? -1
        XCTAssertGreaterThan(parsed, 80)
        XCTAssertLessThanOrEqual(parsed, 90)
        XCTAssertEqual(GmailHTTPClient.parseRetryAfter("Thu, 01 Jan 2015 00:00:00 GMT"), 0, "dates in the past mean retry now")
    }
}
