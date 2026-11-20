import XCTest
@testable import SSCore

/// What Help Me Write sends about a conversation: which messages, how each is written, and the user's name.
final class ReplyContextBuilderTests: XCTestCase {
    private let gmail = Account(id: AccountID("acct-g"), kind: .gmail, email: "alex@example.test", displayName: "alex",
                                addedAt: Date(timeIntervalSince1970: 0))
    private let outlook = Account(id: AccountID("acct-m"), kind: .microsoft, email: "alex@work.test", displayName: "Alex Morgan",
                                  addedAt: Date(timeIntervalSince1970: 0))
    private let priya = EmailAddress(name: "Priya Shah", address: "priya@example.test")
    private let start = Date(timeIntervalSince1970: 1_795_000_000)

    private func message(_ number: Int, from: EmailAddress?, account: AccountID? = nil, to: [EmailAddress] = [],
                         subject: String = "Lunch", snippet: String = "", roles: Set<MailboxRole> = [.inbox],
                         hasAttachments: Bool = false, minutes: Int? = nil) -> MessageMetadata {
        let accountID = account ?? gmail.id
        return MessageMetadata(
            id: MessageID(accountID: accountID, providerID: "m\(number)"),
            conversationID: ConversationID(accountID: accountID, providerID: "c1"),
            subject: subject, snippet: snippet, from: from, to: to,
            date: start.addingTimeInterval(Double((minutes ?? number) * 60)),
            roles: roles, isRead: true, isStarred: false, hasAttachments: hasAttachments
        )
    }

    private func build(_ messages: [MessageMetadata], target: MessageID? = nil, ask: WriteAsk = WriteAsk(),
                       accounts: [Account]? = nil, limits: ReplyContextBuilder.Limits = .standard, knownUserName: String? = nil,
                       bodies: [String: ReplyContextBuilder.Body] = [:]) -> ReplyContext {
        ReplyContextBuilder(accounts: accounts ?? [gmail], limits: limits, knownUserName: knownUserName)
            .build(messages: messages, replyingTo: target, ask: ask) { bodies[$0.id.providerID] }
    }

    // MARK: Messages

    func testOwnWordsAuthorsDatesAndTheTargetAreSent() {
        let messages = [
            message(1, from: priya, subject: "Lunch on Thursday"),
            message(2, from: EmailAddress(name: "Alex Morgan", address: "ALEX@example.test"), subject: "Re: Lunch on Thursday"),
            message(3, from: priya, subject: "Re: Lunch on Thursday", hasAttachments: true),
        ]
        let context = build(messages, bodies: [
            "m1": .init(plainText: "Could we move lunch to Thursday?"),
            "m2": .init(plainText: "Let me check.\n\nOn Tue, Priya Shah wrote:\n> Could we move lunch to Thursday?"),
            "m3": .init(plainText: "Any news?\r\n> Let me check.", attachmentCount: 2),
        ])
        XCTAssertEqual(context.subject, "Lunch on Thursday")
        XCTAssertEqual(context.messages.map(\.author), ["Priya Shah", "you", "Priya Shah"])
        XCTAssertEqual(context.messages.map(\.text), ["Could we move lunch to Thursday?", "Let me check.", "Any news?"])
        XCTAssertEqual(context.messages.map(\.isFromUser), [false, true, false])
        XCTAssertEqual(context.messages.map(\.isReplyTarget), [false, false, true])
        XCTAssertEqual(context.messages.map(\.attachmentCount), [0, 0, 2])
        XCTAssertEqual(context.messages.first?.date, messages[0].date)
        XCTAssertEqual(context.omittedCount, 0)
    }

    func testDraftsAreLeftOutAndOrderIsByDate() {
        let messages = [
            message(3, from: priya),
            message(9, from: EmailAddress(address: "alex@example.test"), roles: [.drafts]),
            message(1, from: priya),
        ]
        let context = build(messages, bodies: ["m1": .init(plainText: "first"), "m3": .init(plainText: "second")])
        XCTAssertEqual(context.messages.map(\.text), ["first", "second"])
    }

