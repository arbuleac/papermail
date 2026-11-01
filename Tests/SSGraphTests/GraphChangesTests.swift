import Foundation
import SSCore
import XCTest
@testable import SSGraph

final class GraphChangesTests: GraphTestCase {
    private let inboxDelta = "/v1.0/me/mailFolders/F-INBOX/messages/delta"
    private let sentDelta = "/v1.0/me/mailFolders/F-SENT/messages/delta"
    private let inboxNext = "https://graph.microsoft.com/v1.0/me/mailFolders/F-INBOX/messages/delta?$skiptoken=inbox-2"
    private let inboxLink = "https://graph.microsoft.com/v1.0/me/mailFolders/F-INBOX/messages/delta?$deltatoken=inbox-d1"
    private let inboxLink2 = "https://graph.microsoft.com/v1.0/me/mailFolders/F-INBOX/messages/delta?$deltatoken=inbox-d2"
    private let sentLink = "https://graph.microsoft.com/v1.0/me/mailFolders/F-SENT/messages/delta?$deltatoken=sent-d1"
    private let sentLink2 = "https://graph.microsoft.com/v1.0/me/mailFolders/F-SENT/messages/delta?$deltatoken=sent-d2"

    /// Inbox: seed page (m1, nextLink) -> skip page (m2, deltaLink d1) -> delta d1 ([], deltaLink d2).
    /// Sent: seed page (m3, deltaLink s1) -> delta s1 ([], deltaLink s2).
    private func routeTwoFolderDeltas() {
        route { request in
            guard request.method == "GET" else { return nil }
            switch request.path {
            case self.inboxDelta:
                if request.query["$skiptoken"] == "inbox-2" {
                    return .json(Fixtures.list([Fixtures.message(id: "m2", folder: "F-INBOX")], deltaLink: self.inboxLink))
                }
                if request.query["$deltatoken"] != nil {
                    return .json(Fixtures.list([], deltaLink: self.inboxLink2))
                }
                return .json(Fixtures.list([Fixtures.message(id: "m1", folder: "F-INBOX")], nextLink: self.inboxNext))
            case self.sentDelta:
                if request.query["$deltatoken"] != nil {
                    return .json(Fixtures.list([], deltaLink: self.sentLink2))
                }
                return .json(Fixtures.list([Fixtures.message(id: "m3", folder: "F-SENT")], deltaLink: self.sentLink))
            default:
                return nil
            }
        }
    }

    func testSeedsDeltasPersistsNextLinkWhenLimitIsReachedThenStoresDeltaLink() async throws {
        routeTwoFolderDeltas()
        let provider = makeProvider()

        // Two items fill a limit of two after the first pass, so the inbox stays on its nextLink.
        let first = try await provider.changes(since: try cursor(folders: ["F-INBOX": nil, "F-SENT": nil]), limit: 2)

        let seeds = requests
        XCTAssertEqual(seeds.map(\.path), [inboxDelta, sentDelta])
        for seed in seeds {
            XCTAssertEqual(seed.query["$filter"], "receivedDateTime ge \(nowString)")
            XCTAssertEqual(seed.query["$select"], GraphProvider.metadataSelect)
            let prefer = try XCTUnwrap(seed.header("Prefer"))
            XCTAssertTrue(prefer.contains("odata.maxpagesize=2"), prefer)
            XCTAssertTrue(prefer.contains("IdType=\"ImmutableId\""), prefer)
        }
        XCTAssertEqual(first.upserts.map(\.id.providerID), ["m1", "m3"])
        XCTAssertEqual(first.upserts.map(\.roles), [[.inbox], [.sent]])
        XCTAssertTrue(first.deletedIDs.isEmpty)
        XCTAssertTrue(first.hasMore)
        let afterFirst = try GraphCursor.decode(first.cursor)
        XCTAssertEqual(afterFirst.nextLinks["F-INBOX"], inboxNext)
        XCTAssertNil(afterFirst.deltaLink(for: "F-INBOX"))
        XCTAssertEqual(afterFirst.deltaLink(for: "F-SENT"), sentLink)

        StubURLProtocol.clearRequests()
        let second = try await provider.changes(since: first.cursor, limit: 2)

        XCTAssertEqual(requests.map(\.url.absoluteString), [inboxNext, sentLink])
        XCTAssertEqual(second.upserts.map(\.id.providerID), ["m2"])
        XCTAssertFalse(second.hasMore)
        let afterSecond = try GraphCursor.decode(second.cursor)
        XCTAssertTrue(afterSecond.nextLinks.isEmpty)
        XCTAssertEqual(afterSecond.deltaLink(for: "F-INBOX"), inboxLink)
        XCTAssertEqual(afterSecond.deltaLink(for: "F-SENT"), sentLink2)

        StubURLProtocol.clearRequests()
        let third = try await provider.changes(since: second.cursor, limit: 2)

        XCTAssertEqual(requests.map(\.url.absoluteString), [inboxLink, sentLink2])
        XCTAssertTrue(third.upserts.isEmpty)
        XCTAssertFalse(third.hasMore)
        XCTAssertEqual(try GraphCursor.decode(third.cursor).deltaLink(for: "F-INBOX"), inboxLink2)
    }

