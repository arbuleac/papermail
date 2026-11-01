import Foundation
import SSCore
import XCTest
@testable import SSGraph

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

    func testApplyTreatsMissingMessageAsDone() async throws {
        route { request in
            self.batchReply(request) { id, url in
                url.contains("gone")
                    ? Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError)
                    : Fixtures.BatchItem(id: id, status: 201, body: #"{"id":"kept"}"#)
            }
        }
        try await makeProvider().apply(.archive, to: ["gone", "kept"])
        XCTAssertEqual(requests.count, 1)
    }

    func testApplySurfacesPerItemThrottleWithRetryAfter() async throws {
        route { request in
            self.batchReply(request) { id, url in
                url.contains("busy")
                    ? Fixtures.BatchItem(id: id, status: 429, headers: ["Retry-After": "3"], body: #"{"error":{"code":"ApplicationThrottled","message":"slow down"}}"#)
                    : Fixtures.BatchItem(id: id, status: 200)
            }
        }
        await expectProviderError({ try await self.makeProvider().apply(.setRead(true), to: ["ok", "busy"]) }) { $0.retryAfter == 3 }
    }

    func testApplySurfacesPerItemServerError() async throws {
        route { request in
            self.batchReply(request) { id, _ in
                Fixtures.BatchItem(id: id, status: 500, body: #"{"error":{"code":"InternalServerError","message":"boom"}}"#)
            }
        }
        await expectProviderError({ try await self.makeProvider().apply(.trash, to: ["a"]) }) { $0.serverStatus == 500 }
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
