import XCTest
@testable import SSCore

/// The end of a search (spec §5.10, roadmap Q3.1): the row's words in every state and scope, when it shows, how many
/// conversations a search added, and the empty search's offer (§5.9).
final class ServerSearchRowTests: XCTestCase {
    private let gmail = Account(id: AccountID("g"), kind: .gmail, email: "alex@gmail.com", displayName: "Alex", addedAt: Date(timeIntervalSince1970: 0))
    private let outlook = Account(id: AccountID("o"), kind: .microsoft, email: "alex@contoso.test", displayName: "Alex",
                                  addedAt: Date(timeIntervalSince1970: 1))
    private let fabrikam = Account(id: AccountID("f"), kind: .microsoft, email: "alex@fabrikam.test", displayName: "Alex",
                                   addedAt: Date(timeIntervalSince1970: 2))

    private func row(_ target: ServerSearchRow.Target, _ phase: ServerSearchRow.Phase) -> ServerSearchRow {
        ServerSearchRow(target: target, phase: phase)
    }

    func testTheCopyTableForOneAccount() {
        XCTAssertEqual(row(.provider(.gmail), .offer).title, "Search Gmail for more")
        XCTAssertEqual(row(.provider(.microsoft), .offer).title, "Search Outlook for more")
        XCTAssertEqual(row(.provider(.gmail), .searching).title, "Searching Gmail…")
        XCTAssertEqual(row(.provider(.gmail), .found(12)).title, "Found 12 more on Gmail")
        XCTAssertEqual(row(.provider(.microsoft), .found(1)).title, "Found 1 more on Outlook")
        XCTAssertEqual(row(.provider(.gmail), .found(0)).title, "Nothing more on Gmail")
        XCTAssertEqual(row(.provider(.gmail), .failed(subject: "Gmail")).title, "Couldn't search Gmail")
        XCTAssertEqual(row(.provider(.gmail), .failed(subject: "Gmail")).actionTitle, "Try again")
        XCTAssertEqual(row(.provider(.gmail), .failed(subject: "Gmail")).accessibilityLabel, "Couldn't search Gmail, Try again")
        for phase: ServerSearchRow.Phase in [.offer, .searching, .found(3), .found(0)] {
            XCTAssertNil(row(.provider(.gmail), phase).actionTitle, "\(phase): the offer is a link itself, the rest act on nothing")
        }
    }

    func testTheCopyTableForAllAccounts() {
        XCTAssertEqual(row(.allAccounts, .offer).title, "Search all accounts for more")
        XCTAssertEqual(row(.allAccounts, .searching).title, "Searching all accounts…")
        XCTAssertEqual(row(.allAccounts, .found(1_204)).title, "Found \(SyncLineSummary.grouped(1_204)) more in your accounts")
        XCTAssertEqual(row(.allAccounts, .found(0)).title, "Nothing more in your accounts")
    }

    func testOnlyTheOfferAndAFailureRun() {
        XCTAssertTrue(row(.provider(.gmail), .offer).runs)
        XCTAssertTrue(row(.provider(.gmail), .failed(subject: "Gmail")).runs, "Try again")
        XCTAssertFalse(row(.provider(.gmail), .searching).runs, "one search at a time")
        XCTAssertFalse(row(.provider(.gmail), .found(2)).runs, "a finished search is not run again for the same words")
        XCTAssertFalse(row(.provider(.gmail), .found(0)).runs)
    }

    func testTheEmptySearchOffersItInItsOwnWords() {
        XCTAssertEqual(row(.provider(.gmail), .offer).emptyHint.text, "Not on this Mac?")
        XCTAssertEqual(row(.provider(.gmail), .offer).emptyHint.link, "Search Gmail")
        XCTAssertEqual(row(.allAccounts, .offer).emptyHint.link, "Search all accounts")
        XCTAssertEqual(row(.provider(.microsoft), .searching).emptyHint.text, "Searching Outlook…")
        XCTAssertNil(row(.provider(.microsoft), .searching).emptyHint.link)
        XCTAssertEqual(row(.provider(.gmail), .found(0)).emptyHint.text, "Nothing on Gmail either.")
        XCTAssertEqual(row(.allAccounts, .found(0)).emptyHint.text, "Nothing in your accounts either.")
        XCTAssertEqual(row(.provider(.gmail), .failed(subject: "Gmail")).emptyHint.text, "Couldn't search Gmail ·")
        XCTAssertEqual(row(.provider(.gmail), .failed(subject: "Gmail")).emptyHint.link, "Try again")
    }

