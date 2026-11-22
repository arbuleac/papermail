import XCTest
@testable import PaperCore

/// The search field's grammar (spec §5.6): what `SearchQuery(parsing:)` makes of what the user types. Dates are read
/// in a fixed time zone, so the tests mean the same on any Mac.
final class SearchGrammarTests: XCTestCase {
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func terms(_ text: String, timeZone: TimeZone? = nil) -> [SearchTerm] {
        SearchQuery(parsing: text, timeZone: timeZone ?? losAngeles)?.terms ?? []
    }

    private func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: Words and phrases

    func testWordsAreTermsAndTheLastOneIsAPrefix() {
        XCTAssertEqual(terms("budget review"), [SearchTerm(.text("budget")), SearchTerm(.text("review"), isPrefix: true)])
        XCTAssertEqual(terms("  budget  "), [SearchTerm(.text("budget"), isPrefix: true)])
        XCTAssertEqual(terms("e-mail"), [SearchTerm(.text("e-mail"), isPrefix: true)], "a hyphen inside a word is not a minus")
    }

    func testQuotedPhrases() {
        XCTAssertEqual(terms("\"quarterly budget\""), [SearchTerm(.phrase("quarterly budget"))], "a closed quote is finished")
        XCTAssertEqual(terms("\"quarterly bud"), [SearchTerm(.phrase("quarterly bud"), isPrefix: true)], "an open quote is still being typed")
        XCTAssertEqual(terms("\"lunch\" plans"), [SearchTerm(.phrase("lunch")), SearchTerm(.text("plans"), isPrefix: true)])
        XCTAssertEqual(terms("a \"b c\" d"), [SearchTerm(.text("a")), SearchTerm(.phrase("b c")), SearchTerm(.text("d"), isPrefix: true)])
    }

    // MARK: Operators

    func testEveryOperator() {
        XCTAssertEqual(terms("from:ben x"), [SearchTerm(.from("ben")), SearchTerm(.text("x"), isPrefix: true)])
        XCTAssertEqual(terms("to:ben@example.com x").first, SearchTerm(.to("ben@example.com")))
        XCTAssertEqual(terms("subject:lunch x").first, SearchTerm(.subject("lunch")))
        XCTAssertEqual(terms("is:unread"), [SearchTerm(.unread)])
        XCTAssertEqual(terms("is:read"), [SearchTerm(.read)])
        XCTAssertEqual(terms("is:starred"), [SearchTerm(.starred)])
        XCTAssertEqual(terms("has:attachment"), [SearchTerm(.attachment)])
        XCTAssertEqual(terms("before:2026-01-15"), [SearchTerm(.before(instant("2026-01-15T08:00:00Z")))])
        XCTAssertEqual(terms("after:2026/01/15"), [SearchTerm(.after(instant("2026-01-15T08:00:00Z")))])
        XCTAssertEqual(terms("in:inbox"), [SearchTerm(.mailbox(.inbox))])
        XCTAssertEqual(terms("in:sent"), [SearchTerm(.mailbox(.sent))])
        XCTAssertEqual(terms("in:drafts"), [SearchTerm(.mailbox(.drafts))])
        XCTAssertEqual(terms("in:trash"), [SearchTerm(.mailbox(.trash))])
        XCTAssertEqual(terms("in:all"), [SearchTerm(.mailbox(.all))])
    }

    func testTheLastTextOperatorIsAPrefix() {
        XCTAssertEqual(terms("from:nakam"), [SearchTerm(.from("nakam"), isPrefix: true)])
        XCTAssertEqual(terms("to:o"), [SearchTerm(.to("o"), isPrefix: true)])
        XCTAssertEqual(terms("subject:lun"), [SearchTerm(.subject("lun"), isPrefix: true)])
    }

