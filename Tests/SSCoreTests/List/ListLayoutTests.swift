import XCTest
@testable import SSCore

final class ListLayoutTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .current
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }
    private lazy var formatting = DateFormatting(locale: Locale(identifier: "en_GB"), calendar: calendar, timeZone: utc)
    /// Thursday 6 March 2025, 14:05 UTC; the week started on Monday 3 March.
    private lazy var reference = formatting.reference(now: date(2025, 3, 6, 14, 5))

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private func layout(_ dates: [Date], heads: Bool = true, footer: Bool = false) -> ListLayout {
        ListLayout.make(dates: dates, showsHeads: heads, showsFooter: footer, reference: reference, formatter: formatting)
    }

    /// Newest first, one or two rows per group, as the store orders a mailbox.
    private lazy var mailbox: [Date] = [
        date(2025, 3, 6, 13, 0), date(2025, 3, 6, 9, 0),   // today
        date(2025, 3, 5, 18, 0),                           // yesterday
        date(2025, 3, 4, 10, 0), date(2025, 3, 3, 8, 0),   // earlier this week
        date(2025, 2, 27, 8, 0),                           // last week
        date(2025, 2, 10, 8, 0), date(2025, 2, 1, 8, 0),   // February
        date(2024, 10, 30, 8, 0),                          // October 2024
    ]

    func testHeadsOpenEachGroupOnce() {
        let result = layout(mailbox)
        XCTAssertEqual(result.items, [
            .head(.today), .conversation(0), .conversation(1),
            .head(.yesterday), .conversation(2),
            .head(.earlierThisWeek), .conversation(3), .conversation(4),
            .head(.lastWeek), .conversation(5),
            .head(.month(year: 2025, month: 2)), .conversation(6), .conversation(7),
            .head(.month(year: 2024, month: 10)), .conversation(8),
        ])
        XCTAssertTrue(result.showsHeads)
        XCTAssertEqual(result.timeStyles, [.timeOfDay, .timeOfDay, .timeOfDay, .weekday, .weekday, .dayMonth, .dayMonth, .dayMonth, .dayMonth])
    }

    func testRowsAndConversationsMapBothWays() {
        let result = layout(mailbox, footer: true)
        for index in mailbox.indices {
            guard let row = result.row(ofConversation: index) else { return XCTFail("no row for \(index)") }
            XCTAssertEqual(result.conversationIndex(atRow: row), index)
        }
        XCTAssertNil(result.conversationIndex(atRow: 0), "a head is not a conversation")
        XCTAssertEqual(result.footerRow, result.rowCount - 1)
        XCTAssertNil(result.conversationIndex(atRow: result.rowCount - 1), "nor is the footer")
        XCTAssertNil(result.conversationIndex(atRow: result.rowCount))
        XCTAssertNil(result.row(ofConversation: mailbox.count))
    }

    func testWithoutHeadsRowsAreConversationsAndTimesAreRelative() {
        let result = layout(mailbox, heads: false, footer: true)
        XCTAssertEqual(result.rowCount, mailbox.count + 1)
        XCTAssertEqual(Array(result.items.prefix(3)), [.conversation(0), .conversation(1), .conversation(2)])
        XCTAssertEqual(result.items.last, .footer)
        XCTAssertTrue(result.timeStyles.allSatisfy { $0 == .relative })
        XCTAssertNil(layout(mailbox, heads: false).footerRow)
    }

    func testOutOfOrderDatesNeverRepeatAHead() {
        // A row that moved while sync ran: today, yesterday, then today again.
        let result = layout([date(2025, 3, 6, 13, 0), date(2025, 3, 5, 9, 0), date(2025, 3, 6, 8, 0)])
        XCTAssertEqual(result.items, [.head(.today), .conversation(0), .head(.yesterday), .conversation(1), .conversation(2)])
        XCTAssertEqual(result.timeStyles[2], .timeOfDay, "it reads under the head it sits beneath")
        let ids = result.itemIDs(conversationIDs: (0..<3).map { ConversationID(accountID: AccountID("a"), providerID: "\($0)") })
        XCTAssertEqual(Set(ids).count, ids.count, "row identities stay unique for the diff")
    }

    func testItemIDsDiffWhenAGroupAppears() {
        let ids = (0..<3).map { ConversationID(accountID: AccountID("a"), providerID: "\($0)") }
        let before = layout([date(2025, 3, 5, 9, 0), date(2025, 3, 4, 9, 0)]).itemIDs(conversationIDs: Array(ids.suffix(2)))
        let after = layout([date(2025, 3, 6, 13, 0), date(2025, 3, 5, 9, 0), date(2025, 3, 4, 9, 0)]).itemIDs(conversationIDs: ids)
        let diff = ListDiff.compute(old: before, new: after)
        XCTAssertEqual(diff.insertedIDs, [.head(.today), .conversation(ids[0])])
        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertEqual(diff.applied(to: before), after)
    }

    func testHeadsShowOnlyInLongDateOrderedViews() {
        XCTAssertTrue(RunningHead.showsHeads(conversationCount: 8, isSearch: false))
        XCTAssertFalse(RunningHead.showsHeads(conversationCount: 7, isSearch: false))
        XCTAssertFalse(RunningHead.showsHeads(conversationCount: 500, isSearch: true))
    }

    func testEmptyLayout() {
        let result = layout([])
        XCTAssertEqual(result.rowCount, 0)
        XCTAssertNil(result.footerRow)
        XCTAssertNil(result.serverSearchRow)
    }

    /// The end of a search (§5.10): the server row closes the rows once nothing older is left to load, and it is no
    /// conversation, so j/k and the selection never land on it.
    func testTheServerRowEndsTheListInsteadOfTheTail() {
        let dates = Array(mailbox.prefix(3))
        let ended = ListLayout.make(dates: dates, showsHeads: false, showsFooter: false, showsServerSearch: true,
                                    reference: reference, formatter: formatting)
        XCTAssertEqual(ended.items, [.conversation(0), .conversation(1), .conversation(2), .serverSearch])
        XCTAssertEqual(ended.serverSearchRow, 3)
        XCTAssertNil(ended.footerRow)
        XCTAssertNil(ended.conversationIndex(atRow: 3))
        let ids = dates.indices.map { ConversationID(accountID: AccountID("a"), providerID: "\($0)") }
        XCTAssertEqual(ended.itemIDs(conversationIDs: ids).last, .serverSearch)

        let paging = ListLayout.make(dates: dates, showsHeads: false, showsFooter: true, showsServerSearch: true,
                                     reference: reference, formatter: formatting)
        XCTAssertEqual(paging.items.last, .footer, "while older pages exist the tail ends the list, never both")
        XCTAssertNil(paging.serverSearchRow)
    }

    // MARK: Performance (SS_PERF=1)

    /// Grouping a page is part of every list refresh, inside the 50 ms budget (docs/ARCHITECTURE.md); ten
    /// thousand rows over two years must group in a small slice of it.
    func testGroupingTenThousandRowsIsFast() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the timing assertion")
        }
        let start = reference.now
        let dates = (0..<10_000).map { start.addingTimeInterval(-Double($0) * 6_300) }
        _ = layout(Array(dates.prefix(100)))
        let begin = DispatchTime.now()
        let result = layout(dates, footer: true)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin.uptimeNanoseconds) / 1e9
        XCTAssertGreaterThan(result.rowCount, 10_000)
        XCTAssertLessThan(elapsed, 0.010, "grouping 10,000 rows took \(elapsed * 1000) ms")
    }
}
