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

    private func deltaPath(_ folder: String) -> String {
        "/v1.0/me/mailFolders/\(folder)/messages/delta"
    }

    private func deltaLink(_ folder: String, _ token: String) -> String {
        "https://graph.microsoft.com/v1.0/me/mailFolders/\(folder)/messages/delta?$deltatoken=\(token)"
    }

    private func skipLink(_ folder: String, _ token: String) -> String {
        "https://graph.microsoft.com/v1.0/me/mailFolders/\(folder)/messages/delta?$skiptoken=\(token)"
    }

    private func folder(of request: Request) -> String {
        String(request.path.dropFirst("/v1.0/me/mailFolders/".count).dropLast("/messages/delta".count))
    }

    /// Each listed folder's first round is `seedPages[folder]` pages of `perPage` messages (`<folder>-<page>`,
    /// then `<folder>-<page>-2` and on), chained by `$skiptoken=<page>` and ending on `$deltatoken=<folder>-d1`.
    /// Any request on a delta link answers empty with `<folder>-d2`, so a folder that has finished seeding polls
    /// quietly from then on.
    private func routeSeeds(_ seedPages: [String: Int], perPage: Int = 1) {
        route { request in
            guard request.method == "GET", request.path.hasSuffix("/messages/delta") else { return nil }
            let folder = self.folder(of: request)
            if request.query["$deltatoken"] != nil {
                return .json(Fixtures.list([], deltaLink: self.deltaLink(folder, "\(folder)-d2")))
            }
            guard let pages = seedPages[folder] else { return nil }
            let page = Int(request.query["$skiptoken"] ?? "1") ?? 1
            let items = (1...perPage).map { item in
                Fixtures.message(id: item == 1 ? "\(folder)-\(page)" : "\(folder)-\(page)-\(item)", folder: folder)
            }
            return page < pages
                ? .json(Fixtures.list(items, nextLink: self.skipLink(folder, String(page + 1))))
                : .json(Fixtures.list(items, deltaLink: self.deltaLink(folder, "\(folder)-d1")))
        }
    }

    /// The delta requests sent so far, as "F-INBOX seed", "F-INBOX skip 2" or "F-INBOX delta F-INBOX-d1".
    private func trail() -> [String] {
        requests.filter { $0.path.hasSuffix("/messages/delta") }.map { request in
            let folder = folder(of: request)
            if let token = request.query["$skiptoken"] { return "\(folder) skip \(token)" }
            if let token = request.query["$deltatoken"] { return "\(folder) delta \(token)" }
            return "\(folder) seed"
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
            XCTAssertNil(seed.query["$filter"], "a receivedDateTime filter would hide changes to mail that predates the account")
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

        // The custom folders already hold delta links: unseeded, they would wait their turn one page per call.
        _ = try await makeProvider().changes(since: try cursor(folders: [
            "F-AAA": deltaLink("F-AAA", "a1"), "F-SENT": nil, "F-INBOX": nil, "F-ZZZ": deltaLink("F-ZZZ", "z1"),
        ]), limit: 10)

        XCTAssertEqual(requests.map(\.path), [
            inboxDelta,
            sentDelta,
            "/v1.0/me/mailFolders/F-AAA/messages/delta",
            "/v1.0/me/mailFolders/F-ZZZ/messages/delta",
        ])
    }

    /// After a bootstrap no folder has a delta link. The inbox's first round drains in full on the first poll,
    /// while the archive's listing of its whole content goes one page per poll and never holds the poll open.
    func testInboxFirstRoundDrainsWhileArchiveSeedsOnePagePerCall() async throws {
        routeSeeds(["F-INBOX": 3, "F-ARCHIVE": 3])
        // Polls a full visit apart, so every folder on a delta link is due each time and only seeding is read here.
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)

        let first = try await provider.changes(since: try cursor(folders: ["F-INBOX": nil, "F-ARCHIVE": nil]), limit: 25)

        XCTAssertEqual(trail(), ["F-INBOX seed", "F-ARCHIVE seed", "F-INBOX skip 2", "F-INBOX skip 3"])
        XCTAssertEqual(first.upserts.map(\.id.providerID), ["F-INBOX-1", "F-ARCHIVE-1", "F-INBOX-2", "F-INBOX-3"])
        XCTAssertFalse(first.hasMore, "the archive's remaining seed pages wait for the next poll")
        let archiveSeed = try XCTUnwrap(requests(to: deltaPath("F-ARCHIVE")).first)
        XCTAssertNil(archiveSeed.query["$filter"])
        XCTAssertEqual(archiveSeed.query["$select"], GraphProvider.metadataSelect)
        XCTAssertTrue(archiveSeed.header("Prefer")?.contains("odata.maxpagesize=25") ?? false)
        let afterFirst = try GraphCursor.decode(first.cursor)
        XCTAssertEqual(afterFirst.deltaLink(for: "F-INBOX"), deltaLink("F-INBOX", "F-INBOX-d1"))
        XCTAssertNil(afterFirst.deltaLink(for: "F-ARCHIVE"))
        XCTAssertEqual(afterFirst.nextLinks, ["F-ARCHIVE": skipLink("F-ARCHIVE", "2")])

        StubURLProtocol.clearRequests()
        clock.advance(by: GraphCursor.fullVisitInterval)
        let second = try await provider.changes(since: first.cursor, limit: 25)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d1", "F-ARCHIVE skip 2"])
        XCTAssertEqual(second.upserts.map(\.id.providerID), ["F-ARCHIVE-2"])
        XCTAssertFalse(second.hasMore)
        let afterSecond = try GraphCursor.decode(second.cursor)
        XCTAssertNil(afterSecond.deltaLink(for: "F-ARCHIVE"))
        XCTAssertEqual(afterSecond.nextLinks, ["F-ARCHIVE": skipLink("F-ARCHIVE", "3")])

        StubURLProtocol.clearRequests()
        clock.advance(by: GraphCursor.fullVisitInterval)
        let third = try await provider.changes(since: second.cursor, limit: 25)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d2", "F-ARCHIVE skip 3"])
        XCTAssertEqual(third.upserts.map(\.id.providerID), ["F-ARCHIVE-3"])
        XCTAssertFalse(third.hasMore)
        let afterThird = try GraphCursor.decode(third.cursor)
        XCTAssertEqual(afterThird.deltaLink(for: "F-ARCHIVE"), deltaLink("F-ARCHIVE", "F-ARCHIVE-d1"))
        XCTAssertTrue(afterThird.nextLinks.isEmpty)

        StubURLProtocol.clearRequests()
        clock.advance(by: GraphCursor.fullVisitInterval)
        let fourth = try await provider.changes(since: third.cursor, limit: 25)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d2", "F-ARCHIVE delta F-ARCHIVE-d1"], "a seeded archive is polled like any folder")
        XCTAssertTrue(fourth.upserts.isEmpty)
        XCTAssertFalse(fourth.hasMore)
    }

    /// What a real account looks like after a bootstrap: the inbox's first round runs past `limit` while the
    /// archive seeds. The seed page counts toward the early stop, the inbox's nextLink alone keeps the engine
    /// calling, and every call of that loop still takes exactly one seed page.
    func testInboxFirstRoundPastTheLimitKeepsHasMoreWhileEachCallTakesOneSeedPage() async throws {
        routeSeeds(["F-INBOX": 3, "F-ARCHIVE": 4], perPage: 2)
        let provider = makeProvider()
        var current = try cursor(folders: ["F-INBOX": nil, "F-ARCHIVE": nil])
        var trails: [[String]] = []
        var upserts: [[String]] = []
        var hasMore: [Bool] = []
        var cursors: [GraphCursor] = []

        // Three calls is the engine's loop while hasMore holds; the fourth is the next poll.
        for _ in 0..<4 {
            StubURLProtocol.clearRequests()
            // Two items from the inbox stay under three, so only the seed page can end the first pass.
            let page = try await provider.changes(since: current, limit: 3)
            trails.append(trail())
            upserts.append(page.upserts.map(\.id.providerID))
            hasMore.append(page.hasMore)
            cursors.append(try GraphCursor.decode(page.cursor))
            current = page.cursor
        }

        XCTAssertEqual(trails, [
            ["F-INBOX seed", "F-ARCHIVE seed"],
            ["F-INBOX skip 2", "F-ARCHIVE skip 2"],
            ["F-INBOX skip 3", "F-ARCHIVE skip 3"],
            ["F-INBOX delta F-INBOX-d1", "F-ARCHIVE skip 4"],
        ])
        XCTAssertEqual(upserts[0], ["F-INBOX-1", "F-INBOX-1-2", "F-ARCHIVE-1", "F-ARCHIVE-1-2"], "the inbox's mail leads the page")
        XCTAssertEqual(hasMore, [true, true, false, false], "the inbox's nextLink holds the loop open; the archive's alone does not")
        XCTAssertEqual(cursors[0].nextLinks, ["F-INBOX": skipLink("F-INBOX", "2"), "F-ARCHIVE": skipLink("F-ARCHIVE", "2")])
        XCTAssertEqual(cursors[1].nextLinks, ["F-INBOX": skipLink("F-INBOX", "3"), "F-ARCHIVE": skipLink("F-ARCHIVE", "3")])
        XCTAssertNil(cursors[1].deltaLink(for: "F-INBOX"))
        XCTAssertEqual(cursors[2].deltaLink(for: "F-INBOX"), deltaLink("F-INBOX", "F-INBOX-d1"))
        XCTAssertEqual(cursors[2].nextLinks, ["F-ARCHIVE": skipLink("F-ARCHIVE", "4")])
        XCTAssertEqual(cursors[3].deltaLink(for: "F-ARCHIVE"), deltaLink("F-ARCHIVE", "F-ARCHIVE-d1"))
        XCTAssertTrue(cursors[3].nextLinks.isEmpty)
    }

    func testSeedingFoldersSeedOneAtATimeInFolderOrder() async throws {
        routeSeeds(["F-ARCHIVE": 2, "F-AAA": 1, "F-ZZZ": 1])
        // Polls a full visit apart, so a folder that has finished seeding is polled on the very next one.
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        var current = try cursor(folders: ["F-ZZZ": nil, "F-INBOX": deltaLink("F-INBOX", "F-INBOX-d1"), "F-AAA": nil, "F-ARCHIVE": nil])
        var trails: [[String]] = []

        for call in 0..<5 {
            StubURLProtocol.clearRequests()
            if call > 0 { clock.advance(by: GraphCursor.fullVisitInterval) }
            let page = try await provider.changes(since: current, limit: 25)
            XCTAssertFalse(page.hasMore)
            trails.append(trail())
            current = page.cursor
        }

        XCTAssertEqual(trails, [
            ["F-INBOX delta F-INBOX-d1", "F-ARCHIVE seed"],
            ["F-INBOX delta F-INBOX-d2", "F-ARCHIVE skip 2"],
            ["F-INBOX delta F-INBOX-d2", "F-ARCHIVE delta F-ARCHIVE-d1", "F-AAA seed"],
            ["F-INBOX delta F-INBOX-d2", "F-ARCHIVE delta F-ARCHIVE-d2", "F-AAA delta F-AAA-d1", "F-ZZZ seed"],
            ["F-INBOX delta F-INBOX-d2", "F-ARCHIVE delta F-ARCHIVE-d2", "F-AAA delta F-AAA-d2", "F-ZZZ delta F-ZZZ-d1"],
        ])
    }

    /// A folder that already has a delta link is drained as before, nextLinks and all, even while another folder
    /// is seeding; its nextLink left at the limit is what sets `hasMore`.
    func testSeededFolderOnNextLinkIsContinuedWithinTheCallAndSetsHasMore() async throws {
        route { request in
            guard request.method == "GET", request.path.hasSuffix("/messages/delta") else { return nil }
            let folder = self.folder(of: request)
            switch (folder, request.query["$deltatoken"], request.query["$skiptoken"]) {
            case ("F-INBOX", _, _):
                return .json(Fixtures.list([], deltaLink: self.deltaLink("F-INBOX", "F-INBOX-d2")))
            case ("F-ARCHIVE", "F-ARCHIVE-d1"?, _):
                return .json(Fixtures.list([Fixtures.message(id: "x1", folder: "F-ARCHIVE")], nextLink: self.skipLink("F-ARCHIVE", "inc-2")))
            case ("F-ARCHIVE", _, "inc-2"?):
                return .json(Fixtures.list([Fixtures.message(id: "x2", folder: "F-ARCHIVE")], nextLink: self.skipLink("F-ARCHIVE", "inc-3")))
            case ("F-ARCHIVE", _, "inc-3"?):
                return .json(Fixtures.list([Fixtures.message(id: "x3", folder: "F-ARCHIVE")], deltaLink: self.deltaLink("F-ARCHIVE", "F-ARCHIVE-d2")))
            case ("F-AAA", nil, nil):
                return .json(Fixtures.list([Fixtures.message(id: "a1", folder: "F-AAA")], nextLink: self.skipLink("F-AAA", "2")))
            case ("F-AAA", nil, "2"?):
                return .json(Fixtures.list([Fixtures.message(id: "a2", folder: "F-AAA")], deltaLink: self.deltaLink("F-AAA", "F-AAA-d1")))
            default:
                return nil
            }
        }
        let provider = makeProvider()
        let start = try cursor(folders: [
            "F-INBOX": deltaLink("F-INBOX", "F-INBOX-d1"), "F-ARCHIVE": deltaLink("F-ARCHIVE", "F-ARCHIVE-d1"), "F-AAA": nil,
        ])

        // Two items after the first pass stay under the limit of three, so the archive goes on; the seeding
        // folder has spent its page and does not.
        let first = try await provider.changes(since: start, limit: 3)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d1", "F-ARCHIVE delta F-ARCHIVE-d1", "F-AAA seed", "F-ARCHIVE skip inc-2"])
        XCTAssertEqual(first.upserts.map(\.id.providerID), ["x1", "a1", "x2"])
        XCTAssertTrue(first.hasMore, "the archive stopped on a nextLink at the limit")
        let afterFirst = try GraphCursor.decode(first.cursor)
        XCTAssertEqual(afterFirst.deltaLink(for: "F-ARCHIVE"), deltaLink("F-ARCHIVE", "F-ARCHIVE-d1"), "the old delta link stays until the round ends")
        XCTAssertEqual(afterFirst.nextLinks, ["F-ARCHIVE": skipLink("F-ARCHIVE", "inc-3"), "F-AAA": skipLink("F-AAA", "2")])

        StubURLProtocol.clearRequests()
        let second = try await provider.changes(since: first.cursor, limit: 3)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d2", "F-ARCHIVE skip inc-3", "F-AAA skip 2"])
        XCTAssertEqual(second.upserts.map(\.id.providerID), ["x3", "a2"])
        XCTAssertFalse(second.hasMore)
        let afterSecond = try GraphCursor.decode(second.cursor)
        XCTAssertEqual(afterSecond.deltaLink(for: "F-ARCHIVE"), deltaLink("F-ARCHIVE", "F-ARCHIVE-d2"))
        XCTAssertEqual(afterSecond.deltaLink(for: "F-AAA"), deltaLink("F-AAA", "F-AAA-d1"))
        XCTAssertTrue(afterSecond.nextLinks.isEmpty)
    }

    /// A seeding folder's nextLink alone never sets `hasMore`, even when its page fills the limit: the engine's
    /// poll ends and the next poll continues it.
    func testSeedingLeftOverAloneDoesNotSetHasMore() async throws {
        routeSeeds(["F-PROJECTS": 3])

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": deltaLink("F-INBOX", "F-INBOX-d1"), "F-PROJECTS": nil]), limit: 1)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d1", "F-PROJECTS seed"])
        XCTAssertEqual(page.upserts.map(\.id.providerID), ["F-PROJECTS-1"])
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(try GraphCursor.decode(page.cursor).nextLinks, ["F-PROJECTS": skipLink("F-PROJECTS", "2")])
    }

    // MARK: Full visits

    /// The folders of the delta requests sent so far, in order.
    private func polledFolders() -> [String] {
        requests.filter { $0.path.hasSuffix("/messages/delta") }.map { folder(of: $0) }
    }

    /// The live lane polls every 5 s. Between full visits only the inbox, sent and drafts are asked; the archive
    /// and a custom folder, quiet on their delta links, are asked again once the interval since the last full
    /// visit has run out.
    func testOtherFoldersOnADeltaLinkArePolledOnlyOnFullVisits() async throws {
        routeSeeds([:])
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        let everyFolder = ["F-INBOX", "F-SENT", "F-DRAFTS", "F-ARCHIVE", "F-PROJECTS"]
        let priorityOnly = ["F-INBOX", "F-SENT", "F-DRAFTS"]
        var current = try cursor(folders: Dictionary(uniqueKeysWithValues: everyFolder.map { ($0, deltaLink($0, "\($0)-d1")) }))
        var polled: [[String]] = []
        var stamps: [String?] = []
        var archiveLinks: [String?] = []

        // Seconds since the first call: 5 s apart, then up to the interval's edge, onto it and past it.
        for elapsed: TimeInterval in [0, 5, 25, 29, 30, 35] {
            StubURLProtocol.clearRequests()
            clock.advance(by: now.addingTimeInterval(elapsed).timeIntervalSince(clock.now))
            let page = try await provider.changes(since: current, limit: 25)
            XCTAssertFalse(page.hasMore)
            polled.append(polledFolders())
            let next = try GraphCursor.decode(page.cursor)
            stamps.append(next.fullVisitAt)
            archiveLinks.append(next.deltaLink(for: "F-ARCHIVE"))
            current = page.cursor
        }

        XCTAssertEqual(polled, [everyFolder, priorityOnly, priorityOnly, priorityOnly, everyFolder, priorityOnly])
        XCTAssertEqual(
            stamps,
            [nowString, nowString, nowString, nowString, "2026-11-01T10:00:30Z", "2026-11-01T10:00:30Z"],
            "only a full visit moves the stamp, so the interval runs from the last one"
        )
        let afterFirst = deltaLink("F-ARCHIVE", "F-ARCHIVE-d2")
        XCTAssertEqual(archiveLinks, Array(repeating: afterFirst, count: 6), "a skipped folder keeps its delta link")
    }

    /// Cursors stored before polls were thinned carry no full-visit time: they decode with their delta links
    /// intact and their next call polls every folder. (This one carries the walked-tree marker, so the call is
    /// about the visit alone, not the folder walk such a cursor also starts.)
    func testCursorStoredWithoutFullVisitTimeVisitsEveryFolder() async throws {
        routeSeeds([:])
        let folders = [
            #""F-ARCHIVE":"\#(deltaLink("F-ARCHIVE", "F-ARCHIVE-d1"))""#,
            #""F-INBOX":"\#(deltaLink("F-INBOX", "F-INBOX-d1"))""#,
            #""F-PROJECTS":"\#(deltaLink("F-PROJECTS", "F-PROJECTS-d1"))""#,
        ].joined(separator: ",")
        let stored = #"{"deltaScope":"mailbox","folderScope":"tree","folders":{\#(folders)},"foldersResolvedAt":"\#(nowString)","nextLinks":{},"since":"\#(nowString)","wellKnown":{"archive":"F-ARCHIVE","inbox":"F-INBOX"}}"#
        let decoded = try GraphCursor.decode(stored)
        XCTAssertNil(decoded.fullVisitAt)
        XCTAssertEqual(decoded.deltaLink(for: "F-PROJECTS"), deltaLink("F-PROJECTS", "F-PROJECTS-d1"))
        let provider = makeProvider()

        let page = try await provider.changes(since: stored, limit: 25)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d1", "F-ARCHIVE delta F-ARCHIVE-d1", "F-PROJECTS delta F-PROJECTS-d1"])
        XCTAssertEqual(try GraphCursor.decode(page.cursor).fullVisitAt, nowString)

        StubURLProtocol.clearRequests()
        _ = try await provider.changes(since: page.cursor, limit: 25)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d2"], "the stamp it now carries thins the next call")
    }

    func testFullVisitIsDueWithoutAReadableStampAndWhenTheClockWentBack() {
        var cursor = GraphCursor(folders: [:], wellKnown: [:], since: nowString)
        XCTAssertTrue(cursor.needsFullVisit(at: now))
        cursor.fullVisitAt = nowString
        XCTAssertFalse(cursor.needsFullVisit(at: now))
        XCTAssertFalse(cursor.needsFullVisit(at: now.addingTimeInterval(GraphCursor.fullVisitInterval - 1)))
        XCTAssertTrue(cursor.needsFullVisit(at: now.addingTimeInterval(GraphCursor.fullVisitInterval)))
        XCTAssertTrue(cursor.needsFullVisit(at: now.addingTimeInterval(-60)), "a clock set back must not starve the folders")
        cursor.fullVisitAt = "garbage"
        XCTAssertTrue(cursor.needsFullVisit(at: now))
    }

    /// A folder partway through a round is continued on every call, priority or not, and the engine's further
    /// calls while `hasMore` holds do not ask the quiet folders again.
    func testFolderOnANextLinkIsContinuedBetweenFullVisits() async throws {
        route { request in
            guard request.method == "GET", request.path.hasSuffix("/messages/delta") else { return nil }
            let folder = self.folder(of: request)
            switch (folder, request.query["$deltatoken"], request.query["$skiptoken"]) {
            case ("F-ARCHIVE", "F-ARCHIVE-d1"?, _):
                return .json(Fixtures.list([Fixtures.message(id: "x1", folder: "F-ARCHIVE")], nextLink: self.skipLink("F-ARCHIVE", "inc-2")))
            case ("F-ARCHIVE", _, "inc-2"?):
                return .json(Fixtures.list([Fixtures.message(id: "x2", folder: "F-ARCHIVE")], deltaLink: self.deltaLink("F-ARCHIVE", "F-ARCHIVE-d2")))
            case (_, _?, nil):
                return .json(Fixtures.list([], deltaLink: self.deltaLink(folder, "\(folder)-d2")))
            default:
                return nil
            }
        }
        let provider = makeProvider()
        let start = try cursor(folders: [
            "F-INBOX": deltaLink("F-INBOX", "F-INBOX-d1"),
            "F-ARCHIVE": deltaLink("F-ARCHIVE", "F-ARCHIVE-d1"),
            "F-PROJECTS": deltaLink("F-PROJECTS", "F-PROJECTS-d1"),
        ])

        let first = try await provider.changes(since: start, limit: 1)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d1", "F-ARCHIVE delta F-ARCHIVE-d1", "F-PROJECTS delta F-PROJECTS-d1"])
        XCTAssertTrue(first.hasMore, "the archive stopped on a nextLink at the limit")

        StubURLProtocol.clearRequests()
        let second = try await provider.changes(since: first.cursor, limit: 1)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d2", "F-ARCHIVE skip inc-2"])
        XCTAssertEqual(second.upserts.map(\.id.providerID), ["x2"])
        XCTAssertFalse(second.hasMore)
        let afterSecond = try GraphCursor.decode(second.cursor)
        XCTAssertEqual(afterSecond.deltaLink(for: "F-ARCHIVE"), deltaLink("F-ARCHIVE", "F-ARCHIVE-d2"))
        XCTAssertEqual(afterSecond.deltaLink(for: "F-PROJECTS"), deltaLink("F-PROJECTS", "F-PROJECTS-d2"))
        XCTAssertTrue(afterSecond.nextLinks.isEmpty)
    }

    /// Seeding keeps its page per call between full visits; a folder that finishes seeding then waits for the
    /// next full visit like any other folder on a delta link.
    func testSeedingGoesOnBetweenFullVisits() async throws {
        routeSeeds(["F-AAA": 2])
        let clock = StepClock(now.addingTimeInterval(5))
        let provider = makeProvider(clock: clock)
        var current = try cursor(
            folders: ["F-INBOX": deltaLink("F-INBOX", "F-INBOX-d1"), "F-ARCHIVE": deltaLink("F-ARCHIVE", "F-ARCHIVE-d1"), "F-AAA": nil],
            fullVisitAt: nowString
        )
        var trails: [[String]] = []

        // 5, 10, 15 and 30 s after the last full visit.
        for step: TimeInterval in [0, 5, 5, 15] {
            StubURLProtocol.clearRequests()
            clock.advance(by: step)
            let page = try await provider.changes(since: current, limit: 25)
            XCTAssertFalse(page.hasMore)
            trails.append(trail())
            current = page.cursor
        }

        XCTAssertEqual(trails, [
            ["F-INBOX delta F-INBOX-d1", "F-AAA seed"],
            ["F-INBOX delta F-INBOX-d2", "F-AAA skip 2"],
            ["F-INBOX delta F-INBOX-d2"],
            ["F-INBOX delta F-INBOX-d2", "F-ARCHIVE delta F-ARCHIVE-d1", "F-AAA delta F-AAA-d1"],
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

    /// A delta can report a read message with only what changed. Stored whole it became “No sender · No subject”
    /// dated 1970; its metadata is looked up instead, and a message gone since is simply left out.
    func testAPartialChangeIsLookedUpNotStoredBlank() async throws {
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list([
                    #"{"id":"m-read","isRead":true}"#,
                    #"{"id":"m-gone","isRead":true}"#,
                ], deltaLink: self.inboxLink))
            }
            return self.batchReply(request) { id, url in
                if url.contains("m-gone") {
                    return Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError)
                }
                return Fixtures.BatchItem(id: id, status: 200, body: Fixtures.message(id: "m-read", folder: "F-INBOX"))
            }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil]), limit: 50)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-read"])
        XCTAssertNotEqual(page.upserts.first?.date, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(page.deletedIDs, [], "a partial change is no deletion")
        XCTAssertEqual(innerBatchRequests().map { $0["url"] as? String }, [
            "/me/messages/m-read?$select=\(GraphProvider.metadataSelect)",
            "/me/messages/m-gone?$select=\(GraphProvider.metadataSelect)",
        ])
    }

    /// A partial change Graph will not look up keeps what the store has, and the cursor moves on.
    func testAPartialChangeGraphWillNotReturnKeepsWhatTheStoreHas() async throws {
        let internalError = #"{"error":{"code":"ErrorInternalServerError","message":"An internal server error occurred."}}"#
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list([
                    #"{"id":"m-broken","isRead":true}"#,
                    Fixtures.message(id: "m-new", folder: "F-INBOX"),
                ], deltaLink: self.inboxLink))
            }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 500, body: internalError) }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil]), limit: 50)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-new"])
        XCTAssertEqual(page.deletedIDs, [])
        XCTAssertEqual(try GraphCursor.decode(page.cursor).deltaLink(for: "F-INBOX"), inboxLink)
    }

    /// One removal Graph would not look up (seen live: 403 ErrorAccessDenied) failed the whole call, so the cursor
    /// never moved and every poll met the same message: the account stopped syncing for good. It is taken as gone
    /// now and the cursor moves on.
    func testARemovalGraphWillNotReturnDoesNotStopThePoll() async throws {
        let accessDenied = #"{"error":{"code":"ErrorAccessDenied","message":"Access is denied. Check credentials and try again."}}"#
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list([
                    Fixtures.removed("r-denied"),
                    Fixtures.message(id: "m-new", folder: "F-INBOX"),
                ], deltaLink: self.inboxLink))
            }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 403, body: accessDenied) }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil]), limit: 50)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-new"])
        XCTAssertEqual(page.deletedIDs, ["r-denied"])
        XCTAssertEqual(try GraphCursor.decode(page.cursor).deltaLink(for: "F-INBOX"), inboxLink)
    }

    /// A throttle or a refused token in a lookup is the mailbox's, not the message's: the call still fails and the
    /// cursor stays, so nothing is lost.
    func testAThrottledLookupStillFailsThePoll() async throws {
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list([Fixtures.removed("r-1")], deltaLink: self.inboxLink))
            }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 429, headers: ["Retry-After": "7"]) }
        }
        let start = try cursor(folders: ["F-INBOX": nil])
        await expectProviderError({ try await self.makeProvider().changes(since: start, limit: 50) }) { $0.retryAfter == 7 }
    }

    /// Through Exchange's November 2026 outage a lookup part answered 502 now and then. Taken as gone, a message that was
    /// only moved (a snooze's archive) was deleted here, its snooze and body with it. Only a 404 is gone: the message is
    /// left as the store has it and looked up again on the next call, which finds where it went.
    func testARemovalTheServiceFailsToLookUpIsAskedAgainNotDeleted() async throws {
        var lookupsWork = false
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                if request.query["$deltatoken"] != nil { return .json(Fixtures.list([], deltaLink: self.inboxLink2)) }
                return .json(Fixtures.list([
                    Fixtures.removed("r-moved"),
                    Fixtures.message(id: "m-new", folder: "F-INBOX"),
                ], deltaLink: self.inboxLink))
            }
            return self.batchReply(request) { id, _ in
                lookupsWork
                    ? Fixtures.BatchItem(id: id, status: 200, body: Fixtures.message(id: "r-moved", folder: "F-ARCHIVE"))
                    : Fixtures.BatchItem(id: id, status: 502, body: #"{"error":{"code":"UnknownError","message":""}}"#)
            }
        }
        let provider = makeProvider()

        let first = try await provider.changes(since: try cursor(folders: ["F-INBOX": nil]), limit: 50)
        XCTAssertEqual(first.upserts.map(\.id.providerID), ["m-new"])
        XCTAssertEqual(first.deletedIDs, [], "a lookup the service failed says nothing about the message")
        let carried = try GraphCursor.decode(first.cursor)
        XCTAssertEqual(carried.deltaLink(for: "F-INBOX"), inboxLink, "the delta moves on")
        XCTAssertEqual(carried.recheck, ["r-moved": 1])

        lookupsWork = true
        let second = try await provider.changes(since: first.cursor, limit: 50)
        XCTAssertEqual(second.upserts.map(\.id.providerID), ["r-moved"])
        XCTAssertEqual(second.upserts.first?.folderID, "F-ARCHIVE")
        XCTAssertEqual(second.deletedIDs, [])
        XCTAssertEqual(try GraphCursor.decode(second.cursor).recheck, [:])
        XCTAssertFalse(second.cursor.contains("recheck"), "a cursor with nothing to look up again does not grow")
    }

    /// A lookup part answering 503 or 504 failed the whole call, so the inbox's new mail was fetched and thrown away on
    /// every poll while removals were pending. The new mail lands now and the lookup waits for the next call.
    func testALookupPartTheServiceFailsNoLongerHoldsNewMail() async throws {
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list([
                    Fixtures.removed("r-1"),
                    Fixtures.message(id: "m-new", folder: "F-INBOX"),
                ], deltaLink: self.inboxLink))
            }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 503) }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil]), limit: 50)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-new"])
        XCTAssertEqual(page.deletedIDs, [])
        XCTAssertEqual(try GraphCursor.decode(page.cursor).recheck, ["r-1": 1])
    }

    /// The same when the `$batch` envelope itself fails for now.
    func testALookupWhoseWholeBatchTheServiceFailsIsAskedAgain() async throws {
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list([
                    Fixtures.removed("r-1"),
                    #"{"id":"m-read","isRead":true}"#,
                    Fixtures.message(id: "m-new", folder: "F-INBOX"),
                ], deltaLink: self.inboxLink))
            }
            return request.path == "/v1.0/$batch" ? .status(504) : nil
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil]), limit: 50)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-new"])
        XCTAssertEqual(page.deletedIDs, [])
        XCTAssertEqual(try GraphCursor.decode(page.cursor).recheck, ["r-1": 1, "m-read": 1])
    }

    /// A read flag set on the phone was dropped for good when its lookup answered 502: the delta link moved past it.
    func testAPartialChangeTheServiceFailsIsLookedUpAgain() async throws {
        var lookupsWork = false
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                if request.query["$deltatoken"] != nil { return .json(Fixtures.list([], deltaLink: self.inboxLink2)) }
                return .json(Fixtures.list([#"{"id":"m-read","isRead":true}"#], deltaLink: self.inboxLink))
            }
            return self.batchReply(request) { id, _ in
                lookupsWork
                    ? Fixtures.BatchItem(id: id, status: 200, body: Fixtures.message(id: "m-read", folder: "F-INBOX"))
                    : Fixtures.BatchItem(id: id, status: 502)
            }
        }
        let provider = makeProvider()

        let first = try await provider.changes(since: try cursor(folders: ["F-INBOX": nil]), limit: 50)
        XCTAssertEqual(first.upserts.map(\.id.providerID), [])
        lookupsWork = true
        let second = try await provider.changes(since: first.cursor, limit: 50)
        XCTAssertEqual(second.upserts.map(\.id.providerID), ["m-read"])
    }

    /// A message whose lookup keeps failing is not carried for ever: after three calls it is left as the store has it,
    /// never deleted for a failure that says nothing about it.
    func testALookupThatKeepsFailingIsLeftAsTheStoreHasIt() async throws {
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list([], deltaLink: self.inboxLink2))
            }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 503) }
        }
        var start = try GraphCursor.decode(try cursor(folders: ["F-INBOX": inboxLink]))
        start.recheck = ["r-1": 2]

        let page = try await makeProvider().changes(since: try start.encoded(), limit: 50)

        XCTAssertEqual(page.deletedIDs, [])
        XCTAssertEqual(page.upserts.map(\.id.providerID), [])
        XCTAssertEqual(try GraphCursor.decode(page.cursor).recheck, [:])
        XCTAssertEqual(innerBatchRequests().count, 1, "asked once more before giving up")
    }

    /// Looked up again, a message Graph no longer has is gone; one another folder reported meanwhile needs no lookup.
    func testACarriedLookupSettlesAsADeletionOrThroughAnotherFolder() async throws {
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list([Fixtures.message(id: "m-found", folder: "F-INBOX")], deltaLink: self.inboxLink2))
            }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError) }
        }
        var start = try GraphCursor.decode(try cursor(folders: ["F-INBOX": inboxLink]))
        start.recheck = ["r-gone": 1, "m-found": 1]

        let page = try await makeProvider().changes(since: try start.encoded(), limit: 50)

        XCTAssertEqual(page.deletedIDs, ["r-gone"])
        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-found"])
        XCTAssertEqual(innerBatchRequests().map { $0["url"] as? String }, ["/me/messages/r-gone?$select=\(GraphProvider.metadataSelect)"])
        XCTAssertEqual(try GraphCursor.decode(page.cursor).recheck, [:])
    }

    // MARK: Requests sent

    /// A quiet poll between full visits asks the inbox, sent and drafts, and says so: three requests, which the
    /// engine charges to its share of the mailbox's limit.
    func testAPollReportsTheDeltaRequestsItSent() async throws {
        routeSeeds([:])
        let everyFolder = ["F-INBOX", "F-SENT", "F-DRAFTS", "F-ARCHIVE", "F-PROJECTS"]
        let start = try cursor(folders: Dictionary(uniqueKeysWithValues: everyFolder.map { ($0, deltaLink($0, "\($0)-d1")) }),
                               fullVisitAt: nowString)

        let page = try await makeProvider(now: now.addingTimeInterval(5)).changes(since: start, limit: 25)

        XCTAssertEqual(polledFolders(), ["F-INBOX", "F-SENT", "F-DRAFTS"])
        XCTAssertEqual(page.requestCount, 3)
    }

    /// Graph counts each part of a `$batch` on its own, so every removal looked up is a request: one delta GET and
    /// 25 lookups in two envelopes make 26, not the three round trips.
    func testEachRemovalLookedUpCountsAsARequest() async throws {
        let gone = (1...25).map { "r-\($0)" }
        route { request in
            if request.method == "GET", request.path == self.inboxDelta {
                return .json(Fixtures.list(gone.map(Fixtures.removed), deltaLink: self.inboxLink))
            }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError) }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": nil]), limit: 50)

        XCTAssertEqual(page.deletedIDs, gone)
        XCTAssertEqual(requests.count, 3, "one delta GET and two envelopes of up to 20")
        XCTAssertEqual(page.requestCount, 26)
    }

    /// A request answered 401 and sent again with a fresh token counts twice: both reached Graph.
    func testARequestSentAgainAfterA401CountsTwice() async throws {
        tokens = StubTokenProvider(tokens: ["stale", "fresh"])
        route { request in
            guard request.method == "GET", request.path == self.inboxDelta else { return nil }
            return request.header("Authorization") == "Bearer stale"
                ? .json(#"{"error":{"code":"InvalidAuthenticationToken","message":"Access token has expired."}}"#, status: 401)
                : .json(Fixtures.list([], deltaLink: self.inboxLink2))
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": inboxLink]), limit: 25)

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(page.requestCount, 2)
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

    /// Exchange's November 2026 outage: the inbox answered, one folder kept failing with a 502, and the whole call
    /// failed with it, throwing the inbox's new mail away on every poll. That folder now waits for the next call.
    func testAFolderTheServiceFailsWaitsWhileTheOthersSync() async throws {
        let badGateway = #"{"error":{"code":"UnknownError","message":""}}"#
        route { request in
            guard request.method == "GET" else { return nil }
            switch request.path {
            case self.inboxDelta:
                return .json(Fixtures.list([Fixtures.message(id: "m-new", folder: "F-INBOX")], deltaLink: self.inboxLink2))
            case self.sentDelta:
                return .json(badGateway, status: 502)
            default:
                return nil
            }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": inboxLink, "F-SENT": sentLink]), limit: 50)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-new"])
        let after = try GraphCursor.decode(page.cursor)
        XCTAssertEqual(after.deltaLink(for: "F-INBOX"), inboxLink2)
        XCTAssertEqual(after.deltaLink(for: "F-SENT"), sentLink, "the failed folder is asked again from where it was")
    }

    /// The inbox is what the user waits on: when the service fails it, the call fails and the account says so.
    func testTheInboxFailingStillFailsThePoll() async throws {
        route { request in
            guard request.method == "GET" else { return nil }
            switch request.path {
            case self.inboxDelta: return .status(504)
            case self.sentDelta: return .json(Fixtures.list([], deltaLink: self.sentLink2))
            default: return nil
            }
        }
        let start = try cursor(folders: ["F-INBOX": inboxLink, "F-SENT": sentLink])
        await expectProviderError({ try await self.makeProvider().changes(since: start, limit: 50) }) {
            if case .network = $0 { return true }
            return false
        }
    }

    /// No folder answering is the service down, not a folder: the call fails rather than report nothing new.
    func testEveryFolderFailingStillFailsThePoll() async throws {
        route { request in
            request.method == "GET" && request.path.hasSuffix("/messages/delta") ? .status(500) : nil
        }
        let start = try cursor(folders: ["F-SENT": sentLink, "F-AAA": deltaLink("F-AAA", "a1")], fullVisitAt: "2000-01-01T00:00:00Z")
        await expectProviderError({ try await self.makeProvider().changes(since: start, limit: 50) }) {
            if case .server(500, _) = $0 { return true }
            return false
        }
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
        XCTAssertEqual(page.goneFolders, ["F-OLD"], "its stored mail is the engine's to check: no delta will report it")
    }

    /// A folder whose delta Graph refuses (403 ErrorAccessDenied, a 400 on its stored link) failed the whole call on
    /// every poll, the inbox's new mail thrown away each time. It waits now, as a folder the service fails does.
    func testAFolderThatRefusesItsDeltaWaitsWhileTheOthersSync() async throws {
        route { request in
            guard request.method == "GET" else { return nil }
            switch request.path {
            case self.inboxDelta:
                return .json(Fixtures.list([Fixtures.message(id: "m-new", folder: "F-INBOX")], deltaLink: self.inboxLink2))
            case self.sentDelta:
                return .json(#"{"error":{"code":"ErrorAccessDenied","message":"Access is denied."}}"#, status: 403)
            default:
                return nil
            }
        }

        let page = try await makeProvider().changes(since: try cursor(folders: ["F-INBOX": inboxLink, "F-SENT": sentLink]), limit: 50)

        XCTAssertEqual(page.upserts.map(\.id.providerID), ["m-new"])
        let after = try GraphCursor.decode(page.cursor)
        XCTAssertEqual(after.deltaLink(for: "F-INBOX"), inboxLink2)
        XCTAssertEqual(after.deltaLink(for: "F-SENT"), sentLink)
        XCTAssertEqual(after.folderFailures, ["F-SENT": 1])
    }

    /// A folder refused three calls in a row starts a fresh round (its stored link may be what Graph refuses) and is
    /// asked only on full visits until it answers, so it costs a request every 30 s rather than one every poll.
    func testAFolderRefusedThreeCallsInARowStartsAFreshRoundOnFullVisits() async throws {
        var refusing = true
        route { request in
            guard request.method == "GET", request.path.hasSuffix("/messages/delta") else { return nil }
            let folder = self.folder(of: request)
            if folder == "F-AAA" {
                if refusing || request.query["$deltatoken"] != nil {
                    return .json(#"{"error":{"code":"ErrorInvalidRequest","message":"bad link"}}"#, status: 400)
                }
                return .json(Fixtures.list([Fixtures.message(id: "m-aaa", folder: "F-AAA")], deltaLink: self.deltaLink("F-AAA", "fresh")))
            }
            return .json(Fixtures.list([], deltaLink: self.deltaLink(folder, "\(folder)-d2")))
        }
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        var start = try GraphCursor.decode(try cursor(
            folders: ["F-INBOX": deltaLink("F-INBOX", "F-INBOX-d1"), "F-AAA": deltaLink("F-AAA", "a1")],
            fullVisitAt: "2000-01-01T00:00:00Z"
        ))
        start.folderFailures = ["F-AAA": 2]

        let first = try await provider.changes(since: try start.encoded(), limit: 50)
        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d1", "F-AAA delta a1"])
        let parked = try GraphCursor.decode(first.cursor)
        XCTAssertEqual(parked.folderFailures, ["F-AAA": 3])
        XCTAssertTrue(parked.folders.keys.contains("F-AAA"))
        XCTAssertNil(parked.deltaLink(for: "F-AAA"), "the refused link is dropped")

        StubURLProtocol.clearRequests()
        clock.advance(by: 5)
        let second = try await provider.changes(since: first.cursor, limit: 50)
        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d2"], "not asked between full visits, not even for a seed page")

        StubURLProtocol.clearRequests()
        refusing = false
        clock.advance(by: GraphCursor.fullVisitInterval)
        let third = try await provider.changes(since: second.cursor, limit: 50)
        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d2", "F-AAA seed"])
        XCTAssertEqual(third.upserts.map(\.id.providerID), ["m-aaa"])
        let recovered = try GraphCursor.decode(third.cursor)
        XCTAssertEqual(recovered.folderFailures, [:])
        XCTAssertEqual(recovered.deltaLink(for: "F-AAA"), deltaLink("F-AAA", "fresh"))
        XCTAssertFalse(third.cursor.contains("folderFailures"))
    }

    /// Each call's seed page went to the first folder still seeding; one whose page kept failing took it every time, so
    /// no folder after it was ever seeded or polled. A folder that failed waits behind those that did not.
    func testASeedThatKeepsFailingNoLongerHoldsBackTheOtherSeeds() async throws {
        route { request in
            guard request.method == "GET", request.path.hasSuffix("/messages/delta") else { return nil }
            switch self.folder(of: request) {
            case "F-AAA": return .status(500)
            case "F-BBB": return .json(Fixtures.list([Fixtures.message(id: "m-b", folder: "F-BBB")], deltaLink: self.deltaLink("F-BBB", "b1")))
            case let folder: return .json(Fixtures.list([], deltaLink: self.deltaLink(folder, "\(folder)-d2")))
            }
        }
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)
        let start = try cursor(folders: ["F-INBOX": deltaLink("F-INBOX", "F-INBOX-d1"), "F-AAA": nil, "F-BBB": nil],
                               fullVisitAt: nowString)

        let first = try await provider.changes(since: start, limit: 50)
        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d1", "F-AAA seed"])
        StubURLProtocol.clearRequests()
        clock.advance(by: 5)
        let second = try await provider.changes(since: first.cursor, limit: 50)

        XCTAssertEqual(trail(), ["F-INBOX delta F-INBOX-d2", "F-BBB seed"])
        XCTAssertEqual(second.upserts.map(\.id.providerID), ["m-b"])
        XCTAssertEqual(try GraphCursor.decode(second.cursor).folderFailures, ["F-AAA": 1])
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
        let provider = makeProvider()
        // Delta requests that start a folder's first round, in the order they went out.
        func seedPaths() -> [String] {
            requests.filter { $0.path.hasSuffix("/messages/delta") && $0.query["$deltatoken"] == nil }.map(\.path)
        }

        let page = try await provider.changes(since: stale, limit: 10)

        let next = try GraphCursor.decode(page.cursor)
        XCTAssertEqual(next.foldersResolvedAt, nowString)
        XCTAssertEqual(Set(next.folders.keys), ["F-INBOX", "F-NEW", "F-SENT", "F-DRAFTS", "F-TRASH", "F-JUNK", "F-ARCHIVE", "F-GONE"])
        XCTAssertNil(next.deltaLink(for: "F-NEW"), "a new custom folder waits for the seeding folders ahead of it")
        XCTAssertEqual(next.deltaLink(for: "F-INBOX"), inboxLink2)
        XCTAssertEqual(next.wellKnown, Fixtures.folderIDs)
        XCTAssertEqual(requests(to: inboxDelta).first?.query["$deltatoken"], "inbox-d1", "a folder that survives keeps its delta link")
        XCTAssertEqual(next.missed, ["F-GONE"], "a folder the walk did not find is kept until a second walk misses it")
        XCTAssertEqual(seedPaths(), [sentDelta, deltaPath("F-DRAFTS"), deltaPath("F-TRASH")], "sent and drafts drain; trash takes the one seed page")
        XCTAssertTrue(page.upserts.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.requestCount, requests.count, "the folder lookups of the refresh count too")
        XCTAssertGreaterThan(requests.count, requests.filter { $0.path.hasSuffix("/messages/delta") }.count)

        // Junk and archive come before the new folder in folder order; each poll seeds one of them.
        var latest = page
        var laterSeeds: [String] = []
        for _ in 0..<3 {
            StubURLProtocol.clearRequests()
            latest = try await provider.changes(since: latest.cursor, limit: 10)
            laterSeeds += seedPaths()
            XCTAssertFalse(latest.hasMore)
        }
        XCTAssertEqual(laterSeeds, [deltaPath("F-JUNK"), deltaPath("F-ARCHIVE"), deltaPath("F-NEW")])
        XCTAssertNil(requests(to: "/v1.0/me/mailFolders/F-NEW/messages/delta").first?.query["$filter"])
        XCTAssertEqual(latest.upserts.map(\.id.providerID), ["m-n"])
        XCTAssertEqual(try GraphCursor.decode(latest.cursor).deltaLink(for: "F-NEW"), newLink)
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

    /// Cursors written before deltas tracked the whole mailbox carry deltaLinks scoped to
    /// `receivedDateTime ge <bootstrap start>`; Graph keeps that scope in the token, so they are dropped and
    /// every folder is seeded again without a filter. (The walked-tree marker keeps this call about the links, not
    /// the folder walk such a cursor also starts.)
    func testLegacyFilteredCursorIsReseededWithoutFilter() async throws {
        route { request in
            guard request.method == "GET", request.path == self.inboxDelta else { return nil }
            if request.query["$deltatoken"] != nil {
                return .json(Fixtures.list([], deltaLink: self.inboxLink2))
            }
            return .json(Fixtures.list([Fixtures.message(id: "old", folder: "F-INBOX", received: "2025-01-01T09:00:00Z")], deltaLink: self.inboxLink))
        }
        let legacy = #"{"folderScope":"tree","folders":{"F-INBOX":"\#(inboxLink)"},"nextLinks":{},"wellKnown":{"inbox":"F-INBOX"},"since":"\#(nowString)","foldersResolvedAt":"\#(nowString)"}"#

        let page = try await makeProvider().changes(since: legacy, limit: 50)

        let seed = try XCTUnwrap(requests(to: inboxDelta).first)
        XCTAssertNil(seed.query["$deltatoken"], "the filtered delta link must not be reused")
        XCTAssertNil(seed.query["$filter"])
        XCTAssertEqual(page.upserts.map(\.id.providerID), ["old"], "mail received before the account was added is tracked")
        let next = try GraphCursor.decode(page.cursor)
        XCTAssertEqual(next.deltaLink(for: "F-INBOX"), inboxLink)
        StubURLProtocol.clearRequests()
        _ = try await makeProvider().changes(since: page.cursor, limit: 50)
        XCTAssertEqual(requests(to: inboxDelta).first?.query["$deltatoken"], "inbox-d1", "a reseeded cursor keeps its links")
    }
}