    func testOperatorNamesAndKeywordsIgnoreCase() {
        XCTAssertEqual(terms("FROM:Ben IS:UNREAD In:Sent Has:Attachment"), [
            SearchTerm(.from("Ben")), SearchTerm(.unread), SearchTerm(.mailbox(.sent)), SearchTerm(.attachment),
        ], "the value of a text operator is kept as typed; the index folds case itself")
        XCTAssertEqual(terms("Before:2026-01-15"), [SearchTerm(.before(instant("2026-01-15T08:00:00Z")))])
    }

    func testQuotedValues() {
        XCTAssertEqual(terms("from:\"Ben Carter\" invoice"), [SearchTerm(.from("Ben Carter")), SearchTerm(.text("invoice"), isPrefix: true)])
        XCTAssertEqual(terms("subject:\"lunch plans\""), [SearchTerm(.subject("lunch plans"))], "a closed quote is no prefix")
        XCTAssertEqual(terms("to:\"Ben Car"), [SearchTerm(.to("Ben Car"), isPrefix: true)])
        XCTAssertEqual(terms("is:\"unread\" in:\"trash\""), [SearchTerm(.unread), SearchTerm(.mailbox(.trash))])
        XCTAssertEqual(terms("before:\"2026-01-15\""), [SearchTerm(.before(instant("2026-01-15T08:00:00Z")))])
    }

    // MARK: Negation

    func testALeadingMinusNegatesAnyTerm() {
        XCTAssertEqual(terms("budget -invoice x"), [SearchTerm(.text("budget")), SearchTerm(.text("invoice"), negated: true), SearchTerm(.text("x"), isPrefix: true)])
        XCTAssertEqual(terms("-\"weekly metrics\" x").first, SearchTerm(.phrase("weekly metrics"), negated: true))
        XCTAssertEqual(terms("-from:ben x").first, SearchTerm(.from("ben"), negated: true))
        XCTAssertEqual(terms("-is:unread"), [SearchTerm(.unread, negated: true)])
        XCTAssertEqual(terms("-has:attachment"), [SearchTerm(.attachment, negated: true)])
        XCTAssertEqual(terms("-in:trash"), [SearchTerm(.mailbox(.trash), negated: true)])
        XCTAssertEqual(terms("-after:2026-01-15"), [SearchTerm(.after(instant("2026-01-15T08:00:00Z")), negated: true)])
    }

    func testANegatedLastTermIsNeverAPrefix() {
        // Typing "-b", "-be", "-ben" excludes those exact words, never every word that starts with b.
        XCTAssertEqual(terms("budget -spread"), [SearchTerm(.text("budget")), SearchTerm(.text("spread"), negated: true)])
        XCTAssertEqual(terms("-from:be"), [SearchTerm(.from("be"), negated: true)])
    }

    func testAMinusAloneOrBeforeASpaceIsNothing() {
        XCTAssertEqual(terms("budget - x"), [SearchTerm(.text("budget")), SearchTerm(.text("x"), isPrefix: true)])
        XCTAssertEqual(terms("-"), [])
        XCTAssertNotNil(SearchQuery(parsing: "-"), "still a search: the field holds text")
    }

    // MARK: Dates

    func testDatesAreLocalMidnight() {
        // after: is on or after the day, before: is before it, both from local midnight in the given zone.
        XCTAssertEqual(terms("after:2026-07-04"), [SearchTerm(.after(instant("2026-07-04T07:00:00Z")))], "summer time")
        XCTAssertEqual(terms("after:2026-07-04", timeZone: TimeZone(identifier: "Asia/Tokyo")),
                       [SearchTerm(.after(instant("2026-07-03T15:00:00Z")))])
        XCTAssertEqual(terms("before:2026-1-5"), [SearchTerm(.before(instant("2026-01-05T08:00:00Z")))], "one-digit month and day")
        XCTAssertEqual(terms("before:2024-02-29"), [SearchTerm(.before(instant("2024-02-29T08:00:00Z")))], "a leap day")
        // São Paulo moved its clocks from midnight to 1:00 on 4 November 2018: the day starts at 1:00.
        XCTAssertEqual(terms("after:2018-11-04", timeZone: TimeZone(identifier: "America/Sao_Paulo")),
                       [SearchTerm(.after(instant("2018-11-04T03:00:00Z")))])
    }