    func testAMissingBodySendsTheSnippetAsAPreview() {
        let context = build([message(1, from: priya, snippet: "Could we move", hasAttachments: true)])
        XCTAssertEqual(context.messages.first?.text, "Could we move")
        XCTAssertEqual(context.messages.first?.isPreview, true)
        XCTAssertEqual(context.messages.first?.attachmentCount, 1)
    }

    func testAnUnknownSenderIsSomeoneAtTheirDomain() {
        let context = build([
            message(1, from: EmailAddress(address: "noreply@Billing.Contoso.test")),
            message(2, from: EmailAddress(name: "\"bob@contoso.test\"", address: "bob@contoso.test")),
            message(3, from: nil),
        ])
        XCTAssertEqual(context.messages.map(\.author), ["someone at billing.contoso.test", "someone at contoso.test", "someone"])
    }

    func testAddressesInBodiesBecomeTheNamesTheThreadGivesThem() {
        let context = build([message(1, from: priya, to: [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")])],
                            bodies: ["m1": .init(plainText: "Copying ben@contoso.test and sam@contoso.test, see https://contoso.test/x")])
        XCTAssertEqual(context.messages.first?.text, "Copying Ben Carter and an address at contoso.test, see [link: contoso.test]")
    }

    func testTheSubjectIsRedactedToo() {
        let context = build([message(1, from: priya, subject: "Your verification code is 482913")])
        XCTAssertEqual(context.subject, "Your verification code is [code]")
    }

    // MARK: Caps

    func testOnlyTheLastEightAreSentNewestLast() {
        let messages = (1...12).map { message($0, from: priya) }
        let context = build(messages, bodies: Dictionary(uniqueKeysWithValues: (1...12).map { ("m\($0)", .init(plainText: "text \($0)")) }))
        XCTAssertEqual(context.messages.map(\.text), (5...12).map { "text \($0)" })
        XCTAssertEqual(context.omittedCount, 4)
        XCTAssertEqual(context.messages.last?.isReplyTarget, true)
    }

    func testAnOlderTargetIsAlwaysKept() {
        let messages = (1...12).map { message($0, from: priya) }
        let bodies = Dictionary(uniqueKeysWithValues: (1...12).map { ("m\($0)", ReplyContextBuilder.Body(plainText: "text \($0)")) })
        let context = build(messages, target: messages[1].id, bodies: bodies)
        XCTAssertEqual(context.messages.map(\.text), ["text 2"] + (6...12).map { "text \($0)" })
        XCTAssertEqual(context.messages.first?.isReplyTarget, true)
        XCTAssertEqual(context.messages.filter(\.isReplyTarget).count, 1)
    }

    func testAnUnknownTargetMeansTheLatest() {
        let messages = [message(1, from: priya), message(2, from: priya)]
        let context = build(messages, target: MessageID(accountID: gmail.id, providerID: "gone"))
        XCTAssertEqual(context.messages.map(\.isReplyTarget), [false, true])
    }

    func testTheOldestGoFirstWhenTheTextIsTooLong() {
        let limits = ReplyContextBuilder.Limits(maxMessages: 8, maxCharacters: 1_100)
        let messages = (1...4).map { message($0, from: priya) }
        let bodies = Dictionary(uniqueKeysWithValues: (1...4).map { ("m\($0)", ReplyContextBuilder.Body(plainText: String(repeating: "\($0)", count: 300))) })
        let context = build(messages, limits: limits, bodies: bodies)
        // 300 characters and a 60-character header each: three fit in 1,100, so the oldest goes.
        XCTAssertEqual(context.messages.map { $0.text.first }, ["2", "3", "4"])
        XCTAssertEqual(context.omittedCount, 1)
    }

    func testATargetTooLongAloneIsCutNotDropped() {
        let limits = ReplyContextBuilder.Limits(maxMessages: 8, maxCharacters: 500)
        let messages = [message(1, from: priya), message(2, from: priya)]
        let context = build(messages, target: messages[0].id, limits: limits,
                            bodies: ["m1": .init(plainText: String(repeating: "a", count: 5_000)), "m2": .init(plainText: "newer")])
        XCTAssertEqual(context.messages.count, 1)
        let only = try? XCTUnwrap(context.messages.first)
        XCTAssertEqual(only?.isReplyTarget, true)
        XCTAssertTrue(only?.text.hasSuffix(ReplyContextBuilder.cutMarker) == true)
        XCTAssertLessThanOrEqual((only?.text.count ?? .max) + ReplyContextBuilder.headerAllowance, 500)
    }

    func testBlankLinesAreFolded() {
        let context = build([message(1, from: priya)], bodies: ["m1": .init(plainText: "\n\nHi,\n\n\n\n  \nSee you.\n\n")])
        XCTAssertEqual(context.messages.first?.text, "Hi,\n\nSee you.")
    }

    // MARK: The user's name

    func testTheFirstNameComesFromTheUsersOwnMessages() {
        let messages = [message(1, from: priya), message(2, from: EmailAddress(name: "Alex Morgan", address: "alex@example.test"))]
        XCTAssertEqual(build(messages).userFirstName, "Alex")
    }

    func testTheFirstNameComesFromHowOthersAddressTheUser() {
        let messages = [message(1, from: priya, to: [EmailAddress(name: "Morgan, Alex", address: "alex@example.test")])]
        XCTAssertEqual(build(messages).userFirstName, "Alex")
    }

    func testAGmailDisplayNameIsNeverUsedButAMicrosoftOneIs() {
        XCTAssertNil(build([message(1, from: priya)]).userFirstName)
        XCTAssertEqual(build([message(1, from: priya)], knownUserName: "Sam Lee").userFirstName, "Sam")
        let fromWork = message(1, from: priya, account: outlook.id)
        XCTAssertEqual(build([fromWork], accounts: [gmail, outlook]).userFirstName, "Alex")
    }

    func testANameThatIsAnAddressIsNoName() {
        let messages = [message(1, from: EmailAddress(name: "alex@example.test", address: "alex@example.test"))]
        XCTAssertNil(build(messages).userFirstName)
        XCTAssertNil(ReplyContextBuilder.firstWord(of: "  "))
        XCTAssertNil(ReplyContextBuilder.firstWord(of: "1234"))
    }

    // MARK: The ask

    func testTheAskIsTheUsersWordsWithoutInvisibleCharacters() {
        let ask = WriteAsk(instruction: "  make it warm\u{200B} ", draft: .notes("thursday ok, email me at alex@example.test\n"))
        let context = build([message(1, from: priya)], ask: ask)
        XCTAssertEqual(context.ask.instruction, "make it warm")
        // The user's own notes are not redacted: an address they typed is one they want in the reply.
        XCTAssertEqual(context.ask.draft, .notes("thursday ok, email me at alex@example.test"))
    }

    func testBlankNotesOrSelectionMeanAnEmptyDraft() {
        XCTAssertEqual(build([message(1, from: priya)], ask: WriteAsk(draft: .notes(" \n "))).ask.draft, .empty)
        XCTAssertEqual(build([message(1, from: priya)], ask: WriteAsk(draft: .selection("\u{200B}"))).ask.draft, .empty)
    }

    func testTheAskIsCapped() {
        let limits = ReplyContextBuilder.Limits(maxAskCharacters: 10)
        let context = build([message(1, from: priya)], ask: WriteAsk(instruction: String(repeating: "x", count: 50),
                                                                     draft: .selection(String(repeating: "y", count: 50))), limits: limits)
        XCTAssertEqual(context.ask.instruction.count, 10)
        XCTAssertEqual(context.ask.draft, .selection(String(repeating: "y", count: 10)))
    }

    func testAnEmptyConversationStillCarriesTheAsk() {
        let context = build([], ask: WriteAsk(instruction: "hello"), knownUserName: "Sam")
        XCTAssertEqual(context.messages, [])
        XCTAssertEqual(context.ask.instruction, "hello")
        XCTAssertEqual(context.userFirstName, "Sam")
    }
}