    func testFollowsNextLinkWithinOneCallWhileUnderLimit() async throws {
        routeTwoFolderDeltas()

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil, "F-SENT": nil]), limit: 25)

        XCTAssertEqual(requests.map(\.path), [inboxDelta, sentDelta, inboxDelta], "round-robin: every folder once, then the inbox continues")
        XCTAssertEqual(requests.last?.url.absoluteString, inboxNext)
        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m1", "m3", "m2"])
        XCTAssertFalse(page.hasMore)
        let cursor = try GraphCursor.decode(page.cursor)
        XCTAssertTrue(cursor.nextLinks.isEmpty)
        XCTAssertEqual(cursor.deltaLink(for: "F-INBOX"), inboxLink)
        XCTAssertEqual(cursor.deltaLink(for: "F-SENT"), sentLink)
    }

    func testSystemFoldersArePolledBeforeCustomOnes() async throws {
        route { request in
            guard request.method == "GET", request.path.hasSuffix("/messages/delta") else { return nil }
            return .json(Fixtures.list([], deltaLink: "https://graph.microsoft.com\(request.path)?$deltatoken=x"))
        }

        _ = try await makeProvider().changes(since: try cursor(folders: ["F-AAA": nil, "F-SENT": nil, "F-INBOX": nil, "F-ZZZ": nil]), limit: 10)

        XCTAssertEqual(requests.map(\.path), [
            inboxDelta,
            sentDelta,
            "/v1.0/me/mailFolders/F-AAA/messages/delta",
            "/v1.0/me/mailFolders/F-ZZZ/messages/delta",
        ])
    }

    func testRemovedItemsAreVerifiedBeforeBecomingDeletions() async throws {
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list([
                    Fixtures.removed("r-gone"),
                    Fixtures.removed("r-moved"),
                    Fixtures.message(id: "m-new", folder: "F-INBOX"),
                ], deltaLink: self.inboxLink))
            }
            return self.batchReply(request) { id, url in
                if url.contains("r-gone") {
                    return Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError)
                }
                return Fixtures.BatchItem(id: id, status: 200, body: Fixtures.message(id: "r-moved", folder: "F-ARCHIVE"))
            }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil]), limit: 50)

        XCTAssertEqual(page.deletedIDs, ["r-gone"])
        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-new", "r-moved"])
        XCTAssertEqual(page.upserts.last?.roles, [])
        XCTAssertEqual(page.upserts.last?.folderID, "F-ARCHIVE")
        XCTAssertFalse(page.hasMore)
        let inner = innerBatchRequests()
        XCTAssertEqual(inner.map { $0["method"] as? String }, ["GET", "GET"])
        XCTAssertEqual(inner.map { $0["url"] as? String }, [
            "/me/messages/r-gone?$select=\(GraphProvider.metadataSelect)",
            "/me/messages/r-moved?$select=\(GraphProvider.metadataSelect)",
        ])
    }

    func testRemovalAlreadyUpsertedByAnotherFolderNeedsNoLookup() async throws {
        route { request in
            guard request.method == "GET" else { return nil }
            switch request.path {
            case self.inboxDelta:
                return .json(Fixtures.list([Fixtures.removed("m-x")], deltaLink: self.inboxLink))
            case "/v1.0/me/mailFolders/F-ARCHIVE/messages/delta":
                return .json(Fixtures.list([Fixtures.message(id: "m-x", folder: "F-ARCHIVE")], deltaLink: "https://graph.microsoft.com/v1.0/me/mailFolders/F-ARCHIVE/messages/delta?$deltatoken=a1"))
            default:
                return nil
            }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil, "F-ARCHIVE": nil]), limit: 50)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-x"])
        XCTAssertTrue(page.deletedIDs.isEmpty)
        XCTAssertTrue(requests(to: "/v1.0/$batch").isEmpty)
    }

    func testGoneDeltaRequiresReset() async throws {
        route { request in
            request.path == self.inboxDelta ? .json(Fixtures.syncStateNotFoundError, status: 410) : nil
        }
        let stale = try cursor(folders: ["F-INBOX": inboxLink])
        await expectProviderError({ try await self.makeProvider().changes(since: stale, limit: 10) }) { $0.isResetRequired }
    }

    func testSyncStateNotFoundRequiresResetEvenAsBadRequest() async throws {
        route { request in
            request.path == self.inboxDelta ? .json(Fixtures.syncStateNotFoundError, status: 400) : nil
        }
        let stale = try cursor(folders: ["F-INBOX": inboxLink])
        await expectProviderError({ try await self.makeProvider().changes(since: stale, limit: 10) }) { $0.isResetRequired }
    }

    func testThrottledDeltaSurfacesRetryAfter() async throws {
        route { request in
            request.path == self.inboxDelta ? .status(429, headers: ["Retry-After": "12"]) : nil
        }
        let start = try cursor(folders: ["F-INBOX": nil])
        await expectProviderError({ try await self.makeProvider().changes(since: start, limit: 10) }) { $0.retryAfter == 12 }
    }

    func testDeletedFolderIsDroppedFromCursor() async throws {
        route { request in
            switch request.path {
            case "/v1.0/me/mailFolders/F-OLD/messages/delta": return .json(Fixtures.notFoundError, status: 404)
            case self.inboxDelta: return .json(Fixtures.list([], deltaLink: self.inboxLink))
            default: return nil
            }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil, "F-OLD": nil]), limit: 10)

        XCTAssertEqual(Set(try GraphCursor.decode(page.cursor).folders.keys), ["F-INBOX"])
        XCTAssertFalse(page.hasMore)
    }

    func testFolderListIsRefreshedAfterADay() async throws {
        let newLink = "https://graph.microsoft.com/v1.0/me/mailFolders/F-NEW/messages/delta?$deltatoken=new-1"
        route { request in
            if let reply = self.wellKnownFolderReply(request) { return reply }
            guard request.method == "GET" else { return nil }
            switch request.path {
            case "/v1.0/me/mailFolders":
                return .json(Fixtures.list([#"{"id":"F-INBOX","childFolderCount":0}"#, #"{"id":"F-NEW","childFolderCount":0}"#]))
            case self.inboxDelta:
                return .json(Fixtures.list([], deltaLink: self.inboxLink2))
            case "/v1.0/me/mailFolders/F-NEW/messages/delta":
                return .json(Fixtures.list([Fixtures.message(id: "m-n", folder: "F-NEW")], deltaLink: newLink))
            case let path where path.hasSuffix("/messages/delta"):
                return .json(Fixtures.list([], deltaLink: "https://graph.microsoft.com\(path)?$deltatoken=generic"))
            default:
                return nil
            }
        }
        let stale = try cursor(folders: ["F-INBOX": inboxLink, "F-GONE": "https://graph.microsoft.com/v1.0/me/mailFolders/F-GONE/messages/delta?$deltatoken=g"], resolvedAt: "2026-10-31T09:00:00Z")

        let page = try await makeProvider().changes(since: stale, limit: 10)

        let next = try GraphCursor.decode(page.cursor)
        XCTAssertEqual(next.foldersResolvedAt, nowString)
        XCTAssertEqual(Set(next.folders.keys), ["F-INBOX", "F-NEW", "F-SENT", "F-DRAFTS", "F-TRASH", "F-JUNK", "F-ARCHIVE"])
        XCTAssertEqual(next.deltaLink(for: "F-NEW"), newLink)
        XCTAssertEqual(next.deltaLink(for: "F-INBOX"), inboxLink2)
        XCTAssertEqual(next.wellKnown, Fixtures.folderIDs)
        XCTAssertEqual(requests(to: inboxDelta).first?.query["$deltatoken"], "inbox-d1", "a folder that survives keeps its delta link")
        XCTAssertEqual(requests(to: "/v1.0/me/mailFolders/F-NEW/messages/delta").first?.query["$filter"], "receivedDateTime ge \(nowString)")
        XCTAssertTrue(requests(to: "/v1.0/me/mailFolders/F-GONE/messages/delta").isEmpty)
        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-n"])
    }

    func testInvalidCursorRequiresReset() async {
        await expectProviderError({ try await self.makeProvider().changes(since: "garbage", limit: 10) }) { $0.isResetRequired }
        XCTAssertTrue(requests.isEmpty)
    }

    func testDeltaPageWithoutAnyLinkIsADecodingError() async throws {
        route { request in request.path == self.inboxDelta ? .json(Fixtures.list([])) : nil }
        let start = try cursor(folders: ["F-INBOX": nil])
        await expectProviderError({ try await self.makeProvider().changes(since: start, limit: 10) }) { $0.isDecoding }
    }
}
