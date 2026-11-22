import Foundation
import PaperCore
import XCTest
@testable import PaperGraph

/// The folder walk that decides which folders get a delta of their own: the whole tree at any depth, each folder
/// once, a few listing pages a call so no poll waits for a large tree, with every request counted, and no listing
/// that fails or folder that moves meanwhile costing the polls or a folder its delta. And the full visit of the quiet
/// folders, spread over calls so a large tree never turns a quiet poll into a heavy one.
final class GraphFolderTreeTests: GraphTestCase {
    /// Inbox › Clients › Acme › 2026. Acme and 2026 sit below the two levels the walk once stopped at, so a change
    /// in either was only seen by a reconcile.
    private let deepTree: [String: [String]] = [
        "": ["F-INBOX", "F-SENT", "F-DRAFTS", "F-TRASH", "F-JUNK", "F-ARCHIVE"],
        "F-INBOX": ["F-CLIENTS"],
        "F-CLIENTS": ["F-ACME"],
        "F-ACME": ["F-ACME-2026"],
    ]
    private let deepest = "F-ACME-2026"

    /// Inbox holds twelve projects, each with one folder of its own: thirteen folders with children, more than
    /// one step of a walk lists.
    private var wideTree: [String: [String]] {
        let projects = (1...12).map { String(format: "F-P%02d", $0) }
        var tree: [String: [String]] = ["": ["F-INBOX", "F-SENT", "F-DRAFTS", "F-TRASH", "F-JUNK", "F-ARCHIVE"], "F-INBOX": projects]
        for project in projects {
            tree[project] = ["\(project)-A"]
        }
        return tree
    }

    /// The live lane's heavy page on Graph: a page dearer than a tenth of its share of the quota (a third of 1,000
    /// requests a minute) makes the next poll, the inbox's included, wait for the share to cover it again.
    private let heavyPage = 33

    private func deltaLink(_ folder: String, _ token: String) -> String {
        "https://graph.microsoft.com/v1.0/me/mailFolders/\(folder)/messages/delta?$deltatoken=\(folder)-\(token)"
    }

