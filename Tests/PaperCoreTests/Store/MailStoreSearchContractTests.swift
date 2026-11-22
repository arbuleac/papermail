import XCTest
@testable import PaperCore

/// The `MailStoring` contract for search operators (roadmap Q2.5, spec §5.6): every operator's results, through the
/// query the field asks for (`ShellQuery`). Written as an extension so `SQLiteMailStoreContractTests` inherits every
/// case and both stores are held to the same semantics.
extension MailStoreContractTests {
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }
    private var day: TimeInterval { 86_400 }

    private var ben: EmailAddress { EmailAddress(name: "Ben Carter", address: "ben@example.com") }
    private var ana: EmailAddress { EmailAddress(name: "Ana Silva", address: "ana@example.org") }
    private var dana: EmailAddress { EmailAddress(name: "Dana Reyes", address: "dana@example.net") }
    private var owner: EmailAddress { EmailAddress(name: "Owner", address: "a@example.com") }

    private func id(_ providerID: String, account: AccountID? = nil) -> MessageID {
        MessageID(accountID: account ?? accountA, providerID: providerID)
    }

    /// What the field shows for `text` typed over `view`, dates read in UTC (so `base`, 2026-01-01T00:00:00Z, is a
    /// midnight).
    private func search(_ text: String, view: MailboxView = .inbox, scope: [AccountID]? = nil,
                        open: ConversationID? = nil) throws -> [String] {
        var query = ShellQuery.make(scope: scope, view: view, searchText: text, timeZone: utc)
        query.openConversationID = open
        return try conversationIDs(query)
    }

    /// Account A:
    /// - c1 "Lisbon flat": Ben writes (unread, with an attachment, Ana in cc); the owner answers Ben, Dana in bcc.
    /// - c2 "Budget review": Ana writes, read and starred.
    /// - c3 "Invoice 4471": in the trash.
    /// - c4 "Contract draft": the owner wrote to Ben; sent only, so not in the inbox.
    /// - c6 "New year": its only message at exactly midnight starting 2026-01-01.
    /// Account B: c5 "Lisbon" from Ben.
    private func seed() throws {
        var answer = message("m2", in: "c1", subject: "Re: Lisbon flat", from: owner, to: [ben], date: date(-9 * day), roles: [.sent])
        answer.bcc = [dana]
        try store.upsertMessages([
            message("m1", in: "c1", subject: "Lisbon flat", from: ben, cc: [ana], date: date(-10 * day), isRead: false,
                    hasAttachments: true),
            answer,
            message("m3", in: "c2", subject: "Budget review", from: ana, date: date(-5 * day), isStarred: true),
            message("m4", in: "c3", subject: "Invoice 4471", from: EmailAddress(name: "Carol", address: "carol@example.com"),
                    date: date(-3 * day), roles: [.trash]),
            message("m5", in: "c4", subject: "Contract draft", from: owner, to: [ben], date: date(-2 * day), roles: [.sent]),
            message("m6", in: "c6", subject: "New year", from: ana, date: date(0)),
            message("b1", in: "c5", account: accountB, subject: "Lisbon", from: ben,
                    to: [EmailAddress(name: "Owner", address: "b@example.com")], date: date(-1 * day)),
        ])
        try store.saveBody(body("the keys are under the mat"), for: id("m1"))
        try store.saveBody(body("thanks, see you there"), for: id("m2"))
        try store.saveBody(body("ben will send the spreadsheet"), for: id("m3"))
        try store.saveBody(body("please pay ben"), for: id("m4"))
    }

    // MARK: Index operators

    func testFromMatchesTheSenderOnly() throws {
        try seed()
        XCTAssertEqual(try search("from:ben"), ["c5", "c1"])
        XCTAssertEqual(try search("from:\"Ben Carter\""), ["c5", "c1"], "a quoted name")
        XCTAssertEqual(try search("from:ben@example.com"), ["c5", "c1"], "an address")
        XCTAssertEqual(try search("from:carter"), ["c5", "c1"])
        XCTAssertEqual(try search("from:car"), ["c5", "c1"], "the last term is a prefix")
        XCTAssertEqual(try search("from:ana"), ["c6", "c2"], "Ana is in c1's cc, not its sender")
        XCTAssertEqual(try search("from:\"carter example\""), [], "a phrase's words side by side: the column reads Ben Carter ben example com")
        XCTAssertEqual(try search("from:ben", scope: [accountA]), ["c1"], "the account scope still applies")
    }

    func testToMatchesEveryRecipient() throws {
        try seed()
        XCTAssertEqual(try search("to:ana"), ["c1"], "cc")
        XCTAssertEqual(try search("to:dana"), ["c1"], "bcc")
        XCTAssertEqual(try search("to:\"Dana Reyes\""), ["c1"])
        XCTAssertEqual(try search("to:ben"), ["c4", "c1"], "to")
        XCTAssertEqual(try search("to:da"), ["c1"])
        XCTAssertEqual(try search("to:carol"), [], "Carol only ever sends")
    }

    func testSubjectMatchesTheSubjectOnly() throws {
        try seed()
        XCTAssertEqual(try search("subject:lisbon"), ["c5", "c1"])
        XCTAssertEqual(try search("subject:\"budget review\""), ["c2"])
        XCTAssertEqual(try search("subject:\"review budget\""), [])
        XCTAssertEqual(try search("subject:ben"), [], "Ben is in bodies and senders, never a subject")
        XCTAssertEqual(try search("ben"), ["c5", "c4", "c2", "c1"], "a plain word still searches every column")
    }

    func testPlainWordsFindWhatTheyFoundAndBccNames() throws {
        try seed()
        XCTAssertEqual(try search("carter"), ["c5", "c4", "c1"], "senders and recipients, as participants did")
        XCTAssertEqual(try search("silva"), ["c6", "c2", "c1"])
        XCTAssertEqual(try search("dana"), ["c1"], "bcc names are searched now")
        XCTAssertEqual(try search("spreadsheet"), ["c2"])
        XCTAssertEqual(try search("lisbon keys"), ["c1"], "every word in one message")
    }

    func testQuotedPhrasesKeepTheirOrder() throws {
        try seed()
        XCTAssertEqual(try search("\"under the mat\""), ["c1"])
        XCTAssertEqual(try search("\"the mat under\""), [])
        XCTAssertEqual(try search("\"under the m"), ["c1"], "an open quote is a prefix")
        XCTAssertEqual(try search("\"under the m\""), [], "a closed one is not")
    }

    func testEveryPositiveTermHoldsInOneMessage() throws {
        try seed()
        XCTAssertEqual(try search("from:ben keys"), ["c1"])
        XCTAssertEqual(try search("from:ben thanks"), [], "the thanks is in the owner's answer, not in Ben's message")
        XCTAssertEqual(try search("from:ana to:ben"), [])
    }

    func testNegatedIndexTermsAreReadPerMessage() throws {
        try seed()
        XCTAssertEqual(try search("budget -spreadsheet"), [])
        XCTAssertEqual(try search("lisbon -thanks"), ["c5", "c1"], "Ben's message in c1 has no thanks")
        XCTAssertEqual(try search("-from:ben"), ["c6", "c4", "c2", "c1"], "c1 also holds the owner's answer; c5 is only Ben")
        XCTAssertEqual(try search("-from:ben", scope: [accountB]), [])
        XCTAssertEqual(try search("-\"under the mat\" lisbon"), ["c5", "c1"])
        XCTAssertEqual(try search("-carter -silva"), [], "every message outside the trash names one of them")
    }

    // MARK: Row operators

    func testFlagsTestTheRow() throws {
        try seed()
        XCTAssertEqual(try search("is:unread"), ["c1"])
        XCTAssertEqual(try search("is:read"), ["c6", "c5", "c4", "c2"])
        XCTAssertEqual(try search("-is:unread"), try search("is:read"))
        XCTAssertEqual(try search("-is:read"), ["c1"])
        XCTAssertEqual(try search("is:starred"), ["c2"])
        XCTAssertEqual(try search("-is:starred"), ["c6", "c5", "c4", "c1"])
        XCTAssertEqual(try search("has:attachment"), ["c1"])
        XCTAssertEqual(try search("-has:attachment"), ["c6", "c5", "c4", "c2"])
        XCTAssertEqual(try search("is:unread is:starred"), [], "operators combine with AND")
        XCTAssertEqual(try search("from:ben is:unread has:attachment lisbon"), ["c1"])
        XCTAssertEqual(try search("from:ana is:unread"), [])
    }

    func testDatesTestTheLatestMessageFromLocalMidnight() throws {
        try seed()
        // c6's message is at exactly midnight starting 2026-01-01: after: takes the day itself, before: does not.
        XCTAssertEqual(try search("after:2026-01-01"), ["c6"])
        XCTAssertEqual(try search("before:2026-01-01"), ["c5", "c4", "c2", "c1"])
        XCTAssertEqual(try search("before:2026-01-02"), ["c6", "c5", "c4", "c2", "c1"])
        XCTAssertEqual(try search("-after:2026-01-01"), try search("before:2026-01-01"))
        XCTAssertEqual(try search("-before:2026-01-01"), ["c6"])
        // c1's messages are on 22 and 23 December: the row's date, its latest message, decides.
        XCTAssertEqual(try search("after:2025-12-23 before:2025-12-24"), ["c1"])
        XCTAssertEqual(try search("after:2025-12-22 before:2025-12-23"), [], "Ben's own message is older than the row's date")
        XCTAssertEqual(try search("after:2025/12/27 before:2026/01/01"), ["c5", "c4", "c2"])
    }

    func testInPicksTheViewAndNegatedInNarrowsIt() throws {
        try seed()
        XCTAssertEqual(try search("lisbon"), ["c5", "c1"], "search looks through all mail but the trash")
        XCTAssertEqual(try search("invoice"), [])
        XCTAssertEqual(try search("in:trash"), ["c3"])
        XCTAssertEqual(try search("in:trash invoice", view: .starred), ["c3"], "whatever view is on screen")
        XCTAssertEqual(try search("in:sent"), ["c4", "c1"])
        XCTAssertEqual(try search("in:sent", scope: [accountB]), [])
        XCTAssertEqual(try search("in:inbox"), ["c6", "c5", "c2", "c1"])
        XCTAssertEqual(try search("in:all"), ["c6", "c5", "c4", "c2", "c1"])
        XCTAssertEqual(try search("in:drafts"), [])
        XCTAssertEqual(try search("-in:inbox"), ["c4"])
        XCTAssertEqual(try search("-in:trash"), ["c6", "c5", "c4", "c2", "c1"])
        XCTAssertEqual(try search("in:sent in:inbox"), ["c1"], "several in: terms all apply")
        XCTAssertEqual(try search("in:sent -from:ben"), ["c4", "c1"])
    }

    func testUnknownOperatorsAreWords() throws {
        try seed()
        XCTAssertEqual(try search("label:lisbon"), [], "the words label and lisbon side by side")
        XCTAssertEqual(try search("is:important"), [])
        XCTAssertEqual(try search("is:un"), ["c6", "c5", "c4", "c2", "c1"], "still being typed: the search waits for it")
    }

    /// Whatever is typed or pasted is only ever words to the index, never FTS5 syntax or an error, and both stores read
    /// the same words from it: a quote inside a word separates (`foo"bar` is foo and bar side by side), so does a quote
    /// that a combining mark or a variation selector makes one Character with, and so does NUL.
    func testQuotesAndMarksInsideWordsOnlySeparate() throws {
        try store.upsertMessages([
            message("m1", in: "c1", subject: "A 27\" display NEAR the window", from: ben, date: date(-1 * day)),
            message("m2", in: "c2", subject: "Lunch", from: ana, date: date(-2 * day)),
        ])
        try store.saveBody(body("set foo\"bar to on"), for: id("m1"))
        XCTAssertEqual(try search("foo\"bar"), ["c1"], "foo and bar side by side")
        XCTAssertEqual(try search("foo\"ba"), ["c1"], "the last word a prefix")
        XCTAssertEqual(try search("foo\"on"), [], "not side by side")
        XCTAssertEqual(try search("-foo\"bar"), ["c2"])
        XCTAssertEqual(try search("27\"display"), ["c1"])
        XCTAssertEqual(try search("NEAR\"\u{301}"), ["c1"], "a quote and a combining mark: still only a separator")
        XCTAssertEqual(try search("display\"\u{FE0F}near"), ["c1"], "a quote and a variation selector")
        XCTAssertEqual(try search("subject:\"\u{301}window"), ["c1"])
        XCTAssertEqual(try search("in\"\u{301}   2024-01-01"), [])
        XCTAssertEqual(try search("foo\u{0}bar"), ["c1"], "NUL separates words")
    }

    /// Both stores split words where FTS5's unicode61 tokenizer does, which is not where Swift's letters end: symbols
    /// Swift calls letters (Ⓐ, 🅻) separate, a private-use character (the Apple logo) belongs to its word, so does a
    /// code point Unicode 6.1 had not assigned (SQLite's tables are 6.1's: 🥳), and so does a combining accent. A term
    /// with nothing the index keeps adds nothing, where it was an empty phrase that matched no message.
    func testWordsSplitWhereTheIndexSplitsThem() throws {
        try store.upsertMessages([
            message("m1", in: "c1", subject: "Lisbon Ⓐ flat", from: ben, date: date(-1 * day)),
            message("m2", in: "c2", subject: "🅻🅸🆂🅱🅾🅽 sale", from: ana, date: date(-2 * day)),
            message("m3", in: "c3", subject: "Your \u{F8FF}TV subscription", from: ben, date: date(-3 * day)),
            message("m4", in: "c4", subject: "Party🥳 tonight", from: ana, date: date(-4 * day)),
        ])
        try store.saveBody(body("two cafe\u{301}s nearby"), for: id("m1"))
        XCTAssertEqual(try search("lisbon Ⓐ"), ["c1"], "a term of symbol letters adds nothing")
        XCTAssertEqual(try search("sale 🅻🅸🆂🅱🅾🅽"), ["c2"])
        XCTAssertEqual(try search("subject:Ⓐ lisbon"), ["c1"])
        XCTAssertEqual(try search("-Ⓐ"), ["c1", "c2", "c3", "c4"])
        XCTAssertEqual(try search("lisbonⒶflat"), ["c1"], "symbol letters separate words")
        XCTAssertEqual(try search("tv subscription"), [], "the Apple logo is part of its word")
        XCTAssertEqual(try search("\u{F8FF}tv"), ["c3"])
        XCTAssertEqual(try search("party tonight"), [], "an emoji newer than Unicode 6.1 is part of its word")
        XCTAssertEqual(try search("party🥳 tonight"), ["c4"])
        XCTAssertEqual(try search("cafes nearby"), ["c1"], "a combining accent stays in its word and folds away")
    }

    // MARK: The open conversation

    func testReadStateNeverTakesTheOpenConversationOut() throws {
        try seed()
        let c2 = ConversationID(accountID: accountA, providerID: "c2")
        let c1 = ConversationID(accountID: accountA, providerID: "c1")
        let c4 = ConversationID(accountID: accountA, providerID: "c4")
        XCTAssertEqual(try search("is:unread", open: c2), ["c2", "c1"], "read, and still listed while it is open")
        XCTAssertEqual(try search("-is:unread", open: c1).contains("c1"), true)
        XCTAssertEqual(try search("is:read", open: c1).contains("c1"), true)
        XCTAssertEqual(try search("is:unread in:inbox", open: c4), ["c1"], "only read state is waived")
        XCTAssertEqual(try search("is:unread lisbon", open: c2), ["c1"], "the words still apply")
        XCTAssertEqual(try search("lisbon", open: c2), ["c5", "c1"], "nothing changes without a read-state term")

        // Reading the open result keeps it; it goes once another conversation is open.
        try store.enqueue(Operation(accountID: accountA, change: .setRead(true), targets: [id("m1")]))
        XCTAssertEqual(try search("is:unread", open: c1), ["c1"])
        XCTAssertEqual(try search("is:unread", open: c2), ["c2"])
    }

    // MARK: Write paths

    /// Every path that writes a message or its body keeps `from:` and `to:` answering from the stored rows: a new
    /// message, a body saved whole, a body saved already evicted, an eviction, a poll that changes the sender or the
    /// recipients (Bcc included), and a delete.
    func testEveryWritePathKeepsTheSenderAndRecipientsSearchable() throws {
        var message = self.message("m1", in: "c1", subject: "Harbour", from: ben, to: [owner], date: date(-400 * day))
        message.bcc = [dana]
        try store.upsertMessages([message])
        try assertIndexed()
        XCTAssertEqual(try search("from:ben"), ["c1"])
        XCTAssertEqual(try search("to:dana"), ["c1"])

        try store.saveBody(body("lighthouse keeper"), for: id("m1"))
        try assertIndexed()
        XCTAssertEqual(try search("from:ben lighthouse"), ["c1"])

        try store.evictBodies(receivedBefore: date(-90 * day), excluding: [], limit: 10)
        try assertIndexed()
        XCTAssertEqual(try search("to:dana lighthouse"), ["c1"], "an eviction keeps the full-text row")

        try store.saveBody(body("foghorn"), for: id("m1"), evictingIfReceivedBefore: date(-90 * day))
        try assertIndexed()
        XCTAssertEqual(try search("from:ben foghorn"), ["c1"], "a body saved already evicted")
        XCTAssertEqual(try search("lighthouse"), [])

        // A poll that changes nothing the index holds but the Bcc still indexes the message again.
        message.bcc = [EmailAddress(name: "Erin Moss", address: "erin@example.com")]
        try store.upsertMessages([message])
        try assertIndexed()
        XCTAssertEqual(try search("to:dana"), [], "a changed bcc is indexed again")
        XCTAssertEqual(try search("to:erin"), ["c1"])

        message.from = ana
        try store.upsertMessages([message])
        try assertIndexed()
        XCTAssertEqual(try search("from:ben"), [])
        XCTAssertEqual(try search("from:ana foghorn"), ["c1"])

        try store.deleteMessages([id("m1")])
        try assertIndexed()
        XCTAssertEqual(try search("from:ana"), [])
    }

    /// The SQLite store's strict integrity check: the index holds exactly what the stored rows say.
    private func assertIndexed(file: StaticString = #filePath, line: UInt = #line) throws {
        guard let sqlite = store as? SQLiteMailStore else { return }
        XCTAssertNoThrow(try sqlite.verifyFullTextIndex(), file: file, line: line)
    }

}
