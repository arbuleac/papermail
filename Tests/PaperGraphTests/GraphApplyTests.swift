import Foundation
import PaperCore
import XCTest
@testable import PaperGraph

final class GraphApplyTests: GraphTestCase {
    private struct Expectation {
        var change: MetadataChange
        var method: String
        var suffix: String
        var body: NSDictionary
    }

    func testApplyBatchesTwentyPerCallForEveryChange() async throws {
        let ids = (1...45).map { "id-\($0)" }
        let expectations = [
            Expectation(change: .setRead(true), method: "PATCH", suffix: "", body: ["isRead": true]),
            Expectation(change: .setRead(false), method: "PATCH", suffix: "", body: ["isRead": false]),
            Expectation(change: .setStarred(true), method: "PATCH", suffix: "", body: ["flag": ["flagStatus": "flagged"]]),
            Expectation(change: .setStarred(false), method: "PATCH", suffix: "", body: ["flag": ["flagStatus": "notFlagged"]]),
            Expectation(change: .archive, method: "POST", suffix: "/move", body: ["destinationId": "archive"]),
            Expectation(change: .moveToInbox, method: "POST", suffix: "/move", body: ["destinationId": "inbox"]),
            Expectation(change: .restoreFromTrash, method: "POST", suffix: "/move", body: ["destinationId": "inbox"]),
            Expectation(change: .trash, method: "POST", suffix: "/move", body: ["destinationId": "deleteditems"]),
            Expectation(change: .markSpam, method: "POST", suffix: "/move", body: ["destinationId": "junkemail"]),
            Expectation(change: .markNotSpam, method: "POST", suffix: "/move", body: ["destinationId": "inbox"]),
        ]
        let provider = makeProvider()

        for expectation in expectations {
            StubURLProtocol.reset()
            route { request in self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 200) } }

            try await provider.apply(expectation.change, to: ids)

            let calls = requests
            XCTAssertEqual(calls.count, 3, "\(expectation.change)")
            XCTAssertTrue(calls.allSatisfy { $0.method == "POST" && $0.path == "/v1.0/$batch" }, "\(expectation.change)")
            XCTAssertTrue(calls.allSatisfy { $0.header("Content-Type") == "application/json" })
            let perCall = calls.map { ($0.json()["requests"] as? [[String: Any]]) ?? [] }
            XCTAssertEqual(perCall.map(\.count), [20, 20, 5], "\(expectation.change)")
            XCTAssertEqual(perCall[0].map { $0["id"] as? String }, (1...20).map { String($0) })
            XCTAssertEqual(perCall[2].map { $0["id"] as? String }, (1...5).map { String($0) })