    /// Answers the folder listings from `tree`, keyed by parent ("" for the top level). Each folder reports as many
    /// children as `tree` gives it, and a listing longer than `pageSize` is split into pages chained by
    /// `$skiptoken`. A parent in `gone` answers 404, as one deleted since its own parent was listed does, and one in
    /// `refusing` answers what it maps to. A parent missing from `tree` is left unrouted, so a walk that asks for it
    /// fails loudly.
    private func folderTreeReply(_ request: Request, tree: [String: [String]], pageSize: Int, gone: Set<String>,
                                 refusing: [String: Reply] = [:]) -> Reply? {
        guard request.method == "GET" else { return nil }
        let prefix = "/v1.0/me/mailFolders/", suffix = "/childFolders"
        let parent: String
        if request.path == "/v1.0/me/mailFolders" {
            parent = ""
        } else if request.path.hasPrefix(prefix), request.path.hasSuffix(suffix) {
            parent = String(request.path.dropFirst(prefix.count).dropLast(suffix.count))
        } else {
            return nil
        }
        if gone.contains(parent) { return .json(Fixtures.notFoundError, status: 404) }
        if let refusal = refusing[parent] { return refusal }
        guard let children = tree[parent] else { return nil }
        let start = Int(request.query["$skiptoken"] ?? "0") ?? 0
        let end = min(start + pageSize, children.count)
        let items = children[start..<end].map { #"{"id":"\#($0)","childFolderCount":\#(tree[$0]?.count ?? 0)}"# }
        let next = end < children.count ? "https://graph.microsoft.com\(request.path)?$skiptoken=\(end)" : nil
        return .json(Fixtures.list(items, nextLink: next))
    }

    /// A mailbox shaped by `tree`. Every folder's first round is one empty page ending on `<folder>-d1`; a delta link
    /// answers `deltaItems[folder]` (nothing by default) and `<folder>-d2`. Removals looked up in `$batch` are gone.
    private func routeMailbox(tree: [String: [String]], childPageSize: Int = 200, gone: Set<String> = [],
                              refusing: [String: Reply] = [:], deltaItems: [String: [String]] = [:]) {
        route { request in
            if let reply = self.wellKnownFolderReply(request)
                ?? self.folderTreeReply(request, tree: tree, pageSize: childPageSize, gone: gone, refusing: refusing) {
                return reply
            }
            if request.method == "GET", request.path == "/v1.0/me/messages" {
                return .json(Fixtures.list([]))
            }
            if request.method == "GET", request.path.hasSuffix("/messages/delta") {
                let folder = String(request.path.dropFirst("/v1.0/me/mailFolders/".count).dropLast("/messages/delta".count))
                if request.query["$deltatoken"] != nil {
                    return .json(Fixtures.list(deltaItems[folder] ?? [], deltaLink: self.deltaLink(folder, "d2")))
                }
                return .json(Fixtures.list([], deltaLink: self.deltaLink(folder, "d1")))
            }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError) }
        }
    }

    /// The childFolders listings sent so far, as "F-INBOX" or "F-INBOX skip 2" for a later page.
    private func childListings() -> [String] {
        requests.filter { $0.path.hasSuffix("/childFolders") }.map { request in
            let parent = String(request.path.dropFirst("/v1.0/me/mailFolders/".count).dropLast("/childFolders".count))
            return request.query["$skiptoken"].map { "\(parent) skip \($0)" } ?? parent
        }
    }

    private func folderRequests() -> [Request] {
        requests.filter { $0.path.hasPrefix("/v1.0/me/mailFolders") && !$0.path.hasSuffix("/messages/delta") }
    }

    /// The folders whose delta was asked for so far, in order.
    private func polledFolders() -> [String] {
        requests.filter { $0.path.hasSuffix("/messages/delta") }.map {
            String($0.path.dropFirst("/v1.0/me/mailFolders/".count).dropLast("/messages/delta".count))
        }
    }

    /// Every folder in `tree` below the top level's parent key, as the walk should find them.
    private func folders(in tree: [String: [String]]) -> Set<String> {
        Set(tree.values.joined())
    }

    /// Steps a walk from the top to its end, as the polls would one after another.
    private func walkWholeTree(_ provider: GraphProvider) async throws -> [String] {
        var step = try await provider.stepFolderWalk(nil)
        var found = step.found
        while !step.walk.isFinished {
            step = try await provider.stepFolderWalk(step.walk)
            found += step.found
        }
        return found
    }

    /// A cursor whose folders all sit on their first delta link, with no full visit or walk under way; its folder
    /// list resolved at `resolvedAt`, the start of the test's day by default.
    private func seededCursor(_ folders: [String], resolvedAt: String? = nil) throws -> String {
        try cursor(folders: Dictionary(uniqueKeysWithValues: folders.map { ($0, Optional(deltaLink($0, "d1"))) }),
                   resolvedAt: resolvedAt)
    }

    /// A folder list resolved more than a day before the test's clock, so the next poll starts a walk.
    private let yesterday = "2026-10-31T09:00:00Z"

    private func serverError(_ status: Int, _ code: String) -> Reply {
        .json(#"{"error":{"code":"\#(code)","message":"Refused."}}"#, status: status)
    }

    // MARK: Changes at depth

    /// From a fresh account to a change four folders down: the bootstrap's walk gives every folder a delta, the
    /// polls seed them, and a full visit then reports what arrived in, was read in, moved into and was deleted from
    /// the deepest one, without walking the tree again.
    func testChangesInAFolderFourLevelsDownAreReportedByThePolls() async throws {
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        routeMailbox(tree: deepTree)

        let head = try await provider.bootstrap(page: nil, limit: 50)
        var cursor = try XCTUnwrap(head.changeCursor)
        XCTAssertEqual(Set(try GraphCursor.decode(cursor).folders.keys),
                       Set(Fixtures.folderIDs.values).union(["F-CLIENTS", "F-ACME", deepest]))

        // The priority folders seed on the first poll, every other folder one page a poll after it.
        for _ in 0..<20 {
            clock.advance(by: GraphCursor.fullVisitInterval)
            cursor = try await provider.changes(since: cursor, limit: 50).cursor
            if try GraphCursor.decode(cursor).folders.values.allSatisfy({ $0 != nil }) { break }
        }
        XCTAssertNotNil(try GraphCursor.decode(cursor).deltaLink(for: deepest))

        routeMailbox(tree: deepTree, deltaItems: [
            "F-INBOX": [Fixtures.removed("moved-in")],
            deepest: [
                Fixtures.message(id: "deep-new", folder: deepest),
                Fixtures.message(id: "deep-read", folder: deepest, isRead: true),
                Fixtures.message(id: "moved-in", folder: deepest),
                Fixtures.removed("deep-gone"),
            ],
        ])
        StubURLProtocol.clearRequests()
        clock.advance(by: GraphCursor.fullVisitInterval)

        let page = try await provider.changes(since: cursor, limit: 50)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["deep-new", "deep-read", "moved-in"])
        XCTAssertEqual(page.upserts.map(\.folderID), [deepest, deepest, deepest])
        XCTAssertEqual(page.upserts.map(\.isRead), [false, true, false])
        XCTAssertEqual(page.deletedIDs, ["deep-gone"])
        XCTAssertEqual(innerBatchRequests().map { $0["url"] as? String },
                       ["/me/messages/deep-gone?$select=\(GraphProvider.metadataSelect)"],
                       "the move out of the inbox is explained by the deep folder's delta, so only the deletion is looked up")
        XCTAssertEqual(requests(to: "/v1.0/me/mailFolders/\(deepest)/messages/delta").map { $0.query["$deltatoken"] },
                       ["\(deepest)-d2"], "asked once, on its delta link")
        XCTAssertTrue(folderRequests().isEmpty, "a poll between folder refreshes does not walk the tree")
        XCTAssertEqual(page.requestCount, requests.count)
    }

    // MARK: Cost of the walk

    /// The daily refresh walks the whole tree, a step a poll: six system folder lookups and the top level's first
    /// page, then five listing pages a poll, each page a request of its own (two folders a page here) and a listing
    /// the pages ran out in going on where it stopped. All of it is in `requestCount`, and the polls until the next
    /// refresh list no folders.
    func testTheWalkIsCountedAndRunsOnlyOnTheFolderRefresh() async throws {
        var tree = deepTree
        tree["F-INBOX"] = ["F-CLIENTS", "F-PERSONAL", "F-RECEIPTS"]
        routeMailbox(tree: tree, childPageSize: 2)
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        let wellKnownLinks = Dictionary(uniqueKeysWithValues: Fixtures.folderIDs.values.map { ($0, Optional(deltaLink($0, "d1"))) })
        let stale = try cursor(folders: wellKnownLinks, resolvedAt: "2026-10-31T09:00:00Z")

        let first = try await provider.changes(since: stale, limit: 50)

        XCTAssertEqual(childListings(), [])
        XCTAssertEqual(requests(to: "/v1.0/me/mailFolders").map { $0.query["$skiptoken"] }, [nil],
                       "the poll that starts the walk sends the top level's first page only")
        XCTAssertEqual(folderRequests().count, 6 + 1)
        XCTAssertEqual(first.requestCount, requests.count, "the walk's lookups and listings count with the delta requests")
        XCTAssertEqual(try GraphCursor.decode(first.cursor).walk?.pending.map(\.id), ["", "F-INBOX"],
                       "the rest of the top level, then the inbox's children")

        StubURLProtocol.clearRequests()
        clock.advance(by: 5)
        let second = try await provider.changes(since: first.cursor, limit: 50)

        XCTAssertEqual(requests(to: "/v1.0/me/mailFolders").map { $0.query["$skiptoken"] }, ["2", "4"])
        XCTAssertEqual(childListings(), ["F-INBOX", "F-INBOX skip 2", "F-CLIENTS"])
        XCTAssertEqual(folderRequests().count, GraphProvider.maxWalkPagesPerCall, "no lookups again until the next walk")
        XCTAssertEqual(second.requestCount, requests.count)
        XCTAssertEqual(try GraphCursor.decode(second.cursor).walk?.pending.map(\.id), ["F-ACME"])

        StubURLProtocol.clearRequests()
        clock.advance(by: 5)
        let third = try await provider.changes(since: second.cursor, limit: 50)

        XCTAssertEqual(childListings(), ["F-ACME"])
        XCTAssertEqual(third.requestCount, requests.count)
        let refreshed = try GraphCursor.decode(third.cursor)
        XCTAssertEqual(Set(refreshed.folders.keys),
                       Set(Fixtures.folderIDs.values).union(["F-CLIENTS", "F-PERSONAL", "F-RECEIPTS", "F-ACME", deepest]))
        XCTAssertNil(refreshed.walk)
        XCTAssertEqual(refreshed.foldersResolvedAt, nowString, "the next walk is due a day after this one started")

        // Polls for the rest of the day seed the new folders and poll the rest, and never list a folder.
        var latest = third
        for _ in 0..<8 {
            StubURLProtocol.clearRequests()
            clock.advance(by: GraphCursor.fullVisitInterval)
            latest = try await provider.changes(since: latest.cursor, limit: 50)
            XCTAssertTrue(folderRequests().isEmpty)
            XCTAssertEqual(latest.requestCount, requests.count)
        }
        XCTAssertNotNil(try GraphCursor.decode(latest.cursor).deltaLink(for: deepest))
    }

    /// A tree with thirteen folders that have children is walked five listings a poll, so the poll that carries new
    /// inbox mail never waits for the whole tree. The folders found join as they are found; one the walk does not
    /// find is kept until the next walk misses it too, then dropped.
    func testAWideTreeIsWalkedAFewFoldersAPollWhileTheInboxIsPolledEveryTime() async throws {
        let tree = wideTree
        routeMailbox(tree: tree)
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        var links = Dictionary(uniqueKeysWithValues: Fixtures.folderIDs.values.map { ($0, Optional(deltaLink($0, "d1"))) })
        links["F-GONE"] = deltaLink("F-GONE", "d1")
        var current = try cursor(folders: links, resolvedAt: "2026-10-31T09:00:00Z")
        var listings: [[String]] = []
        var walks: [GraphFolderWalk?] = []
        var cursors: [GraphCursor] = []

        for call in 0..<5 {
            StubURLProtocol.clearRequests()
            if call > 0 { clock.advance(by: 5) }
            let page = try await provider.changes(since: current, limit: 50)
            XCTAssertEqual(polledFolders().first, "F-INBOX", "the inbox is polled on every call of the walk")
            XCTAssertEqual(page.requestCount, requests.count)
            listings.append(childListings())
            let next = try GraphCursor.decode(page.cursor)
            walks.append(next.walk)
            cursors.append(next)
            current = page.cursor
        }

        XCTAssertEqual(listings, [
            [],
            ["F-INBOX", "F-P01", "F-P02", "F-P03", "F-P04"],
            ["F-P05", "F-P06", "F-P07", "F-P08", "F-P09"],
            ["F-P10", "F-P11", "F-P12"],
            [],
        ])
        XCTAssertEqual(walks.map { $0?.pending.count }, [1, 8, 3, nil, nil])
        XCTAssertTrue(cursors[1].folders.keys.contains("F-P12"), "a folder joins the polls as soon as it is found")
        XCTAssertTrue(cursors[1].folders.keys.contains("F-P04-A"))
        XCTAssertFalse(cursors[1].folders.keys.contains("F-P05-A"))
        XCTAssertTrue(cursors[2].folders.keys.contains("F-GONE"), "kept while the walk may still find it")
        XCTAssertEqual(Set(cursors[3].folders.keys), folders(in: tree).union(["F-GONE"]))
        XCTAssertEqual(cursors[3].missed, ["F-GONE"], "missed once: a walk spread over polls can miss a folder moved meanwhile")
        XCTAssertEqual(cursors[3].deltaLink(for: "F-GONE"), deltaLink("F-GONE", "d2"), "and still polled")
        XCTAssertEqual(cursors[3].foldersResolvedAt, nowString)

        clock.advance(by: GraphCursor.folderRefreshInterval)
        for _ in 0..<4 {
            clock.advance(by: 5)
            current = try await provider.changes(since: current, limit: 50).cursor
        }
        let nextDay = try GraphCursor.decode(current)
        XCTAssertNil(nextDay.walk)
        XCTAssertEqual(Set(nextDay.folders.keys), folders(in: tree), "dropped once a second walk in a row misses it")
        XCTAssertEqual(nextDay.missed, [])
    }

    /// The bootstrap starts the walk as a poll would and takes one step of it, so a new account's first page waits
    /// for at most five listings, however large the tree; the polls walk on. The page says what the call sent.
    func testTheBootstrapTakesTheFirstStepsOfTheWalkAndReportsItsRequests() async throws {
        let tree = wideTree
        routeMailbox(tree: tree)
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)

        let head = try await provider.bootstrap(page: nil, limit: 50)

        XCTAssertEqual(childListings(), ["F-INBOX", "F-P01", "F-P02", "F-P03", "F-P04"])
        XCTAssertEqual(head.requestCount, 6 + 1 + 5 + 1, "lookups, the top level, a step of the walk and the page")
        XCTAssertEqual(head.requestCount, requests.count)
        var cursor = try GraphCursor.decode(try XCTUnwrap(head.changeCursor))
        XCTAssertEqual(cursor.walk?.pending.map(\.id), (5...12).map { String(format: "F-P%02d", $0) })
        XCTAssertTrue(cursor.folders.keys.contains("F-P04-A"))

        var current = try XCTUnwrap(head.changeCursor)
        for _ in 0..<2 {
            clock.advance(by: 5)
            current = try await provider.changes(since: current, limit: 50).cursor
        }
        cursor = try GraphCursor.decode(current)
        XCTAssertNil(cursor.walk)
        XCTAssertEqual(Set(cursor.folders.keys), folders(in: tree))

        StubURLProtocol.clearRequests()
        let next = try await provider.bootstrap(page: "https://graph.microsoft.com/v1.0/me/messages?$skip=50", limit: 50)
        XCTAssertEqual(next.requestCount, 1, "a later page sends the listing alone")
    }

    /// A folder found in one listing can be deleted before its own children are asked for; Graph then answers 404.
    /// The walk skips it with its children, as the next walk would find, and goes on with the rest of the tree,
    /// rather than failing the poll (and the bootstrap) with it.
    func testAFolderDeletedBeforeItsChildrenAreListedIsSkipped() async throws {
        var tree = deepTree
        tree["F-TRASH"] = ["F-OLDPROJECTS"]
        tree["F-OLDPROJECTS"] = ["F-OLD-A", "F-OLD-B"]
        routeMailbox(tree: tree, gone: ["F-OLDPROJECTS"])
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        let wellKnownLinks = Dictionary(uniqueKeysWithValues: Fixtures.folderIDs.values.map { ($0, Optional(deltaLink($0, "d1"))) })

        var current = try cursor(folders: wellKnownLinks, resolvedAt: "2026-10-31T09:00:00Z")
        for _ in 0..<2 {
            current = try await provider.changes(since: current, limit: 50).cursor
            clock.advance(by: 5)
        }

        XCTAssertEqual(childListings(), ["F-INBOX", "F-TRASH", "F-CLIENTS", "F-OLDPROJECTS", "F-ACME"])
        let walked = try GraphCursor.decode(current)
        XCTAssertNil(walked.walk)
        XCTAssertTrue(walked.folders.keys.contains(deepest), "the rest of the tree is walked")
        XCTAssertFalse(walked.folders.keys.contains("F-OLD-A"))
        XCTAssertEqual(requests(to: "/v1.0/me/mailFolders/F-INBOX/messages/delta").count, 2, "and the inbox polled each time")

        StubURLProtocol.clearRequests()
        let head = try await provider.bootstrap(page: nil, limit: 50)
        XCTAssertNotNil(head.changeCursor, "the bootstrap's walk goes on past it too")
    }

    /// A folder made in Outlook at any depth is picked up by the next refresh, and one deleted there is dropped once
    /// a second walk in a row has not found it, as top-level folders are.
    func testTheNextRefreshAddsAndDropsFoldersAtAnyDepth() async throws {
        var tree = deepTree
        tree["F-ACME"] = ["F-ACME-2027"]
        routeMailbox(tree: tree)
        var links = Dictionary(uniqueKeysWithValues: Fixtures.folderIDs.values.map { ($0, Optional(deltaLink($0, "d1"))) })
        for folder in ["F-CLIENTS", "F-ACME", deepest] {
            links[folder] = deltaLink(folder, "d1")
        }
        let stale = try cursor(folders: links, resolvedAt: "2026-10-31T09:00:00Z")
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)

        let first = try await provider.changes(since: stale, limit: 50)
        let started = try GraphCursor.decode(first.cursor)
        XCTAssertTrue(started.folders.keys.contains(deepest), "kept while the walk is under way")
        clock.advance(by: 5)
        let page = try await provider.changes(since: first.cursor, limit: 50)

        let next = try GraphCursor.decode(page.cursor)
        XCTAssertNil(next.walk)
        XCTAssertTrue(next.folders.keys.contains("F-ACME-2027"))
        XCTAssertEqual(next.deltaLink(for: "F-ACME"), deltaLink("F-ACME", "d2"), "a folder that survives keeps its delta")
        XCTAssertEqual(next.missed, [deepest], "kept a day longer, in case the walk passed it by")

        XCTAssertEqual(page.goneFolders, [], "missed once is not gone")

        clock.advance(by: GraphCursor.folderRefreshInterval)
        var current = page.cursor
        var gone: [String] = []
        for _ in 0..<2 {
            let nextPage = try await provider.changes(since: current, limit: 50)
            current = nextPage.cursor
            gone += nextPage.goneFolders
            clock.advance(by: 5)
        }
        let nextDay = try GraphCursor.decode(current)
        XCTAssertNil(nextDay.walk)
        XCTAssertFalse(nextDay.folders.keys.contains(deepest))
        XCTAssertTrue(nextDay.folders.keys.contains("F-ACME-2027"))
        XCTAssertEqual(nextDay.missed, [])
        XCTAssertEqual(gone, [deepest], "a folder dropped from the polls is reported, so its stored mail is checked")
    }

    // MARK: Listings that fail

    /// Acme, three levels down, refuses to list its children, as a corrupt folder or one the account may no longer
    /// open does, and keeps refusing. The walk tries it on three calls and then gives up on it, while every call polls
    /// the inbox; the folder below Acme keeps its delta, since a walk that did not look there cannot say it is gone.
    func testAListingThatKeepsFailingNeitherStopsThePollsNorDropsTheFoldersBelowIt() async throws {
        let refusals: [(String, Reply)] = [
            ("500", serverError(500, "ErrorInternalServerError")),
            ("403", serverError(403, "ErrorAccessDenied")),
            ("504", .status(504)),
            ("garbled", .json("not json")),
        ]
        for (name, refusal) in refusals {
            StubURLProtocol.clearRequests()
            routeMailbox(tree: deepTree, refusing: ["F-ACME": refusal])
            let clock = StepClock(now)
            let provider = makeProvider(clock: clock)
            var current = try seededCursor(Array(folders(in: deepTree)), resolvedAt: yesterday)

            for call in 0..<8 {
                if call > 0 { clock.advance(by: 5) }
                current = try await provider.changes(since: current, limit: 50).cursor
            }

            XCTAssertEqual(requests(to: "/v1.0/me/mailFolders/F-INBOX/messages/delta").count, 8,
                           "\(name): the inbox is polled on every call")
            XCTAssertEqual(childListings().filter { $0 == "F-ACME" }.count, GraphProvider.maxWalkAttempts,
                           "\(name): tried on three calls, then given up on")
            let walked = try GraphCursor.decode(current)
            XCTAssertNil(walked.walk, name)
            XCTAssertEqual(Set(walked.folders.keys), folders(in: deepTree), name)
            XCTAssertEqual(walked.deltaLink(for: deepest), deltaLink(deepest, "d2"), "\(name): the folder below keeps its delta")
            XCTAssertEqual(walked.missed, [], "\(name): and is not counted as missed")
        }
    }

    /// A throttle on a listing is the mailbox's limit, which the call's delta requests would meet as well: it fails
    /// the call, for the engine to wait out, rather than being held against the listing.
    func testAThrottledListingFailsTheCall() async throws {
        let throttle = Reply.json(#"{"error":{"code":"ApplicationThrottled","message":"Slow down."}}"#, status: 429,
                                  headers: ["Retry-After": "7"])
        routeMailbox(tree: deepTree, refusing: ["F-CLIENTS": throttle])
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        let first = try await provider.changes(since: try seededCursor(Array(folders(in: deepTree)), resolvedAt: yesterday), limit: 50)
        clock.advance(by: 5)

        await expectProviderError({ try await provider.changes(since: first.cursor, limit: 50) }) { $0.retryAfter == 7 }
    }

    /// A new account's walk meets a listing that fails, in its first step or its second: the head page goes out all
    /// the same, the listing left first in the walk with one failure, and the polls list it and walk on.
    func testTheBootstrapGoesOnPastAListingThatFails() async throws {
        routeMailbox(tree: deepTree, refusing: ["": serverError(500, "ErrorInternalServerError")])
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)

        let head = try await provider.bootstrap(page: nil, limit: 50)

        XCTAssertEqual(requests(to: "/v1.0/me/mailFolders").count, 1, "tried once, as the polls try it again")
        XCTAssertEqual(requests(to: "/v1.0/me/messages").count, 1)
        XCTAssertEqual(head.requestCount, requests.count)
        var cursor = try GraphCursor.decode(try XCTUnwrap(head.changeCursor))
        XCTAssertEqual(cursor.walk?.pending, [GraphFolderWalk.Parent(id: "", depth: 0, failures: 1)])
        XCTAssertEqual(Set(cursor.folders.keys), Set(Fixtures.folderIDs.values), "the system folders are polled meanwhile")

        routeMailbox(tree: deepTree)
        clock.advance(by: 5)
        cursor = try GraphCursor.decode(try await provider.changes(since: try XCTUnwrap(head.changeCursor), limit: 50).cursor)
        XCTAssertNil(cursor.walk)
        XCTAssertEqual(Set(cursor.folders.keys), folders(in: deepTree))

        StubURLProtocol.clearRequests()
        routeMailbox(tree: deepTree, refusing: ["F-ACME": serverError(500, "ErrorInternalServerError")])
        let second = try await provider.bootstrap(page: nil, limit: 50)
        XCTAssertEqual(childListings(), ["F-INBOX", "F-CLIENTS", "F-ACME"])
        cursor = try GraphCursor.decode(try XCTUnwrap(second.changeCursor))
        XCTAssertEqual(cursor.walk?.pending, [GraphFolderWalk.Parent(id: "F-ACME", depth: 3, failures: 1)])
    }

    // MARK: Folders that move during a walk

    /// The walk lists the inbox's twelve projects over three polls. Meanwhile Mover is dragged out of the last
    /// project, not listed yet, into the first, listed already, so this walk never meets it. It keeps its delta and
    /// goes on reporting what a rule files into it, and the next walk finds it where it now is.
    func testAFolderMovedDuringTheWalkKeepsItsDelta() async throws {
        var before = wideTree
        before["F-P12"] = ["F-P12-A", "F-MOVER"]
        var after = wideTree
        after["F-P01"] = ["F-P01-A", "F-MOVER"]
        routeMailbox(tree: before)
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        var current = try seededCursor(Array(folders(in: before)), resolvedAt: yesterday)

        for call in 0..<4 {
            if call == 2 {
                routeMailbox(tree: after, deltaItems: ["F-MOVER": [Fixtures.message(id: "rule-filed", folder: "F-MOVER")]])
            }
            if call > 0 { clock.advance(by: 5) }
            current = try await provider.changes(since: current, limit: 50).cursor
        }
        let walked = try GraphCursor.decode(current)
        XCTAssertNil(walked.walk, "the walk is over without meeting Mover")
        XCTAssertEqual(walked.missed, ["F-MOVER"])
        XCTAssertEqual(walked.deltaLink(for: "F-MOVER"), deltaLink("F-MOVER", "d2"), "kept on its delta link")

        var reported: [String] = []
        for _ in 0..<8 where reported.isEmpty {
            clock.advance(by: 5)
            let page = try await provider.changes(since: current, limit: 50)
            reported = page.upserts.map(\.id.providerID)
            current = page.cursor
        }
        XCTAssertEqual(reported, ["rule-filed"], "what a rule files into it is still reported")

        clock.advance(by: GraphCursor.folderRefreshInterval)
        for _ in 0..<4 {
            clock.advance(by: 5)
            current = try await provider.changes(since: current, limit: 50).cursor
        }
        let nextDay = try GraphCursor.decode(current)
        XCTAssertNil(nextDay.walk)
        XCTAssertEqual(nextDay.missed, [], "found under the project it was moved to")
        XCTAssertEqual(Set(nextDay.folders.keys), folders(in: after))
    }

    // MARK: Cursors from before the walk

    /// A cursor stored by the version that listed folders two levels deep, its folder list resolved an hour before
    /// the update, so Acme, three levels down, has no delta. The first poll after the update starts the walk rather
    /// than waiting out the day since that listing, Acme joins on the next, and the walk's own stamp then holds the
    /// next walk off for a day.
    func testACursorListedTwoLevelsDeepStartsAWalkOnItsFirstPoll() async throws {
        let tree: [String: [String]] = [
            "": ["F-INBOX", "F-SENT", "F-DRAFTS", "F-TRASH", "F-JUNK", "F-ARCHIVE"],
            "F-INBOX": ["F-CLIENTS"],
            "F-CLIENTS": ["F-ACME"],
        ]
        routeMailbox(tree: tree)
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        let listed = (Fixtures.folderIDs.values.sorted() + ["F-CLIENTS"]).map { #""\#($0)":"\#(deltaLink($0, "d1"))""# }
        let wellKnown = Fixtures.folderIDs.sorted { $0.key < $1.key }.map { #""\#($0.key)":"\#($0.value)""# }
        // The shape the shipped encoder wrote: no walk, no polledAt, no folderScope.
        let shipped = #"{"deltaScope":"mailbox","folders":{\#(listed.joined(separator: ","))},"foldersResolvedAt":"2026-11-01T09:00:00Z","fullVisitAt":"2026-11-01T09:59:50Z","nextLinks":{},"since":"2026-10-01T10:00:00Z","wellKnown":{\#(wellKnown.joined(separator: ","))}}"#
        XCTAssertTrue(try GraphCursor.decode(shipped).needsFolderRefresh(at: now))

        let first = try await provider.changes(since: shipped, limit: 50)
        XCTAssertEqual(requests(to: "/v1.0/me/mailFolders").count, 1, "the walk starts on the first poll")
        clock.advance(by: 5)
        let second = try await provider.changes(since: first.cursor, limit: 50)

        let walked = try GraphCursor.decode(second.cursor)
        XCTAssertNil(walked.walk)
        XCTAssertEqual(Set(walked.folders.keys), folders(in: tree))
        XCTAssertNotNil(walked.deltaLink(for: "F-CLIENTS"), "a folder it already had keeps its delta")
        XCTAssertEqual(walked.foldersResolvedAt, nowString)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.cursor.utf8)) as? [String: Any])
        XCTAssertEqual(json["folderScope"] as? String, GraphCursor.treeScope)

        StubURLProtocol.clearRequests()
        clock.advance(by: 5)
        _ = try await provider.changes(since: second.cursor, limit: 50)
        XCTAssertTrue(folderRequests().isEmpty, "the next walk waits a day")
    }

    // MARK: Listings of many pages

    /// One folder holds 150 others and the top level 32, listed ten a page here (Graph lists 200 a page, so this is
    /// a folder of 3,000, scaled down). A step sends at most five pages, carrying on with a listing where the last
    /// step stopped, so with the priority three and twenty quiet folders a background poll stays a light page while
    /// the walk goes on, and the inbox's next poll never waits for the walk's share of the quota.
    func testAWalkStepSendsAFewPagesHoweverManyFoldersAListingHolds() async throws {
        let custom = (1...25).map { String(format: "F-C%02d", $0) }
        let tree: [String: [String]] = [
            "": ["F-INBOX", "F-SENT", "F-DRAFTS", "F-TRASH", "F-JUNK", "F-ARCHIVE"] + custom + ["F-WIDE"],
            "F-WIDE": (1...150).map { String(format: "F-WIDE-%03d", $0) },
        ]
        routeMailbox(tree: tree, childPageSize: 10)
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        var current = try seededCursor(Array(folders(in: tree)), resolvedAt: yesterday)
        var counts: [Int] = []
        var pages: [Int] = []

        for call in 0..<8 {
            StubURLProtocol.clearRequests()
            if call > 0 { clock.advance(by: 30) }
            let page = try await provider.changes(since: current, limit: 50)
            XCTAssertEqual(polledFolders().first, "F-INBOX")
            XCTAssertEqual(page.requestCount, requests.count)
            counts.append(try XCTUnwrap(page.requestCount))
            pages.append(requests.filter { $0.path == "/v1.0/me/mailFolders" || $0.path.hasSuffix("/childFolders") }.count)
            current = page.cursor
        }

        XCTAssertEqual(pages, [1, 5, 5, 5, 3, 0, 0, 0], "four pages of the top level, then fifteen of the wide folder")
        XCTAssertEqual(counts.first, 6 + 1 + 3 + 20, "the call that starts the walk: lookups, a page and the polls")
        XCTAssertLessThanOrEqual(counts.max() ?? .max, heavyPage, "no step makes a heavy page")
        let walked = try GraphCursor.decode(current)
        XCTAssertNil(walked.walk)
        XCTAssertEqual(Set(walked.folders.keys), folders(in: tree))
        XCTAssertEqual(walked.missed, [])
    }

    // MARK: Shape of the listing

    /// Inbox is listed twice at the top, and Acme names Inbox as its own child. Each folder is kept once and each
    /// parent's children are asked for once, so the walk ends instead of going round the loop.
    func testADuplicateOrACycleInTheListingIsWalkedOnce() async throws {
        routeMailbox(tree: [
            "": ["F-INBOX", "F-SENT", "F-INBOX"],
            "F-INBOX": ["F-CLIENTS"],
            "F-CLIENTS": ["F-ACME"],
            "F-ACME": ["F-INBOX", deepest],
            deepest: [],
        ])

        let ids = try await walkWholeTree(makeProvider())

        XCTAssertEqual(ids.count, Set(ids).count, "no folder twice")
        XCTAssertEqual(Set(ids), ["F-INBOX", "F-SENT", "F-CLIENTS", "F-ACME", deepest])
        XCTAssertEqual(childListings(), ["F-INBOX", "F-CLIENTS", "F-ACME"])
    }

    /// A listing that never stops handing back a new child (F-LEVEL-1 › F-LEVEL-2 › …) is walked to the depth cap
    /// and no further. Past a hundred levels the stub refuses, so a walk without the cap fails instead of hanging.
    func testTheWalkStopsAtTheDepthCap() async throws {
        route { request in
            if let reply = self.wellKnownFolderReply(request) { return reply }
            guard request.method == "GET" else { return nil }
            if request.path == "/v1.0/me/mailFolders" {
                return .json(Fixtures.list([#"{"id":"F-LEVEL-1","childFolderCount":1}"#]))
            }
            let prefix = "/v1.0/me/mailFolders/F-LEVEL-", suffix = "/childFolders"
            guard request.path.hasPrefix(prefix), request.path.hasSuffix(suffix),
                  let depth = Int(request.path.dropFirst(prefix.count).dropLast(suffix.count)), depth < 100 else { return nil }
            return .json(Fixtures.list([#"{"id":"F-LEVEL-\#(depth + 1)","childFolderCount":1}"#]))
        }

        let ids = try await walkWholeTree(makeProvider())

        XCTAssertEqual(GraphProvider.maxFolderDepth, 16)
        XCTAssertEqual(ids, (1...16).map { "F-LEVEL-\($0)" })
        XCTAssertEqual(childListings(), (1...15).map { "F-LEVEL-\($0)" }, "the sixteenth level's children are not asked for")
    }

    // MARK: Full visits of a large tree

    /// Two hundred quiet folders, the shape of an archive filed by client and year. Polled every 5 s, as while the
    /// app is active, no call is a heavy page, so the live lane never holds the next poll (and new inbox mail) back
    /// for its share of the quota; the full visit goes ten folders a poll and reaches every folder within 95 s, and
    /// none twice within 30 s. Ten minutes of polls spend about 1,600 of Outlook's 10,000 requests.
    func testTwoHundredQuietFoldersKeepEveryPollLight() async throws {
        let custom = (1...197).map { String(format: "F-%03d", $0) }
        let quiet = Set(custom).union(["F-TRASH", "F-JUNK", "F-ARCHIVE"])
        routeMailbox(tree: [:])
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        var current = try seededCursor(custom + Fixtures.folderIDs.values)
        var visits: [String: [TimeInterval]] = [:]
        var counts: [Int] = []

        for call in 0..<120 {
            StubURLProtocol.clearRequests()
            if call > 0 { clock.advance(by: 5) }
            let page = try await provider.changes(since: current, limit: 50)
            let polled = polledFolders()
            XCTAssertEqual(Array(polled.prefix(3)), ["F-INBOX", "F-SENT", "F-DRAFTS"])
            for folder in polled.dropFirst(3) {
                visits[folder, default: []].append(Double(call) * 5)
            }
            counts.append(try XCTUnwrap(page.requestCount))
            current = page.cursor
        }

        XCTAssertLessThanOrEqual(counts.max() ?? 0, heavyPage, "a quiet poll is never a heavy page")
        XCTAssertEqual(Array(counts.prefix(3)), [23, 13, 13], "twenty folders after a long gap, then ten a poll")
        XCTAssertEqual(Set(visits.keys), quiet)
        XCTAssertLessThanOrEqual(visits.values.compactMap(\.first).max() ?? .infinity, 95)
        for (folder, times) in visits {
            for (earlier, later) in zip(times, times.dropFirst()) {
                XCTAssertGreaterThanOrEqual(later - earlier, GraphCursor.fullVisitInterval, folder)
            }
        }
        XCTAssertLessThanOrEqual(counts.reduce(0, +), 1_600)
    }

    /// The mailbox of forty folders the 30 s visit was sized for keeps it while the app is active: polled every 5 s,
    /// each of its 37 quiet folders is asked once every 30 s, the visit spread over four polls, and ten minutes
    /// spend 1,100 requests as before. Polled every 30 s, as in the background, no call takes more than twenty, so
    /// the visit takes two polls.
    func testFortyFoldersKeepTheirVisitEveryThirtySeconds() async throws {
        let custom = (1...34).map { String(format: "F-%03d", $0) }
        routeMailbox(tree: [:])
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        let start = try seededCursor(custom + Fixtures.folderIDs.values)
        var current = start
        var total = 0
        var visitsPerFolder: [String: Int] = [:]

        for call in 0..<120 {
            StubURLProtocol.clearRequests()
            if call > 0 { clock.advance(by: 5) }
            let page = try await provider.changes(since: current, limit: 50)
            for folder in polledFolders().dropFirst(3) { visitsPerFolder[folder, default: 0] += 1 }
            total += try XCTUnwrap(page.requestCount)
            current = page.cursor
        }

        XCTAssertEqual(total, 3 * 120 + 37 * 20)
        XCTAssertEqual(visitsPerFolder.count, 37)
        XCTAssertEqual(Set(visitsPerFolder.values), [20], "once every 30 s for ten minutes")

        current = start
        var background: [Int] = []
        for call in 0..<4 {
            if call > 0 { clock.advance(by: 30) }
            let page = try await provider.changes(since: current, limit: 50)
            background.append(try XCTUnwrap(page.requestCount))
            current = page.cursor
        }
        XCTAssertEqual(background, [3 + 20, 3 + 17, 3 + 20, 3 + 17])
    }

    /// The full visit's place survives in the cursor: a folder dropped or added meanwhile shifts nothing, since the
    /// visit goes on in id order after the last folder it polled.
    func testAFullVisitGoesOnAfterTheLastFolderItPolled() async throws {
        let custom = (1...30).map { String(format: "F-%03d", $0) }
        routeMailbox(tree: [:])
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)

        let first = try await provider.changes(since: try seededCursor(custom + Fixtures.folderIDs.values), limit: 50)
        var cursor = try GraphCursor.decode(first.cursor)
        XCTAssertEqual(cursor.fullVisitAfter, "F-020", "twenty folders in id order on the first call")
        XCTAssertEqual(cursor.polledAt, nowString)
        // The next folder in line goes, and one sorting before the place is left to the next visit.
        cursor.folders.removeValue(forKey: "F-021")
        cursor.folders["F-000"] = deltaLink("F-000", "d1")

        StubURLProtocol.clearRequests()
        clock.advance(by: 5)
        let second = try await provider.changes(since: try cursor.encoded(), limit: 50)

        // Ten folders after F-020 in id order: F-022 to F-030, then F-ARCHIVE; the system folders lead the call.
        XCTAssertEqual(Array(polledFolders().dropFirst(3)), ["F-ARCHIVE"] + (22...30).map { String(format: "F-%03d", $0) })
        XCTAssertEqual(try GraphCursor.decode(second.cursor).fullVisitAfter, "F-ARCHIVE")

        StubURLProtocol.clearRequests()
        clock.advance(by: 5)
        let third = try await provider.changes(since: second.cursor, limit: 50)

        XCTAssertEqual(Array(polledFolders().dropFirst(3)), ["F-TRASH", "F-JUNK"])
        XCTAssertNil(try GraphCursor.decode(third.cursor).fullVisitAfter, "the visit is over")
        XCTAssertEqual(try GraphCursor.decode(third.cursor).fullVisitAt, nowString)
    }
}