    func testDaysThatDoNotExistAreText() {
        XCTAssertEqual(terms("before:2025-02-29 x").first, SearchTerm(.text("before:2025-02-29")))
        XCTAssertEqual(terms("after:2025-13-01 x").first, SearchTerm(.text("after:2025-13-01")))
        XCTAssertEqual(terms("after:25-01-01 x").first, SearchTerm(.text("after:25-01-01")), "the year has four digits")
        XCTAssertEqual(terms("before:yesterday x").first, SearchTerm(.text("before:yesterday")))
        XCTAssertEqual(terms("before:2025-01-01-01 x").first, SearchTerm(.text("before:2025-01-01-01")))
    }

    func testADayNoDigitCanSaveIsTextEvenLast() {
        // Typed last, these are no day still being typed: more digits cannot make them real, so they are searched as
        // words (finding nothing) instead of waiting while the list shows everything.
        XCTAssertEqual(terms("after:2025-02-30"), [SearchTerm(.text("after:2025-02-30"), isPrefix: true)])
        XCTAssertEqual(terms("before:2025-13-01"), [SearchTerm(.text("before:2025-13-01"), isPrefix: true)])
        XCTAssertEqual(terms("from:ben before:2025-11-31"), [SearchTerm(.from("ben")), SearchTerm(.text("before:2025-11-31"), isPrefix: true)])
        XCTAssertEqual(terms("after:2025-00-10").first, SearchTerm(.text("after:2025-00-10"), isPrefix: true))
        XCTAssertEqual(terms("after:2025-13").first, SearchTerm(.text("after:2025-13"), isPrefix: true), "no thirteenth month")
        XCTAssertEqual(terms("after:2025-0-").first, SearchTerm(.text("after:2025-0-"), isPrefix: true), "the month is finished")
        XCTAssertEqual(terms("after:0000-1").first, SearchTerm(.text("after:0000-1"), isPrefix: true), "no year 0")
        // Still on the way to a real day: they wait.
        XCTAssertEqual(terms("after:2025-1"), [])
        XCTAssertEqual(terms("after:2025-02-0"), [])
        XCTAssertEqual(terms("after:2025/12/"), [])
    }

    // MARK: Anything else is text

    func testUnknownOperatorsAndValuesAreSearchedAsText() {
        XCTAssertEqual(terms("label:work"), [SearchTerm(.text("label:work"), isPrefix: true)])
        XCTAssertEqual(terms("re:hello 10:30 https://example.com"), [
            SearchTerm(.text("re:hello")), SearchTerm(.text("10:30")), SearchTerm(.text("https://example.com"), isPrefix: true),
        ])
        XCTAssertEqual(terms("is:important x").first, SearchTerm(.text("is:important")))
        XCTAssertEqual(terms("has:pdf x").first, SearchTerm(.text("has:pdf")))
        XCTAssertEqual(terms("in:spam x").first, SearchTerm(.text("in:spam")))
        XCTAssertEqual(terms("-in:spam x").first, SearchTerm(.text("in:spam"), negated: true))
        XCTAssertEqual(terms("is:unreadx"), [SearchTerm(.text("is:unreadx"), isPrefix: true)], "not the start of a value it takes")
    }

    func testAnOperatorStillBeingTypedWaits() {
        // The last token, while it is the start of a value the operator takes, adds nothing yet: the list keeps
        // what the rest of the text finds instead of searching for "is" and "un".
        XCTAssertEqual(terms("budget is:un"), [SearchTerm(.text("budget"))])
        XCTAssertEqual(terms("has:att"), [])
        XCTAssertEqual(terms("in:tr"), [])
        XCTAssertEqual(terms("before:2026"), [])
        XCTAssertEqual(terms("before:2026-0"), [])
        XCTAssertEqual(terms("after:2026/11/"), [])
        XCTAssertEqual(terms("after:2026-02-3"), [SearchTerm(.after(instant("2026-02-03T08:00:00Z")))], "already a day")
        // Once something follows it, it is finished, and what it says is searched as words.
        XCTAssertEqual(terms("is:un budget"), [SearchTerm(.text("is:un")), SearchTerm(.text("budget"), isPrefix: true)])
    }