            let inner = perCall.flatMap { $0 }
            XCTAssertEqual(inner.map { $0["url"] as? String }, ids.map { "/me/messages/\($0)\(expectation.suffix)" }, "\(expectation.change)")
            XCTAssertTrue(inner.allSatisfy { $0["method"] as? String == expectation.method }, "\(expectation.change)")
            for item in inner {
                XCTAssertEqual(item["body"] as? NSDictionary, expectation.body, "\(expectation.change)")
                let headers = item["headers"] as? [String: String]
                XCTAssertEqual(headers?["Content-Type"], "application/json")
                XCTAssertEqual(headers?["Prefer"], "IdType=\"ImmutableId\"")
            }
        }
    }

    /// Mark as spam moves to Junk Email by its well-known name (roadmap Q2.3). Immutable ids keep the message's id, so the
    /// next poll finds it in Junk Email's delta as the inbox's delta reports it removed, and it comes back as spam, which
    /// is what the store applied: a move, not a deletion.
    func testMarkSpamMovesToJunkEmailAndTheNextPollReportsItAsSpam() async throws {
        route { request in
            if request.path == "/v1.0/$batch" {
                return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 201, body: #"{"id":"m-x"}"#) }
            }
            guard request.method == "GET" else { return nil }
            switch request.path {
            case "/v1.0/me/mailFolders/F-INBOX/messages/delta":
                return .json(Fixtures.list([Fixtures.removed("m-x")],
                                           deltaLink: "https://graph.microsoft.com/v1.0/me/mailFolders/F-INBOX/messages/delta?$deltatoken=i2"))
            case "/v1.0/me/mailFolders/F-JUNK/messages/delta":
                return .json(Fixtures.list([Fixtures.message(id: "m-x", folder: "F-JUNK")],
                                           deltaLink: "https://graph.microsoft.com/v1.0/me/mailFolders/F-JUNK/messages/delta?$deltatoken=j2"))
            default:
                return nil
            }
        }
        let provider = makeProvider()
        try await provider.apply(.markSpam, to: ["m-x"])
        let moves = requests(to: "/v1.0/$batch").flatMap { ($0.json()["requests"] as? [[String: Any]]) ?? [] }
        XCTAssertEqual(moves.map { $0["url"] as? String }, ["/me/messages/m-x/move"])
        XCTAssertEqual(moves.first?["body"] as? NSDictionary, ["destinationId": "junkemail"])

        let page = try await provider.changes(since: try cursor(folders: ["F-INBOX": nil, "F-JUNK": nil]), limit: 50)
        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-x"])
        XCTAssertEqual(page.upserts.first?.roles, [.spam])
        XCTAssertTrue(page.deletedIDs.isEmpty)
    }

    func testApplyTreatsMissingMessageAsDone() async throws {
        route { request in
            self.wellKnownFolderReply(request) ?? self.batchReply(request) { id, url in
                url.contains("gone")
                    ? Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError)
                    : Fixtures.BatchItem(id: id, status: 201, body: #"{"id":"kept"}"#)
            }
        }
        try await makeProvider().apply(.archive, to: ["gone", "kept"])
        XCTAssertEqual(requests(to: "/v1.0/$batch").count, 1)
    }

    func testArchiveIntoAMailboxWithoutArchiveFolderIsNotTreatedAsDone() async throws {
        // Outlook creates Archive lazily. A move to a folder that does not exist answers 404 too, and must not
        // be mistaken for "the message is gone": the message would stay in the server inbox for good.
        route { request in
            self.wellKnownFolderReply(request, missing: ["archive"]) ?? self.batchReply(request) { id, _ in
                Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError)
            }
        }
        await expectProviderError({ try await self.makeProvider().apply(.archive, to: ["a"]) }) { $0.serverStatus == 404 }
    }

    func testApplySurfacesPerItemThrottleWithRetryAfter() async throws {
        route { request in
            self.batchReply(request) { id, url in
                url.contains("busy")
                    ? Fixtures.BatchItem(id: id, status: 429, headers: ["Retry-After": "3"], body: #"{"error":{"code":"ApplicationThrottled","message":"slow down"}}"#)
                    : Fixtures.BatchItem(id: id, status: 200)
            }
        }
        let partial = try await expectPartialApply { try await self.makeProvider().apply(.setRead(true), to: ["ok", "busy"]) }
        XCTAssertEqual(partial.unapplied, ["busy"], "the part that went through is not sent again")
        XCTAssertEqual(partial.error.retryAfter, 3)
    }

    func testApplySurfacesPerItemServerError() async throws {
        route { request in
            self.batchReply(request) { id, _ in
                Fixtures.BatchItem(id: id, status: 500, body: #"{"error":{"code":"InternalServerError","message":"boom"}}"#)
            }
        }
        await expectProviderError({ try await self.makeProvider().apply(.trash, to: ["a"]) }) { $0.serverStatus == 500 }
    }

    /// One message Graph refuses (403 ErrorAccessDenied, ErrorMoveCopyFailed) stopped the apply at its part: the call's
    /// later batches never went out, and every retry failed at the same place, so most of an archive of thirty
    /// conversations never reached the server. Every batch goes now, and the call says which messages it did not change.
    func testApplyGoesOnPastAMessageGraphRefuses() async throws {
        route { request in
            self.batchReply(request) { id, url in
                url.contains("/id-3/")
                    ? Fixtures.BatchItem(id: id, status: 403, body: #"{"error":{"code":"ErrorAccessDenied","message":"Access is denied."}}"#)
                    : Fixtures.BatchItem(id: id, status: 200)
            }
        }
        let ids = (1...45).map { "id-\($0)" }

        let partial = try await expectPartialApply { try await self.makeProvider().apply(.archive, to: ids) }

        XCTAssertEqual(partial.unapplied, ["id-3"])
        XCTAssertEqual(partial.error.serverStatus, 403)
        XCTAssertEqual(requests(to: "/v1.0/$batch").count, 3, "every batch went out")
        XCTAssertEqual(applyWaits.waits, [], "a refusal is not asked again within the call")
    }

    /// Through Exchange's November 2026 outage a part answered 502, 503 or 504 now and then, and the whole apply failed
    /// with it: an action on twenty messages almost never got through, and every retry sent the parts that had landed
    /// again. The parts the service failed are sent again on their own after a second, then two.
    func testApplySendsAgainOnlyThePartsTheServiceFailed() async throws {
        var round = 0
        route { request in
            guard request.method == "POST", request.path == "/v1.0/$batch" else { return nil }
            defer { round += 1 }
            return self.batchReply(request) { id, url in
                if round < 2, url.hasSuffix("/id-2") { return Fixtures.BatchItem(id: id, status: 503) }
                if round < 2, url.hasSuffix("/id-22") { return Fixtures.BatchItem(id: id, status: 502) }
                return Fixtures.BatchItem(id: id, status: 200)
            }
        }
        let ids = (1...25).map { "id-\($0)" }

        try await makeProvider().apply(.setRead(true), to: ids)

        let sent = requests(to: "/v1.0/$batch").map { ($0.json()["requests"] as? [[String: Any]])?.map { $0["url"] as? String } ?? [] }
        XCTAssertEqual(sent.map(\.count), [20, 5, 2], "only the two failed parts go out again")
        XCTAssertEqual(sent.last, ["/me/messages/id-2", "/me/messages/id-22"])
        XCTAssertEqual(applyWaits.waits, [1])
    }

    /// Parts the service keeps failing are tried twice more, then left to the outbox, which knows they alone are owed.
    func testApplyLeavesPartsTheServiceKeepsFailingToTheOutbox() async throws {
        route { request in
            self.batchReply(request) { id, url in
                url.hasSuffix("/id-2")
                    ? Fixtures.BatchItem(id: id, status: 504)
                    : Fixtures.BatchItem(id: id, status: 200)
            }
        }

        let partial = try await expectPartialApply { try await self.makeProvider().apply(.setStarred(true), to: ["id-1", "id-2", "id-3"]) }

        XCTAssertEqual(partial.unapplied, ["id-2"])
        XCTAssertTrue(partial.error.isNetwork)
        XCTAssertEqual(requests(to: "/v1.0/$batch").count, 3)
        XCTAssertEqual(applyWaits.waits, [1, 2])
    }

    /// A throttle or a refused token in a part is the mailbox's: the batches after it are not sent, and the call says
    /// they are owed with the part.
    func testAThrottledPartStopsTheBatchesAfterIt() async throws {
        route { request in
            self.batchReply(request) { id, url in
                url.contains("/id-5/")
                    ? Fixtures.BatchItem(id: id, status: 429, headers: ["Retry-After": "8"])
                    : Fixtures.BatchItem(id: id, status: 200)
            }
        }
        let ids = (1...45).map { "id-\($0)" }

        let partial = try await expectPartialApply { try await self.makeProvider().apply(.archive, to: ids) }

        XCTAssertEqual(partial.unapplied, ["id-5"] + (21...45).map { "id-\($0)" })
        XCTAssertEqual(partial.error.retryAfter, 8)
        XCTAssertEqual(requests(to: "/v1.0/$batch").count, 1)
    }

    private func expectPartialApply(_ body: () async throws -> Void, file: StaticString = #filePath,
                                    line: UInt = #line) async throws -> PartialApplyError {
        do {
            try await body()
        } catch let partial as PartialApplyError {
            return partial
        } catch {
            XCTFail("expected a partial apply, got \(error)", file: file, line: line)
            throw error
        }
        XCTFail("expected a partial apply", file: file, line: line)
        throw PartialApplyError(unapplied: [], error: .cancelled)
    }

    func testApplyWithNoTargetsMakesNoRequest() async throws {
        try await makeProvider().apply(.trash, to: [])
        XCTAssertTrue(requests.isEmpty)
    }

    func testApplyDeduplicatesTargets() async throws {
        route { request in self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 200) } }
        try await makeProvider().apply(.setStarred(true), to: ["a", "a", "b"])
        XCTAssertEqual(innerBatchRequests().map { $0["url"] as? String }, ["/me/messages/a", "/me/messages/b"])
    }
}
