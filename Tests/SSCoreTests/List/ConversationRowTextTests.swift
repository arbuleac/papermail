import XCTest
@testable import SSCore

final class ConversationRowTextTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .current
    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()
    private lazy var formatting = DateFormatting(locale: Locale(identifier: "en_GB"), calendar: calendar, timeZone: utc)
    private lazy var now: Date = calendar.date(from: DateComponents(year: 2025, month: 3, day: 6, hour: 14, minute: 5)) ?? Date()
    private lazy var reference = formatting.reference(now: now)

    private let account = AccountID("acct-1")
    private let me = EmailAddress(name: "Alex Morgan", address: "alex@contoso.test")

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
        inboxSection: InboxSection = .focused,
        hasPendingOperations: Bool = false,
        failedOperation: OperationKind? = nil
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
            inboxSection: inboxSection,
            latestMessageID: MessageID(accountID: account, providerID: id + "-m"),
            hasPendingOperations: hasPendingOperations,
            failedOperation: failedOperation
        )
    }

    private func text(_ summary: ConversationSummary, _ context: ConversationRowText.Context = .init()) -> ConversationRowText {
        ConversationRowText(summary: summary, reference: reference, formatter: formatting, context: context)
    }

    private func message(_ id: String, from: EmailAddress?, to: [EmailAddress] = [], cc: [EmailAddress] = [],
                         roles: Set<MailboxRole> = [.inbox], minutesAgo: Double = 10) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account, providerID: id),
            conversationID: ConversationID(accountID: account, providerID: "t1"),
            subject: "Lunch?",
            snippet: "",
            from: from,
            to: to,
            cc: cc,
            date: now.addingTimeInterval(-minutesAgo * 60),
            roles: roles,
            isRead: true,
            isStarred: false,
            hasAttachments: false
        )
    }

    // MARK: Content rules

    func testBasicRow() {
        let row = text(summary())
        XCTAssertEqual(row.senderLine, "Ada Lovelace")
        XCTAssertNil(row.senderPrefix)
        XCTAssertFalse(row.isSenderPlaceholder)
        XCTAssertEqual(row.timeText, "13:55")
        XCTAssertEqual(row.subjectText, "Lunch?")
        XCTAssertFalse(row.isSubjectPlaceholder)
        XCTAssertEqual(row.snippetText, "Are you free at noon")
        XCTAssertEqual(row.initials, "AL")
        XCTAssertEqual(row.avatarAddress, "ada@example.com")
        XCTAssertNil(row.messageCount)
        XCTAssertFalse(row.isUnread)
        XCTAssertEqual(row.status, .none)
    }

    func testUnreadAndMessageCount() {
        let row = text(summary(messageCount: 4, unreadCount: 2))
        XCTAssertTrue(row.isUnread)
        XCTAssertEqual(row.messageCount, 4)
        XCTAssertNil(text(summary(messageCount: 1)).messageCount, "one message shows no count")
    }

    func testTimeFollowsTheHeadStyle() {
        let yesterday = now.addingTimeInterval(-86_400)
        XCTAssertEqual(text(summary(date: yesterday)).timeText, "Yesterday")
        XCTAssertEqual(text(summary(date: yesterday), .init(timeStyle: .timeOfDay)).timeText, "14:05")
    }

    func testMissingSubjectAndSenderUsePlaceholders() {
        let row = text(summary(subject: "  \n ", participants: []))
        XCTAssertEqual(row.subjectText, "No subject")
        XCTAssertTrue(row.isSubjectPlaceholder)
        XCTAssertEqual(row.senderLine, "No sender")
        XCTAssertTrue(row.isSenderPlaceholder)
        XCTAssertEqual(row.initials, "?")
    }

    func testSnippetAndSubjectCollapseToOneLine() {
        let row = text(summary(subject: " Re:\n  plans ", snippet: "  Hello\n\n  world\t\r\n  again \u{A0} end  "))
        XCTAssertEqual(row.snippetText, "Hello world again end")
        XCTAssertEqual(row.subjectText, "Re: plans")
    }

    func testSenderLineShowsLastThreeParticipantsOldestFirst() {
        let participants = ["Ann", "Ben", "Cal", "Dee"].map { EmailAddress(name: $0, address: "\($0.lowercased())@example.com") }
        XCTAssertEqual(ConversationRowText.senderLine(for: participants), "Ben, Cal, Dee")
        XCTAssertEqual(ConversationRowText.senderLine(for: Array(participants.prefix(2))), "Ann, Ben")
        XCTAssertEqual(ConversationRowText.senderLine(for: []), ConversationRowText.noSender)
    }

    func testTheUserReadsMe() {
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let tom = EmailAddress(name: "Tom Hughes", address: "tom@contoso.test")
        let shouting = EmailAddress(name: "Alex Morgan", address: "ALEX@Contoso.test")
        let context = ConversationRowText.Context(ownAddresses: ["alex@contoso.test"])
        XCTAssertEqual(text(summary(participants: [ben, shouting, tom]), context).senderLine, "Ben Carter, me, Tom Hughes")
        XCTAssertEqual(text(summary(participants: [ben, me, tom])).senderLine, "Ben Carter, Alex Morgan, Tom Hughes",
                       "without own addresses nobody is me")
    }

    func testSenderWithoutNameUsesLocalPart() {
        let row = text(summary(participants: [EmailAddress(address: "grace.hopper@navy.mil")]))
        XCTAssertEqual(row.senderLine, "grace.hopper")
        XCTAssertEqual(row.initials, "G")
    }

    func testWhitespaceNameFallsBackToLocalPart() {
        // `shortDisplay` hands back a blank name untouched; the row must not show an empty sender.
        let row = text(summary(participants: [EmailAddress(name: "  ", address: "linus_torvalds@x")]))
        XCTAssertEqual(row.senderLine, "linus_torvalds")
        XCTAssertEqual(row.initials, "L")
    }

    /// Spec §4.3: first and last word of the display name, else the first letter or digit of the address.
    func testInitialsRules() {
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "Ada Lovelace", address: "a@x")), "AL")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "Ada King Lovelace", address: "a@x")), "AL")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "ada", address: "a@x")), "A")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "Mary-Jane O'Neil", address: "a@x")), "MO")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "Lovelace, Ada", address: "a@x")), "LA")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "  ", address: "linus_torvalds@x")), "L")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "éric cartman", address: "a@x")), "ÉC")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "***", address: "@@")), "?")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(name: "42 Labs", address: "a@x")), "4L")
        XCTAssertEqual(ConversationRowText.initials(for: EmailAddress(address: "_42@x")), "4")
    }

    // MARK: Faces

    func testTheFaceIsTheMostRecentSenderWhoIsNotTheUser() {
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let tom = EmailAddress(name: "Tom Hughes", address: "tom@contoso.test")
        let own: Set<String> = ["alex@contoso.test"]
        let messages = [
            message("1", from: tom, minutesAgo: 50),
            message("2", from: ben, minutesAgo: 40),
            message("3", from: me, minutesAgo: 30),
        ]
        XCTAssertEqual(ConversationRowText.latestSender(in: messages, ownAddresses: own), ben)
        XCTAssertEqual(ConversationRowText.latestSender(in: [message("1", from: me)], ownAddresses: own), me,
                       "a thread only the user wrote shows the user")
        XCTAssertNil(ConversationRowText.latestSender(in: [], ownAddresses: own))

        let row = text(summary(participants: [tom, ben, me]), .init(ownAddresses: own, latestSender: ben))
        XCTAssertEqual(row.initials, "BC")
        XCTAssertEqual(row.avatarAddress, "ben@contoso.test")
        // Without a read, the newest distinct sender stands in.
        XCTAssertEqual(text(summary(participants: [tom, ben])).initials, "BC")
    }

    func testAvatarAddressIsLowercasedForTheTint() {
        let row = text(summary(participants: [EmailAddress(name: "Ada", address: "ADA@Example.com")]))
        XCTAssertEqual(row.avatarAddress, "ada@example.com")
    }

    // MARK: Drafts and Sent

    func testDraftsAndSentNameTheRecipients() {
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let draft = text(summary(participants: [me]), .init(kind: .draft, recipients: [ben]))
        XCTAssertEqual(draft.senderPrefix, "Draft to")
        XCTAssertEqual(draft.senderNames, "Ben Carter")
        XCTAssertEqual(draft.senderLine, "Draft to Ben Carter")
        XCTAssertEqual(draft.initials, "BC", "the face is the recipient's")

        let sent = text(summary(participants: [me]), .init(kind: .sent, recipients: [ben]))
        XCTAssertEqual(sent.senderLine, "To Ben Carter")

        let empty = text(summary(participants: [me]), .init(kind: .draft))
        XCTAssertEqual(empty.senderLine, "Draft", "a draft with nobody on it yet")
    }

    func testRecipientsComeFromTheNewestMessageInTheRole() {
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let priya = EmailAddress(name: "Priya Raman", address: "priya@contoso.test")
        let messages = [
            message("1", from: me, to: [priya], roles: [.sent], minutesAgo: 50),
            message("2", from: me, cc: [ben], roles: [.sent], minutesAgo: 40),
            message("3", from: priya, to: [me], roles: [.inbox], minutesAgo: 30),
        ]
        XCTAssertEqual(ConversationRowText.recipients(in: messages, kind: .sent), [ben], "To is empty, so Cc")
        XCTAssertEqual(ConversationRowText.recipients(in: messages, kind: .received), [])
    }

    // MARK: Marks

    /// Rows never show the provider's Focused/Other category (spec §5.7): an Other conversation reads exactly as a
    /// Focused one, to VoiceOver too, while the summary keeps the category for the provider.
    /// The context has no way left to ask for the category; `InboxShowsAllMailTests` checks the rows the list
    /// itself configures, in the Inbox where the tag used to show.
    func testTheCategoryNeverShowsOnARow() {
        let other = text(summary(inboxSection: .other))
        let focused = text(summary(inboxSection: .focused))
        XCTAssertEqual(other.accessibilityLabel, focused.accessibilityLabel)
        XCTAssertFalse(other.accessibilityLabel.contains("Other"))
        XCTAssertEqual(other.senderLine, focused.senderLine)
        XCTAssertEqual(other.status, focused.status)
    }

    func testQueuedAndFailedStatus() {
        XCTAssertEqual(text(summary(hasPendingOperations: true)).status, .queued)
        XCTAssertEqual(text(summary(failedOperation: .archive)).status, .failed(.archive))
        XCTAssertEqual(text(summary(hasPendingOperations: true, failedOperation: .trash)).status, .failed(.trash),
                       "the triangle replaces the queued glyph")
        XCTAssertEqual(ConversationRowText.failureText(for: .archive), "Couldn't archive")
        XCTAssertEqual(ConversationRowText.failureText(for: .markUnread), "Couldn't mark as unread")
        XCTAssertEqual(ConversationRowText.failureText(for: .unstar), "Couldn't unstar")
    }

    func testVoiceOverLabel() {
        let priya = EmailAddress(name: "Priya Raman", address: "priya@example.com")
        let row = text(summary(subject: "Lisbon in March?", snippet: "Booked the flat", participants: [priya],
                               messageCount: 3, unreadCount: 1, isStarred: true, hasPendingOperations: true),
                       .init(accountName: "Gmail"))
        XCTAssertEqual(row.accessibilityLabel,
                       "Unread. Starred. Priya Raman. Lisbon in March? Booked the flat. 13:55. 3 messages. Waiting to sync. Gmail account.")
        let failed = text(summary(failedOperation: .archive))
        XCTAssertTrue(failed.accessibilityLabel.contains("Couldn't archive."))
    }

    // MARK: Cache key

    func testCacheKeyIsStableForEqualInput() {
        let a = ConversationRowText.cacheKey(for: summary(), dayStamp: 1)
        let b = ConversationRowText.cacheKey(for: summary(), dayStamp: 1)
        XCTAssertEqual(a, b)
    }

    func testCacheKeyChangesWithEveryVisibleField() {
        let base = ConversationRowText.cacheKey(for: summary(), dayStamp: 1)
        var newMessage = summary()
        newMessage.latestMessageID = MessageID(accountID: account, providerID: "other")
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
            summary(failedOperation: .archive),
            newMessage,
        ]
        for variant in variants {
            XCTAssertNotEqual(ConversationRowText.cacheKey(for: variant, dayStamp: 1), base, "\(variant)")
        }
        XCTAssertNotEqual(ConversationRowText.cacheKey(for: summary(), dayStamp: 2), base)
    }

    func testCacheKeyIgnoresFieldsTheRowDoesNotShow() {
        var changed = summary()
        changed.inInbox = false
        XCTAssertEqual(ConversationRowText.cacheKey(for: changed, dayStamp: 1), ConversationRowText.cacheKey(for: summary(), dayStamp: 1))
        // The category round-trips provider state only; no row shows it.
        XCTAssertEqual(ConversationRowText.cacheKey(for: summary(inboxSection: .other), dayStamp: 1),
                       ConversationRowText.cacheKey(for: summary(), dayStamp: 1))
    }

    func testContextAndEnvironmentAreInTheExtendedKey() {
        let environment = "light|ic0|g0|newYork"
        let base = ConversationRowText.cacheKey(for: summary(), dayStamp: 1, context: .init(), environment: environment)
        let contexts: [ConversationRowText.Context] = [
            .init(kind: .sent),
            .init(timeStyle: .timeOfDay),
            .init(ownAddresses: ["ada@example.com"]),
            .init(accountName: "Gmail"),
        ]
        for context in contexts {
            XCTAssertNotEqual(ConversationRowText.cacheKey(for: summary(), dayStamp: 1, context: context, environment: environment),
                              base, "\(context)")
        }
        for other in ["dark|ic0|g0|newYork", "light|ic1|g0|newYork", "light|ic0|g1|newYork", "light|ic0|g0|sfPro"] {
            XCTAssertNotEqual(ConversationRowText.cacheKey(for: summary(), dayStamp: 1, context: .init(), environment: other), base)
        }
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
        let context = ConversationRowText.Context(timeStyle: .timeOfDay, ownAddresses: ["ada.lovelace@example.com"])
        for summary in summaries {
            let row = ConversationRowText(summary: summary, reference: reference, formatter: formatting, context: context)
            checksum ^= ConversationRowText.cacheKey(for: summary, dayStamp: reference.dayStamp, context: context, environment: "light|ic0|g0")
            checksum &+= UInt64(row.senderLine.utf8.count + row.timeText.utf8.count + row.subjectText.utf8.count + row.snippetText.utf8.count)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        XCTAssertNotEqual(checksum, 0)
        XCTAssertLessThan(elapsed, 0.050, "building 1,000 rows took \(elapsed * 1000) ms")
    }

    /// A deterministic mailbox: fifty senders, dates spread over the past year, snippets that need collapsing.
    static func syntheticSummaries(count: Int, account: AccountID, now: Date) -> [ConversationSummary] {
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