    func testAnOperatorWithNoValueAddsNothing() {
        XCTAssertEqual(terms("from:"), [])
        XCTAssertEqual(terms("from: ben"), [SearchTerm(.text("ben"), isPrefix: true)])
        XCTAssertEqual(terms("to:\"\" ben"), [SearchTerm(.text("ben"), isPrefix: true)])
        XCTAssertEqual(terms("from:@ ben"), [SearchTerm(.text("ben"), isPrefix: true)], "nothing indexable to look for")
    }

    func testBlankAndUnindexableText() {
        XCTAssertNil(SearchQuery(parsing: "   "))
        XCTAssertNil(SearchQuery(parsing: ""))
        let punctuation = SearchQuery(parsing: " ?! ")
        XCTAssertEqual(punctuation?.text, "?!", "a search whose text is kept for the empty state")
        XCTAssertEqual(punctuation?.terms, [], "with nothing to look for")
        // What counts is what FTS5's unicode61 keeps, not Swift's letters: Ⓐ and 🅻 are symbols to it, and a
        // private-use character (the Apple logo) is a word character.
        XCTAssertEqual(terms("Ⓐ 🅻🅸🆂🅱🅾🅽 from:Ⓐ"), [])
        XCTAssertEqual(terms("\u{F8FF}"), [SearchTerm(.text("\u{F8FF}"), isPrefix: true)])
    }

    func testOperatorsAndWordsTogether() {
        XCTAssertEqual(terms("from:\"Ben Carter\" -to:ana is:unread has:attachment after:2026-01-01 before:2026-02-01 in:inbox \"budget review\" -invoice spread"), [
            SearchTerm(.from("Ben Carter")), SearchTerm(.to("ana"), negated: true), SearchTerm(.unread), SearchTerm(.attachment),
            SearchTerm(.after(instant("2026-01-01T08:00:00Z"))), SearchTerm(.before(instant("2026-02-01T08:00:00Z"))),
            SearchTerm(.mailbox(.inbox)), SearchTerm(.phrase("budget review")), SearchTerm(.text("invoice"), negated: true),
            SearchTerm(.text("spread"), isPrefix: true),
        ])
    }

    // MARK: The parsed form

    func testTheTextIsKeptAsTyped() {
        let search = SearchQuery(parsing: "  from:ben  Lisbon ")
        XCTAssertEqual(search?.text, "from:ben  Lisbon", "trimmed, for the empty state and a provider's own search")
        XCTAssertEqual(ConversationQuery(searchText: " from:ben ").searchText, "from:ben")
        XCTAssertEqual(ConversationQuery(searchText: " from:ben ").search?.terms, [SearchTerm(.from("ben"), isPrefix: true)])
        XCTAssertNil(ConversationQuery(searchText: "  ").search)
    }

    func testTheMailboxIsTheFirstInTermThatIsNotNegated() {
        XCTAssertNil(SearchQuery(parsing: "budget")?.mailbox)
        XCTAssertNil(SearchQuery(parsing: "-in:trash budget")?.mailbox)
        XCTAssertEqual(SearchQuery(parsing: "-in:inbox in:sent in:trash")?.mailbox, .sent)
    }

    func testReadStateFilters() {
        XCTAssertTrue(SearchQuery(parsing: "is:unread")?.filtersOnReadState == true)
        XCTAssertTrue(SearchQuery(parsing: "-is:read budget")?.filtersOnReadState == true)
        XCTAssertFalse(SearchQuery(parsing: "is:starred budget")?.filtersOnReadState == true)
    }
}
