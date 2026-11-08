import XCTest
import SSCore

/// The `MailStoring` contract for a search's server matches (roadmap Q3.1, `ConversationQuery.serverMatches`): the
/// conversations a search of the server found join the full-text hits whatever their stored text says, under the
/// view's other rules and the search's operators on the row. Written as an extension so `SQLiteMailStoreContractTests` holds the SQLite store to it too.
extension MailStoreContractTests {
    private func searchQuery(_ text: String, matches: Set<ConversationID> = [], accounts: [AccountID]? = nil) -> ConversationQuery {
        ConversationQuery(accountIDs: accounts, view: .all, searchText: text, limit: 100, serverMatches: matches)
    }

    func testServerMatchesJoinTheFullTextHitsInDateOrder() throws {
        try store.upsertMessages([
            message("local", in: "t-local", subject: "Lisbon in March", date: date(30)),
            // The server matched words in a body this Mac has not downloaded: nothing stored says “lisbon”.
            message("found-new", in: "t-found-new", subject: "Photos", date: date(60)),
            message("found-old", in: "t-found-old", subject: "Receipt", date: date(10)),
            message("other", in: "t-other", subject: "Unrelated", date: date(20)),
        ])
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon")), ["t-local"], "without matches only the stored text counts")

        let found: Set<ConversationID> = [ConversationID(accountID: accountA, providerID: "t-found-new"),
                                          ConversationID(accountID: accountA, providerID: "t-found-old"),
                                          ConversationID(accountID: accountA, providerID: "t-local")]
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon", matches: found)), ["t-found-new", "t-local", "t-found-old"],
                       "found conversations list among the local hits, newest first, each once")
    }

    func testServerMatchesKeepTheViewsAndScopesRules() throws {
        try store.upsertMessages([
            message("in-trash", in: "t-trash", subject: "Old", date: date(10), roles: [.trash]),
            message("b-found", in: "t-b", account: accountB, subject: "Elsewhere", from: bea, date: date(20)),
            message("a-found", in: "t-a", subject: "Here", date: date(30)),
        ])
        let found: Set<ConversationID> = [ConversationID(accountID: accountA, providerID: "t-trash"),
                                          ConversationID(accountID: accountB, providerID: "t-b"),
                                          ConversationID(accountID: accountA, providerID: "t-a"),
                                          ConversationID(accountID: accountA, providerID: "t-not-stored")]
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon", matches: found)), ["t-a", "t-b"],
                       "Trash stays out of a search, and a match the store lacks lists nothing")
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon", matches: found, accounts: [accountA])), ["t-a"],
                       "a scoped search lists only its account's matches")
        var paged = searchQuery("lisbon", matches: found)
        paged.before = date(30)
        XCTAssertEqual(try conversationIDs(paged), ["t-b"], "paging applies to matches like any row")
    }

    /// The server's own rules decided that its finds match the words and people (roadmap Q2.5's full-text terms); the
    /// operators this Mac tests on the row still narrow them, as they narrow the local hits.
    func testServerMatchesStandInForTheFullTextTermsOnly() throws {
        try store.upsertMessages([
            message("local", in: "t-local", subject: "Lisbon flat", date: date(50), isRead: false),
            message("unread", in: "t-unread", subject: "Photos", from: bea, date: date(40), isRead: false, hasAttachments: true),
            message("read", in: "t-read", subject: "Receipt", date: date(30), isStarred: true),
            message("old", in: "t-old", subject: "Keys", date: date(-86_400 * 3), isRead: false),
        ])
        let found: Set<ConversationID> = Set(["t-unread", "t-read", "t-old"].map { ConversationID(accountID: accountA, providerID: $0) })
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon", matches: found)), ["t-local", "t-unread", "t-read", "t-old"])
        XCTAssertEqual(try conversationIDs(searchQuery("is:unread lisbon", matches: found)), ["t-local", "t-unread", "t-old"],
                       "is: still tests the row")
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon has:attachment", matches: found)), ["t-unread"])
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon is:starred", matches: found)), ["t-read"])
        // Three days before the others, so the day holds in any time zone the tests run in.
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon before:2025-12-31", matches: found)), ["t-old"], "dates still test the row")
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon in:sent", matches: found)), [], "in: still tests the view")
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon -from:bea", matches: found)), ["t-local", "t-unread", "t-read", "t-old"],
                       "the people were the server's to match, a minus included")
        XCTAssertEqual(try conversationIDs(searchQuery("-lisbon", matches: found)), ["t-unread", "t-read", "t-old"],
                       "a search of minus terms alone takes them as found too")
        XCTAssertEqual(try conversationIDs(searchQuery("subject:receipt", matches: [ConversationID(accountID: accountA, providerID: "t-old")])),
                       ["t-read", "t-old"])
    }

    /// With no full-text term there is no match for the finds to stand in for: they list only as stored mail that fits
    /// the operators, as without them.
    func testServerMatchesAddNothingToASearchOfOperatorsAlone() throws {
        try store.upsertMessages([
            message("starred", in: "t-starred", subject: "Lisbon", date: date(30), isStarred: true),
            message("plain", in: "t-plain", subject: "Photos", date: date(20)),
        ])
        let found: Set<ConversationID> = [ConversationID(accountID: accountA, providerID: "t-plain"),
                                          ConversationID(accountID: accountA, providerID: "t-starred")]
        XCTAssertEqual(try conversationIDs(searchQuery("is:starred", matches: found)), ["t-starred"])
        XCTAssertEqual(try conversationIDs(searchQuery("is:starred")), ["t-starred"])
    }

    /// The finds take the search's order and paging: newest latest message first, a page ending where `before` says,
    /// the next page going on from there with the local hits and the finds interleaved.
    func testServerMatchesPageWithTheHits() throws {
        var messages: [MessageMetadata] = []
        var found: Set<ConversationID> = []
        for index in 0..<7 {
            let isFound = index % 2 == 1
            messages.append(message("m\(index)", in: "t\(index)", subject: isFound ? "Photos" : "Lisbon", date: date(Double(index) * 60)))
            if isFound { found.insert(ConversationID(accountID: accountA, providerID: "t\(index)")) }
        }
        try store.upsertMessages(messages)
        var page = ConversationQuery(view: .all, searchText: "lisbon", limit: 3, serverMatches: found)
        XCTAssertEqual(try conversationIDs(page), ["t6", "t5", "t4"])
        page.before = try store.conversations(page).last?.latestDate
        XCTAssertEqual(try conversationIDs(page), ["t3", "t2", "t1"])
        page.before = try store.conversations(page).last?.latestDate
        XCTAssertEqual(try conversationIDs(page), ["t0"])
    }

    /// The open conversation of an `is:unread` search stays once read, a find as much as a local hit.
    func testAnOpenFindStaysInAReadStateSearch() throws {
        try store.upsertMessages([message("found", in: "t-found", subject: "Photos", date: date(30), isRead: true)])
        let id = ConversationID(accountID: accountA, providerID: "t-found")
        var query = searchQuery("is:unread lisbon", matches: [id])
        XCTAssertEqual(try conversationIDs(query), [])
        query.openConversationID = id
        XCTAssertEqual(try conversationIDs(query), ["t-found"])
    }

    func testServerMatchesNeedSearchText() throws {
        try store.upsertMessages([message("a", in: "t-a", subject: "Here", date: date(30), roles: [.sent])])
        let query = ConversationQuery(view: .inbox, serverMatches: [ConversationID(accountID: accountA, providerID: "t-a")])
        XCTAssertEqual(try conversationIDs(query), [], "a view without search text ignores them")
    }

    /// A server hit is stored as metadata: its subject and people are searchable at once, before its body is in.
    func testMetadataAloneIsSearchableBySubjectAndPeople() throws {
        try store.upsertMessages([message("hit", in: "t-hit", subject: "Lisbon photos, finally",
                                          from: EmailAddress(name: "Priya Raman", address: "priya@example.com"), date: date(30))])
        XCTAssertEqual(try conversationIDs(searchQuery("lisbon")), ["t-hit"])
        XCTAssertEqual(try conversationIDs(searchQuery("priya")), ["t-hit"])
    }

    /// Until its body is stored a message is searchable by its snippet too, so a find the server matched there is found
    /// again by a later search of those words, with no matches named; the body then takes the snippet's place.
    func testASnippetIsSearchableUntilTheBodyArrives() throws {
        let id = MessageID(accountID: accountA, providerID: "hit")
        try store.upsertMessages([message("hit", in: "t-hit", subject: "Tax documents", snippet: "Forms for the landlord",
                                          date: date(30))])
        XCTAssertEqual(try conversationIDs(searchQuery("landlord")), ["t-hit"])
        XCTAssertEqual(try conversationIDs(searchQuery("landl")), ["t-hit"], "as you type, like any indexed word")

        var reported = try XCTUnwrap(try store.message(id))
        reported.snippet = "Forms for the accountant"
        try store.upsertMessages([reported])
        XCTAssertEqual(try conversationIDs(searchQuery("accountant")), ["t-hit"], "a new snippet replaces the old one")
        XCTAssertEqual(try conversationIDs(searchQuery("landlord")), [])

        try store.saveBody(body("Both forms are attached"), for: id)
        XCTAssertEqual(try conversationIDs(searchQuery("attached")), ["t-hit"])
        XCTAssertEqual(try conversationIDs(searchQuery("accountant")), [], "the body takes the snippet's place")
    }
}
