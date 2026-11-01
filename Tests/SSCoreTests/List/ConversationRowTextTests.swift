import XCTest
@testable import SSCore

final class ConversationRowTextTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .current
    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()
    private lazy var formatting = DateFormatting(locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: utc)
    private lazy var now: Date = calendar.date(from: DateComponents(year: 2025, month: 3, day: 6, hour: 14, minute: 5)) ?? Date()
    private lazy var reference = formatting.reference(now: now)

    private let account = AccountID("acct-1")

    private func summary(
        id: String = "t1",
        subject: String = "Lunch?",
        snippet: String = "Are you free at noon",
        participants: [EmailAddress] = [EmailAddress(name: "Ada Lovelace", address: "ada@example.com")],
        date: Date? = nil,
        messageCount: Int = 1,
        unreadCount: Int = 0,
        isStarred: Bool = false,
        hasAttachments: Bool = false,
        hasPendingOperations: Bool = false
    ) -> ConversationSummary {
        ConversationSummary(
            id: ConversationID(accountID: account, providerID: id),
            subject: subject,
            snippet: snippet,
            participants: participants,
            latestDate: date ?? now.addingTimeInterval(-600),
            messageCount: messageCount,
            unreadCount: unreadCount,
            isStarred: isStarred,
            hasAttachments: hasAttachments,
            inInbox: true,
            inboxSection: .focused,
            latestMessageID: MessageID(accountID: account, providerID: id + "-m"),
            hasPendingOperations: hasPendingOperations
        )
    }

    private func text(_ summary: ConversationSummary) -> ConversationRowText {
        ConversationRowText(summary: summary, reference: reference, formatter: formatting)
    }

    // MARK: Content rules

    func testBasicRow() {
        let row = text(summary())
        XCTAssertEqual(row.senderLine, "Ada Lovelace")
        XCTAssertEqual(row.timeText, "13:55")
        XCTAssertEqual(row.subjectText, "Lunch?")
        XCTAssertEqual(row.snippetText, "Are you free at noon")
        XCTAssertEqual(row.initials, "AL")
        XCTAssertNil(row.countBadge)
        XCTAssertFalse(row.isUnread)
    }

    func testUnreadCountAndBadge() {
        let row = text(summary(messageCount: 4, unreadCount: 2))
        XCTAssertTrue(row.isUnread)
        XCTAssertEqual(row.countBadge, "4")
    }

    func testEmptySubjectGetsPlaceholder() {
        XCTAssertEqual(text(summary(subject: "   ")).subjectText, ConversationRowText.noSubject)
    }

    func testSnippetCollapsesToOneLine() {
        let row = text(summary(snippet: "  Hello\n\n  world\t\r\n  again \u{A0} end  "))
        XCTAssertEqual(row.snippetText, "Hello world again end")
    }

    func testSenderLineShowsLastThreeParticipantsOldestFirst() {
        let participants = ["Ann", "Ben", "Cal", "Dee"].map { EmailAddress(name: $0, address: "\($0.lowercased())@example.com") }
        XCTAssertEqual(ConversationRowText.senderLine(for: participants), "Ben, Cal, Dee")
        XCTAssertEqual(ConversationRowText.senderLine(for: Array(participants.prefix(2))), "Ann, Ben")
        XCTAssertEqual(ConversationRowText.senderLine(for: []), ConversationRowText.noSender)
    }

    func testSenderWithoutNameUsesLocalPart() {
        let row = text(summary(participants: [EmailAddress(address: "grace.hopper@navy.mil")]))
        XCTAssertEqual(row.senderLine, "grace.hopper")
        XCTAssertEqual(row.initials, "GH")
    }

    func testWhitespaceNameFallsBackToLocalPart() {
        // `shortDisplay` hands back a blank name untouched; the row must not show an empty sender.
        let row = text(summary(participants: [EmailAddress(name: "  ", address: "linus_torvalds@x")]))
        XCTAssertEqual(row.senderLine, "linus_torvalds")
        XCTAssertEqual(row.initials, "LT")
    }

    func testInitialsRules() {
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "Ada Lovelace", address: "a@x")), "AL")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "ada", address: "a@x")), "A")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "Mary-Jane O'Neil", address: "a@x")), "MJ")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "  ", address: "linus_torvalds@x")), "LT")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "éric cartman", address: "a@x")), "ÉC")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "***", address: "@@")), "?")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "42 Labs", address: "a@x")), "4L")
    }

    func testAvatarSeedIsStableAndCaseInsensitive() {
        let lower = text(summary(participants: [EmailAddress(address: "ada@example.com")]))
        let upper = text(summary(participants: [EmailAddress(name: "Ada", address: "ADA@Example.com")]))
        let other = text(summary(participants: [EmailAddress(address: "bob@example.com")]))
        XCTAssertEqual(lower.avatarSeed, upper.avatarSeed)
        XCTAssertNotEqual(lower.avatarSeed, other.avatarSeed)
        XCTAssertEqual(StableHasher.hash("ada@example.com"), lower.avatarSeed)
    }

    func testNoParticipants() {
        let row = text(summary(participants: []))
        XCTAssertEqual(row.senderLine, ConversationRowText.noSender)
        XCTAssertEqual(row.initials, "?")
    }

    // MARK: Cache key

    func testCacheKeyIsStableForEqualInput() {
        let a = ConversationRowText.cacheKey(for: summary(), dayStamp: 1)
        let b = ConversationRowText.cacheKey(for: summary(), dayStamp: 1)
        XCTAssertEqual(a, b)
    }

    func testCacheKeyChangesWithEveryVisibleField() {
        let base = ConversationRowText.cacheKey(for: summary(), dayStamp: 1)
        let variants: [ConversationSummary] = [
            summary(id: "t2"),
            summary(subject: "Dinner?"),
            summary(snippet: "Other"),
            summary(participants: [EmailAddress(name: "Bob", address: "bob@example.com")]),
            summary(date: now.addingTimeInterval(-7_200)),
            summary(messageCount: 2),
            summary(unreadCount: 1),
            summary(isStarred: true),
            summary(hasAttachments: true),
            summary(hasPendingOperations: true),
        ]
        for variant in variants {
            XCTAssertNotEqual(ConversationRowText.cacheKey(for: variant, dayStamp: 1), base, "\(variant)")
        }
        XCTAssertNotEqual(ConversationRowText.cacheKey(for: summary(), dayStamp: 2), base)
    }

    func testCacheKeyIgnoresFieldsTheRowDoesNotShow() {
        var changed = summary()
        changed.inInbox = false
        changed.inboxSection = .other
        changed.latestMessageID = MessageID(accountID: account, providerID: "other")
        XCTAssertEqual(ConversationRowText.cacheKey(for: changed, dayStamp: 1), ConversationRowText.cacheKey(for: summary(), dayStamp: 1))
    }

    func testStableHasherSeparatesAdjacentStrings() {
        var a = StableHasher()
        a.combine("ab")
        a.combine("c")
        var b = StableHasher()
        b.combine("a")
        b.combine("bc")
        XCTAssertNotEqual(a.finalized, b.finalized)
    }

    // MARK: Performance (SS_PERF=1)

    /// Builds the text of 1,000 rows. The budget is what the list needs to re-derive a whole page within the
    /// 50 ms refresh budget in docs/ARCHITECTURE.md, with room left for the attributed strings and the diff.
    func testBuildingOneThousandRowsStaysUnderFiftyMilliseconds() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the timing assertion")
        }
        let summaries = ConversationRowTextTests.syntheticSummaries(count: 1_000, account: account, now: now)
        // One build warms the formatters' ICU state, which a running app has paid for long before any refresh.
        _ = text(summaries[0])

        let start = DispatchTime.now()
        var checksum: UInt64 = 0
        for summary in summaries {
            let row = ConversationRowText(summary: summary, reference: reference, formatter: formatting)
            checksum ^= ConversationRowText.cacheKey(for: summary, dayStamp: reference.dayStamp)
            checksum &+= UInt64(row.senderLine.utf8.count + row.timeText.utf8.count + row.subjectText.utf8.count + row.snippetText.utf8.count)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        XCTAssertNotEqual(checksum, 0)
        XCTAssertLessThan(elapsed, 0.050, "building 1,000 rows took \(elapsed * 1000) ms")
    }

    /// A deterministic mailbox: fifty senders, dates spread over the past year, snippets that need collapsing.
    private static func syntheticSummaries(count: Int, account: AccountID, now: Date) -> [ConversationSummary] {
        let firstNames = ["Ada", "Grace", "Linus", "Margaret", "Dennis", "Barbara", "Ken", "Radia", "Alan", "Hedy"]
        let lastNames = ["Lovelace", "Hopper", "Torvalds", "Hamilton", "Ritchie"]
        var senders: [EmailAddress] = []
        for first in firstNames {
            for last in lastNames {
                senders.append(EmailAddress(name: "\(first) \(last)", address: "\(first.lowercased()).\(last.lowercased())@example.com"))
            }
        }
        let snippetBase = "Hi there,\n\nJust following up on the thread from last week.\tLet me know if Tuesday works for the review, otherwise we can push it.\n\nThanks!"
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        func nextRandom() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
        return (0..<count).map { index in
            let participantCount = Int(nextRandom() % 3) + 1
            let participants = (0..<participantCount).map { _ in senders[Int(nextRandom() % UInt64(senders.count))] }
            let ageSeconds = Double(nextRandom() % (400 * 86_400))
            let messageCount = Int(nextRandom() % 6) + 1
            return ConversationSummary(
                id: ConversationID(accountID: account, providerID: "thread-\(index)"),
                subject: "Re: Project update \(index % 97) and the quarterly planning document",
                snippet: snippetBase,
                participants: participants,
                latestDate: now.addingTimeInterval(-ageSeconds),
                messageCount: messageCount,
                unreadCount: Int(nextRandom() % 2),
                isStarred: nextRandom() % 5 == 0,
                hasAttachments: nextRandom() % 4 == 0,
                inInbox: true,
                inboxSection: .focused,
                latestMessageID: MessageID(accountID: account, providerID: "msg-\(index)"),
                hasPendingOperations: nextRandom() % 20 == 0
            )
        }
    }
}