    func testMenuTitlesAreTitleCase() {
        XCTAssertEqual(ServerSearchRow.menuTitle(for: .provider(.gmail)), "Search Gmail for More")
        XCTAssertEqual(ServerSearchRow.menuTitle(for: .provider(.microsoft)), "Search Outlook for More")
        XCTAssertEqual(ServerSearchRow.menuTitle(for: .allAccounts), "Search All Accounts for More")
        XCTAssertEqual(ServerSearchRow.menuTitle(for: nil), "Search the Server for More")
    }

    // MARK: Rules

    func testTheTargetFollowsTheScope() {
        let accounts = [gmail, outlook]
        XCTAssertEqual(ServerSearchRow.target(scope: nil, accounts: accounts), .allAccounts, "unified with several accounts")
        XCTAssertEqual(ServerSearchRow.target(scope: [gmail.id], accounts: accounts), .provider(.gmail))
        XCTAssertEqual(ServerSearchRow.target(scope: [outlook.id], accounts: accounts), .provider(.microsoft))
        XCTAssertEqual(ServerSearchRow.target(scope: nil, accounts: [outlook]), .provider(.microsoft),
                       "a unified view of one account names its provider")
        XCTAssertEqual(ServerSearchRow.target(scope: nil, accounts: [outlook, fabrikam]), .allAccounts,
                       "two accounts of one provider are still several accounts")
        XCTAssertNil(ServerSearchRow.target(scope: nil, accounts: []))
        XCTAssertNil(ServerSearchRow.target(scope: [AccountID("gone")], accounts: accounts))
    }

    func testTheRowShowsOnlyOnceEveryLocalResultIsListed() {
        XCTAssertTrue(ServerSearchRow.isShown(searchText: "lisbon", hasFirstPage: true, reachedEnd: true, hasRows: true))
        XCTAssertFalse(ServerSearchRow.isShown(searchText: "lisbon", hasFirstPage: true, reachedEnd: false, hasRows: true),
                       "older pages still to load: the tail comes first")
        XCTAssertFalse(ServerSearchRow.isShown(searchText: "lisbon", hasFirstPage: false, reachedEnd: true, hasRows: true),
                       "before the first page there is nothing to end")
        XCTAssertFalse(ServerSearchRow.isShown(searchText: "lisbon", hasFirstPage: true, reachedEnd: true, hasRows: false),
                       "an empty search offers it in its empty state")
        XCTAssertFalse(ServerSearchRow.isShown(searchText: "  ", hasFirstPage: true, reachedEnd: true, hasRows: true))
        XCTAssertFalse(ServerSearchRow.isShown(searchText: nil, hasFirstPage: true, reachedEnd: true, hasRows: true),
                       "a mailbox view is not a search")
    }

    func testAddedCountsRowsThatAppearedNotHits() {
        let a = ConversationID(accountID: gmail.id, providerID: "a")
        let b = ConversationID(accountID: gmail.id, providerID: "b")
        let c = ConversationID(accountID: gmail.id, providerID: "c")
        let hidden = ConversationID(accountID: gmail.id, providerID: "in-trash")
        XCTAssertEqual(ServerSearchRow.added(listed: [a, b, c], found: [a, b, hidden], before: [a]), 1,
                       "a hit already listed adds nothing, and one the view hides is not counted")
        XCTAssertEqual(ServerSearchRow.added(listed: [a], found: [], before: [a]), 0)
    }

    func testAFailureNamesWhoCouldNotBeSearched() {
        XCTAssertEqual(ServerSearchRow.failureSubject(target: .provider(.gmail), failed: [gmail], searched: 1), "Gmail")
        XCTAssertEqual(ServerSearchRow.failureSubject(target: .provider(.microsoft), failed: [], searched: 1), "Outlook")
        let all = [gmail, outlook, fabrikam]
        XCTAssertEqual(ServerSearchRow.failureSubject(target: .allAccounts, failed: [outlook], searched: 3),
                       AccountLabels.name(for: outlook), "one account of several, by its name")
        XCTAssertEqual(ServerSearchRow.failureSubject(target: .allAccounts, failed: [outlook, fabrikam], searched: 3), "2 accounts")
        XCTAssertEqual(ServerSearchRow.failureSubject(target: .allAccounts, failed: all, searched: 3), "your accounts")
    }
}
