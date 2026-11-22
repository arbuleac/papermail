import Foundation
import PaperCore
import XCTest
@testable import PaperGraph

final class GraphBootstrapTests: GraphTestCase {
    private let nextLink = "https://graph.microsoft.com/v1.0/me/messages?$skip=50&$orderby=receivedDateTime%20desc"

    func testBootstrapResolvesFoldersListsNewestFirstAndDropsTrashAndJunk() async throws {
        route { request in
            if let reply = self.wellKnownFolderReply(request) ?? self.folderListReply(request) { return reply }
            guard request.method == "GET", request.path == "/v1.0/me/messages" else { return nil }
            return .json(Fixtures.list([
                Fixtures.message(id: "m-inbox", folder: "F-INBOX"),
                Fixtures.message(id: "m-trash", folder: "F-TRASH"),
                Fixtures.message(id: "m-sent", folder: "F-SENT"),
                Fixtures.message(id: "m-junk", folder: "F-JUNK"),
                Fixtures.message(id: "m-drafts", folder: "F-DRAFTS", isDraft: true),
                Fixtures.message(id: "m-archive", folder: "F-ARCHIVE"),
                Fixtures.message(id: "m-projects", folder: "F-PROJECTS-A"),
            ], nextLink: self.nextLink))
        }

        let page = try await makeProvider().bootstrap(page: nil, limit: 50)

        let folderLookups = requests.filter { $0.path.hasPrefix("/v1.0/me/mailFolders/") && !$0.path.contains("childFolders") }
        XCTAssertEqual(folderLookups.map(\.path), GraphWellKnownFolders.names.map { "/v1.0/me/mailFolders/\($0)" })
        XCTAssertTrue(folderLookups.allSatisfy { $0.query["$select"] == "id" })

        let listing = try XCTUnwrap(requests(to: "/v1.0/me/mailFolders").first)
        XCTAssertEqual(listing.query["$top"], "200")
        XCTAssertEqual(requests(to: "/v1.0/me/mailFolders/F-PROJECTS/childFolders").count, 1)

        let list = try XCTUnwrap(requests(to: "/v1.0/me/messages").first)
        XCTAssertEqual(list.query["$top"], "50")
        XCTAssertEqual(list.query["$orderby"], "receivedDateTime desc")
        XCTAssertEqual(list.query["$select"], GraphProvider.metadataSelect)
        XCTAssertNil(list.query["$filter"])
        let folderIndex = try XCTUnwrap(requests.firstIndex { $0.path == "/v1.0/me/mailFolders" })
        let listIndex = try XCTUnwrap(requests.firstIndex { $0.path == "/v1.0/me/messages" })
        XCTAssertLessThan(folderIndex, listIndex, "the cursor must be captured before enumeration starts")

        XCTAssertEqual(page.messages.map(\.id.providerID), ["m-inbox", "m-sent", "m-drafts", "m-archive", "m-projects"])
        let roles = Dictionary(uniqueKeysWithValues: page.messages.map { ($0.id.providerID, $0.roles) })
        XCTAssertEqual(roles["m-inbox"], [.inbox])
        XCTAssertEqual(roles["m-sent"], [.sent])
        XCTAssertEqual(roles["m-drafts"], [.drafts])
        XCTAssertEqual(roles["m-archive"], [])
        XCTAssertEqual(roles["m-projects"], [])
        XCTAssertEqual(page.nextPage, nextLink)

        let cursorString = try XCTUnwrap(page.changeCursor)
        let cursor = try GraphCursor.decode(cursorString)
        XCTAssertEqual(cursor.since, nowString)
        XCTAssertEqual(cursor.foldersResolvedAt, nowString)
        XCTAssertEqual(cursor.wellKnown, Fixtures.folderIDs)
        XCTAssertEqual(Set(cursor.folders.keys), Fixtures.allFolderIDs)
        XCTAssertTrue(cursor.folders.values.allSatisfy { $0 == nil })
        XCTAssertTrue(cursor.nextLinks.isEmpty)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cursorString.utf8)) as? [String: Any])
        let folders = try XCTUnwrap(json["folders"] as? [String: Any])
        XCTAssertTrue(folders["F-INBOX"] is NSNull)
        XCTAssertEqual((json["wellKnown"] as? [String: String])?["inbox"], "F-INBOX")
        XCTAssertEqual(json["since"] as? String, nowString)
    }

    func testBootstrapFollowsNextPageWithoutIssuingACursor() async throws {
        route { request in
            if let reply = self.wellKnownFolderReply(request) { return reply }
            guard request.method == "GET", request.path == "/v1.0/me/messages", request.query["$skip"] == "50" else { return nil }
            return .json(Fixtures.list([
                Fixtures.message(id: "m-2", folder: "F-INBOX"),
                Fixtures.message(id: "m-junk", folder: "F-JUNK"),
            ]))
        }

        let page = try await makeProvider().bootstrap(page: nextLink, limit: 50)

        XCTAssertEqual(page.messages.map(\.id.providerID), ["m-2"])
        XCTAssertNil(page.nextPage)
        XCTAssertNil(page.changeCursor)
        XCTAssertEqual(requests(to: "/v1.0/me/messages").first?.url.absoluteString, nextLink)
        XCTAssertTrue(requests(to: "/v1.0/me/mailFolders").isEmpty, "a continued page must not re-enumerate folders")
    }

    func testBootstrapSurvivesMissingArchiveFolder() async throws {
        route { request in
            if let reply = self.wellKnownFolderReply(request, missing: ["archive"]) ?? self.folderListReply(request) { return reply }
            guard request.path == "/v1.0/me/messages" else { return nil }
            return .json(Fixtures.list([Fixtures.message(id: "m-1", folder: "F-INBOX")]))
        }

        let page = try await makeProvider().bootstrap(page: nil, limit: 10)

        let cursor = try GraphCursor.decode(try XCTUnwrap(page.changeCursor))
        XCTAssertNil(cursor.wellKnown["archive"])
        XCTAssertEqual(page.messages.map(\.id.providerID), ["m-1"])
    }

    func testBootstrapClampsPageSize() async throws {
        route { request in
            if let reply = self.wellKnownFolderReply(request) ?? self.folderListReply(request) { return reply }
            return request.path == "/v1.0/me/messages" ? .json(Fixtures.list([])) : nil
        }
        _ = try await makeProvider().bootstrap(page: nil, limit: 5000)
        XCTAssertEqual(requests(to: "/v1.0/me/messages").first?.query["$top"], "999")
    }

    func testBootstrapRejectsRelativePage() async {
        await expectProviderError({ try await self.makeProvider().bootstrap(page: "/me/messages?$skip=1", limit: 10) }) { $0.isDecoding }
        XCTAssertTrue(requests(to: "/v1.0/me/messages").isEmpty)
    }

    func testRoleMappingForEveryWellKnownFolder() {
        let folders = GraphWellKnownFolders(ids: Fixtures.folderIDs)
        XCTAssertEqual(folders.roles(folderID: "F-INBOX", isDraft: false), [.inbox])
        XCTAssertEqual(folders.roles(folderID: "F-SENT", isDraft: false), [.sent])
        XCTAssertEqual(folders.roles(folderID: "F-DRAFTS", isDraft: false), [.drafts])
        XCTAssertEqual(folders.roles(folderID: "F-TRASH", isDraft: false), [.trash])
        XCTAssertEqual(folders.roles(folderID: "F-JUNK", isDraft: false), [.spam])
        XCTAssertEqual(folders.roles(folderID: "F-ARCHIVE", isDraft: false), [])
        XCTAssertEqual(folders.roles(folderID: "F-SOMETHING", isDraft: false), [])
        XCTAssertEqual(folders.roles(folderID: nil, isDraft: false), [])
        XCTAssertEqual(folders.roles(folderID: "F-INBOX", isDraft: true), [.inbox, .drafts])
        XCTAssertEqual(folders.roles(folderID: nil, isDraft: true), [.drafts])
        XCTAssertEqual(folders.excludedFromBootstrap, ["F-TRASH", "F-JUNK"])
    }

    func testCursorRoundTrip() throws {
        let deltaLink = "https://graph.microsoft.com/v1.0/me/mailFolders/F-B/messages/delta?$deltatoken=abc"
        let original = GraphCursor(
            folders: ["F-A": nil, "F-B": deltaLink],
            nextLinks: ["F-A": "https://graph.microsoft.com/v1.0/me/mailFolders/F-A/messages/delta?$skiptoken=1"],
            wellKnown: ["inbox": "F-A"],
            since: nowString,
            foldersResolvedAt: nowString
        )

        let encoded = try original.encoded()
        let decoded = try GraphCursor.decode(encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try decoded.encoded(), encoded, "encoding must be stable across round trips")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let folders = try XCTUnwrap(json["folders"] as? [String: Any])
        XCTAssertTrue(folders["F-A"] is NSNull)
        XCTAssertEqual(folders["F-B"] as? String, deltaLink)
        XCTAssertEqual(json["since"] as? String, nowString)
        XCTAssertEqual(json["wellKnown"] as? [String: String], ["inbox": "F-A"])
    }

    func testMinimalCursorDecodesAndAsksForFolderRefresh() throws {
        let minimal = #"{"folders":{"F-A":null},"wellKnown":{"inbox":"F-A"},"since":"2026-11-01T10:00:00Z"}"#
        let cursor = try GraphCursor.decode(minimal)
        XCTAssertEqual(cursor.folders.count, 1)
        XCTAssertNil(cursor.deltaLink(for: "F-A"))
        XCTAssertTrue(cursor.nextLinks.isEmpty)
        XCTAssertNil(cursor.foldersResolvedAt)
        XCTAssertTrue(cursor.needsFolderRefresh(at: now))
    }

    func testFolderRefreshIsDueAfterADay() throws {
        let cursor = try GraphCursor.decode(try self.cursor(folders: [:]))
        XCTAssertFalse(cursor.needsFolderRefresh(at: now))
        XCTAssertFalse(cursor.needsFolderRefresh(at: now.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(cursor.needsFolderRefresh(at: now.addingTimeInterval(24 * 3600)))
    }

    func testGarbageCursorRequiresReset() {
        XCTAssertThrowsError(try GraphCursor.decode("{not json")) { error in
            XCTAssertTrue((error as? ProviderError)?.isResetRequired == true, "\(error)")
        }
        XCTAssertThrowsError(try GraphCursor.decode(#"{"folders":{}}"#)) { error in
            XCTAssertTrue((error as? ProviderError)?.isResetRequired == true, "\(error)")
        }
    }
}
