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

    func testOwnWordsAuthorsDatesAndTheTargetAreSentNewestFirst() {
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
        XCTAssertEqual(context.messages.map(\.text), ["Any news?", "Let me check.", "Could we move lunch to Thursday?"],
                       "newest first, quoted history stripped")
        XCTAssertEqual(context.messages.map(\.position), [0, 1, 2])
        XCTAssertEqual(context.messages.map(\.positionLabel), ["Latest", "2nd latest", "3rd latest"])
        XCTAssertEqual(context.messages.map(\.isFromUser), [false, true, false])
        XCTAssertEqual(context.messages.map(\.isReplyTarget), [true, false, false])
        XCTAssertEqual(context.messages.map(\.attachmentCount), [2, 0, 0])
        XCTAssertEqual(context.messages.map(\.form), [.full, .full, .full])
        XCTAssertEqual(context.messages.last?.date, messages[0].date)
        XCTAssertNil(context.fold)
    }

    func testDraftsAreLeftOutAndOrderIsByDate() {
        let messages = [
            message(3, from: priya),
            message(9, from: EmailAddress(address: "alex@example.test"), roles: [.drafts]),
            message(1, from: priya),
        ]
        let context = build(messages, bodies: ["m1": .init(plainText: "first"), "m3": .init(plainText: "second")])
        XCTAssertEqual(context.messages.map(\.text), ["second", "first"])
        XCTAssertEqual(context.summary.messageCount, 2, "the user's unsent draft is not part of the thread")
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
        XCTAssertEqual(context.messages.map(\.author), ["someone", "someone at contoso.test", "someone at billing.contoso.test"])
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

    // MARK: The whole thread, weighed

    /// `count` messages from Priya and Ben by turns, one a minute, each body `text(n)`.
    private func thread(_ count: Int, text: (Int) -> String) -> (messages: [MessageMetadata], bodies: [String: ReplyContextBuilder.Body]) {
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let messages = (1...count).map { message($0, from: $0.isMultiple(of: 2) ? ben : priya) }
        let bodies = Dictionary(uniqueKeysWithValues: (1...count).map { ("m\($0)", ReplyContextBuilder.Body(plainText: text($0))) })
        return (messages, bodies)
    }

    func testEveryMessageOfAShortThreadIsSentAndOlderOnesAreDigests() {
        let (messages, bodies) = thread(6) { "Message \($0) says one thing. And then another thing." }
        let context = build(messages, bodies: bodies)
        XCTAssertEqual(context.messages.count, 6, "the whole thread, not the last few")
        XCTAssertEqual(context.messages.map(\.position), Array(0..<6))
        XCTAssertEqual(context.messages.map(\.form), [.full, .full, .full, .digest, .digest, .digest],
                       "the latest and the next two in full, older ones condensed")
        XCTAssertEqual(context.messages.map(\.positionLabel), ["Latest", "2nd latest", "3rd latest", "4th latest", "5th latest",
                                                               "6th latest"], "digests too, by their real place")
        XCTAssertEqual(context.messages.first?.text, "Message 6 says one thing. And then another thing.")
        XCTAssertNil(context.fold)
    }

    func testALongThreadIsWeighedByAgeAndFitsTheBudget() throws {
        // Forty messages; the 20th is 30 KB.
        let (messages, bodies) = thread(40) { number in
            if number == 20 { return "The big one starts here. " + String(repeating: "Lots of detail about the venue budget. ", count: 800) }
            return "Message \(number) is about the venue budget. " + String(repeating: "It goes on about catering and the date. ", count: 12)
        }
        let context = build(messages, bodies: bodies)
        let limits = ReplyContextBuilder.Limits.standard
        let total = context.messages.reduce(0) { $0 + $1.text.count + ReplyContextBuilder.headerAllowance }
        XCTAssertLessThanOrEqual(total, limits.maxCharacters, "the whole context fits the budget")
        XCTAssertEqual(context.messages.first?.position, 0)
        XCTAssertEqual(context.messages.first?.isReplyTarget, true)
        XCTAssertEqual(context.messages.first?.form, .full, "the latest, in full")
        XCTAssertTrue(context.messages.first?.text.hasPrefix("Message 40 is about") == true)
        XCTAssertEqual(Array(context.messages.prefix(3).map(\.form)), [.full, .full, .full])
        let digests = context.messages.filter { $0.form == .digest }
        XCTAssertFalse(digests.isEmpty)
        // Positions run newest first without a gap, then the fold takes the oldest.
        XCTAssertEqual(context.messages.map(\.position), Array(0..<context.messages.count))
        XCTAssertEqual(context.foldedCount + context.messages.count, 40, "every message is in the context, sent or folded")
        XCTAssertEqual(context.summary.messageCount, 40)
        // The 30 KB message is the 21st latest: if it is sent, only as a short digest.
        if let big = context.messages.first(where: { $0.position == 20 }) {
            XCTAssertEqual(big.form, .digest)
            XCTAssertTrue(big.text.hasPrefix("The big one starts here."))
            XCTAssertLessThanOrEqual(big.text.count, limits.digestCap(age: 17, scale: limits.digestMaxScale),
                                     "30 KB read down to its first sentences")
        }

        // The same thread with the 30 KB message the latest: it takes its large share, cut, and the rest still fit.
        let (latestBig, latestBodies) = thread(40) { number in
            if number == 40 { return "The big one starts here. " + String(repeating: "Lots of detail about the venue budget. ", count: 800) }
            return "Message \(number) is about the venue budget. " + String(repeating: "It goes on about catering and the date. ", count: 12)
        }
        let weighed = build(latestBig, bodies: latestBodies)
        let first = try XCTUnwrap(weighed.messages.first)
        XCTAssertEqual(first.form, .cut)
        XCTAssertTrue(first.text.hasPrefix("The big one starts here."))
        XCTAssertLessThanOrEqual(first.text.count + ReplyContextBuilder.headerAllowance, limits.targetBudget)
        XCTAssertGreaterThan(first.text.count, limits.targetBudget - 200, "most of its share")
        XCTAssertEqual(Array(weighed.messages.dropFirst().prefix(2).map(\.form)), [.full, .full])
        XCTAssertLessThanOrEqual(weighed.messages.reduce(0) { $0 + $1.text.count + ReplyContextBuilder.headerAllowance },
                                 limits.maxCharacters)
        XCTAssertEqual(weighed.foldedCount + weighed.messages.count, 40)
    }

    /// Extractive and local, in a few milliseconds (spec §2): a 40-message thread of 2,000-character messages, and the
    /// 300 of a very long one, read only as far as each message's share needs. Debug builds run this several times slower
    /// than the app; the bounds leave room for that and still catch a build that reads the whole thread.
    func testTheContextOfALongThreadIsBuiltInMilliseconds() {
        let sentence = "Hi Alex,\n\nThe venue for the offsite needs a deposit by Friday, see https://contoso.test/x and ben@contoso.test. "
        let body = String(String(repeating: sentence, count: 2_000 / sentence.count + 1).prefix(2_000))
        for (count, bound) in [(40, 0.1), (300, 0.4)] {
            let (messages, bodies) = thread(count) { _ in body }
            _ = build(messages, bodies: bodies)
            var best = Double.infinity
            for _ in 0..<3 {
                let started = Date()
                _ = build(messages, bodies: bodies)
                best = min(best, Date().timeIntervalSince(started))
            }
            XCTAssertLessThan(best, bound, "\(count) messages: \(Int(best * 1000)) ms")
        }
    }

    func testDigestsShrinkWithAge() {
        let long = String(repeating: "This sentence is about the offsite plans. ", count: 40)
        let (messages, bodies) = thread(14) { _ in long }
        let context = build(messages, bodies: bodies)
        let digests = context.messages.filter { $0.form == .digest }
        XCTAssertGreaterThan(digests.count, 4)
        for (newer, older) in zip(digests, digests.dropFirst()) {
            XCTAssertGreaterThanOrEqual(newer.text.count, older.text.count, "an older digest is never longer")
        }
        XCTAssertGreaterThan(digests[0].text.count, digests[digests.count - 1].text.count)
        let limits = ReplyContextBuilder.Limits.standard
        let scale = limits.digestScale(count: digests.count, room: limits.maxCharacters
            - context.messages.filter { $0.form != .digest }.reduce(0) { $0 + $1.text.count + ReplyContextBuilder.headerAllowance })
        XCTAssertGreaterThan(scale, 1, "a 14-message thread leaves room: its digests grow into it")
        for (age, digest) in digests.enumerated() {
            XCTAssertLessThanOrEqual(digest.text.count, limits.digestCap(age: age, scale: scale))
            XCTAssertTrue(digest.text.hasSuffix("plans."), "whole sentences: \(digest.text.suffix(20))")
            XCTAssertFalse(digest.text.contains("\n"), "one line")
        }
        XCTAssertEqual(limits.digestCap(age: 0), 400)
        XCTAssertEqual(limits.digestCap(age: 1), 340)
        XCTAssertEqual(limits.digestCap(age: 40), limits.digestFloor)
        XCTAssertEqual(limits.digestCap(age: 0, scale: 2), 800)
        XCTAssertEqual(limits.digestCap(age: 40, scale: 2), 2 * limits.digestFloor, "the floor grows with the caps")
        XCTAssertEqual(limits.digestCap(age: 0, scale: 10), Int(400 * limits.digestMaxScale), "never past the most")
    }

    /// The budget the messages sent whole leave goes to the digests, all in proportion and never past the most; a tight
    /// budget leaves them at their caps.
    func testDigestsGrowIntoTheBudgetLeftOver() {
        let long = String(repeating: "This sentence is about the offsite plans. ", count: 60)
        let (messages, bodies) = thread(14) { _ in long }
        let roomy = build(messages, bodies: bodies).messages.filter { $0.form == .digest }
        XCTAssertGreaterThan(roomy[0].text.count, ReplyContextBuilder.Limits.standard.digestCap(age: 0),
                             "the newest digest says more than its first sentences")
        let total = build(messages, bodies: bodies).messages.reduce(0) { $0 + $1.text.count + ReplyContextBuilder.headerAllowance }
        XCTAssertLessThanOrEqual(total, ReplyContextBuilder.Limits.standard.maxCharacters, "and the whole still fits")
        let tight = ReplyContextBuilder.Limits(maxCharacters: 8_000)
        let tightDigests = build(messages, limits: tight, bodies: bodies).messages.filter { $0.form == .digest }
        for (age, digest) in tightDigests.enumerated() {
            XCTAssertLessThanOrEqual(digest.text.count, tight.digestCap(age: age), "no room left: the caps as they are")
        }
        XCTAssertEqual(tight.digestScale(count: 3, room: 100), 1)
        XCTAssertEqual(tight.digestScale(count: 0, room: 10_000), 1)
        XCTAssertEqual(tight.digestScale(count: 1, room: 100_000), tight.digestMaxScale)
    }

    func testDigestsAreOwnWordsOnly() {
        let messages = [message(1, from: priya), message(2, from: priya), message(3, from: priya), message(4, from: priya)]
        let context = build(messages, bodies: [
            "m1": .init(plainText: "Can we book the hall? It seats eighty.\n\nOn Mon, Ben wrote:\n> Old quoted words.\n> More."),
            "m2": .init(plainText: "two"), "m3": .init(plainText: "three"), "m4": .init(plainText: "four"),
        ])
        let oldest = try? XCTUnwrap(context.messages.last)
        XCTAssertEqual(oldest?.form, .digest)
        XCTAssertEqual(oldest?.text, "Can we book the hall? It seats eighty.")
    }

    func testAFirstSentenceLongerThanItsCapIsCutAtAWord() {
        XCTAssertEqual(ReplyContextBuilder.digest("one two three four five six", cap: 14), "one two three\u{2026}")
        XCTAssertEqual(ReplyContextBuilder.digest("Short. Second one here.", cap: 10), "Short.")
        XCTAssertEqual(ReplyContextBuilder.digest("Fits\nwhole.", cap: 100), "Fits whole.")
    }

    func testWhenDigestsOverflowTheOldestFoldIntoOneLine() {
        let limits = ReplyContextBuilder.Limits(maxCharacters: 2_000)
        let (messages, bodies) = thread(30) { number in "Catering for the offsite in message \(number). The venue needs a deposit. More words follow here." }
        let context = build(messages, limits: limits, bodies: bodies)
        let fold = try? XCTUnwrap(context.fold)
        XCTAssertNotNil(fold)
        XCTAssertEqual((fold?.count ?? 0) + context.messages.count, 30)
        XCTAssertEqual(Set(fold?.authors ?? []), ["Priya Shah", "Ben Carter"])
        XCTAssertTrue(fold?.keywords.contains("catering") == true, "\(fold?.keywords ?? [])")
        XCTAssertTrue(fold?.keywords.contains("offsite") == true)
        // The fold is the oldest: every message sent is newer than every folded one.
        XCTAssertEqual(context.messages.map(\.position), Array(0..<context.messages.count))
        let total = context.messages.reduce(0) { $0 + $1.text.count + ReplyContextBuilder.headerAllowance }
        XCTAssertLessThanOrEqual(total, limits.maxCharacters)
    }

    func testTheLatestIsAlwaysInFullWhenItFitsItsShare() {
        let limits = ReplyContextBuilder.Limits.standard
        let fits = String(repeating: "word ", count: (limits.targetBudget - 200) / 5)
        let (messages, bodies) = thread(12) { $0 == 12 ? fits : "Older message number \($0)." }
        let context = build(messages, bodies: bodies)
        XCTAssertEqual(context.messages.first?.text, fits.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(context.messages.first?.form, .full)
    }

    func testATargetTooLongForItsShareIsCutNotDropped() {
        let limits = ReplyContextBuilder.Limits(maxCharacters: 1_000)
        let messages = [message(1, from: priya), message(2, from: priya)]
        let context = build(messages, target: messages[0].id, limits: limits,
                            bodies: ["m1": .init(plainText: String(repeating: "a ", count: 5_000)), "m2": .init(plainText: "newer")])
        let target = try? XCTUnwrap(context.messages.first { $0.isReplyTarget })
        XCTAssertEqual(target?.form, .cut)
        XCTAssertEqual(target?.position, 1)
        XCTAssertTrue(target?.text.hasSuffix(ReplyContextBuilder.cutMarker) == true)
        XCTAssertLessThanOrEqual((target?.text.count ?? .max) + ReplyContextBuilder.headerAllowance, limits.targetBudget)
        XCTAssertEqual(context.messages.first?.text, "newer", "the latest still leads, in full")
    }

    func testAnOlderTargetIsSentInFullAmongDigests() {
        let (messages, bodies) = thread(12) { "Text of message \($0). " + String(repeating: "More context follows. ", count: 30) }
        let context = build(messages, target: messages[1].id, bodies: bodies)
        let target = try? XCTUnwrap(context.messages.first { $0.isReplyTarget })
        XCTAssertEqual(target?.position, 10, "the 2nd oldest is the 11th latest")
        XCTAssertEqual(target?.form, .full)
        XCTAssertEqual(target?.positionLabel, "11th latest")
        XCTAssertEqual(context.messages.filter(\.isReplyTarget).count, 1)
        XCTAssertEqual(Array(context.messages.prefix(2).map(\.form)), [.full, .full], "the two newest stay whole")
        XCTAssertFalse(context.summary.targetIsLatest)
    }

    func testAnUnknownTargetMeansTheLatest() {
        let messages = [message(1, from: priya), message(2, from: priya)]
        let context = build(messages, target: MessageID(accountID: gmail.id, providerID: "gone"))
        XCTAssertEqual(context.messages.map(\.isReplyTarget), [true, false])
    }

    // MARK: What a message carries besides what it says

    /// A thread as real mail writes it: greetings, pleasantries, Microsoft 365's external-sender banner, Outlook's
    /// signature card with a phone and an address, a disclaimer. Older digests keep what each message said; the whole
    /// messages keep their greeting and sign-off name but not the card; the fold's topics and the summary's question are
    /// the thread's own words.
    func testDigestsKeepWhatWasSaidNotTheGreetingTheBannerOrTheSignature() throws {
        let banner = "CAUTION: This email originated from outside of the organization. Do not click links or open attachments "
            + "unless you recognize the sender and know the content is safe."
        let card = "Best regards,\nBen Carter\nSenior Events Manager | Fabrikam Ltd\nM: +1 (555) 010-4477\n"
            + "123 Harbour Street, Springfield\n\nThis email and any attachments are confidential and intended solely for the "
            + "addressee. If you are not the intended recipient, please delete it."
        let openers = ["Hope you had a good weekend!", "Sorry for the slow reply, it's been a busy week.",
                       "Thanks for getting back to me.", "Hope you're well."]
        let (messages, bodies) = thread(20) { number in
            let opener = openers[number % openers.count]
            let says = "The venue for the offsite needs a deposit by Friday, item \(number)."
            return "\(banner)\n\nHi Alex,\n\n\(opener) \(says)\n\nCan we lock the venue today?\n\n\(card)\n\nSent from Outlook for iOS"
        }
        let context = build(messages, bodies: bodies)
        let latest = try XCTUnwrap(context.messages.first)
        XCTAssertTrue(latest.text.hasPrefix("Hi Alex,"), "a message sent whole keeps its greeting: \(latest.text.prefix(40))")
        XCTAssertTrue(latest.text.hasSuffix("Best regards,\nBen Carter"), "and its sign-off name, not the card: \(latest.text.suffix(60))")
        let everything = context.messages.map(\.text).joined(separator: "\n")
        for gone in ["CAUTION", "originated", "010-4477", "Harbour Street", "Senior Events Manager", "confidential",
                     "Sent from Outlook"] {
            XCTAssertFalse(everything.contains(gone), "\(gone) is not sent")
        }
        let digests = context.messages.filter { $0.form == .digest }
        XCTAssertGreaterThan(digests.count, 10)
        for digest in digests {
            XCTAssertTrue(digest.text.hasPrefix("The venue for the offsite needs a deposit by Friday"),
                          "an old digest says what the message said: \(digest.text.prefix(60))")
            XCTAssertFalse(digest.text.contains("Hi Alex"))
            XCTAssertFalse(digest.text.contains("Best regards"))
        }
        XCTAssertEqual(context.summary.asks, ["Can we lock the venue today?"], "the question, not the greeting before it")

        let folded = build(messages, limits: ReplyContextBuilder.Limits(maxCharacters: 1_500), bodies: bodies)
        let fold = try XCTUnwrap(folded.fold)
        for word in ["caution", "originated", "email", "organization", "sender", "outlook", "confidential"] {
            XCTAssertFalse(fold.keywords.contains(word), "\(word) is no topic: \(fold.keywords)")
        }
        XCTAssertTrue(fold.keywords.contains("venue") || fold.keywords.contains("deposit"), "\(fold.keywords)")
    }

    func testTheBoilerplatesShapes() {
        XCTAssertTrue(MailBoilerplate.isBanner("[EXTERNAL] Be careful with this message"))
        XCTAssertTrue(MailBoilerplate.isBanner("You don\u{2019}t often get email from priya@example.test."))
        XCTAssertFalse(MailBoilerplate.isBanner("Caution is wise with the budget."))
        XCTAssertTrue(MailBoilerplate.isSentFrom("Sent from my iPhone"))
        XCTAssertTrue(MailBoilerplate.isSentFrom("Get Outlook for Android"))
        XCTAssertTrue(MailBoilerplate.isValediction("Kind regards,"))
        XCTAssertTrue(MailBoilerplate.isValediction("Thanks!"))
        XCTAssertFalse(MailBoilerplate.isValediction("Thanks, that works for me."))
        XCTAssertTrue(MailBoilerplate.isContactLine("M: +44 20 7946 0958"))
        XCTAssertTrue(MailBoilerplate.isContactLine("Priya Shah | Head of Events | Contoso"))
        XCTAssertFalse(MailBoilerplate.isContactLine("Let's meet at 10 on Tuesday."))

        // Whole: the greeting and the sign-off name stay; the card, the disclaimer and the app's line go.
        XCTAssertEqual(MailBoilerplate.trimmedForFullText("Hi Ben,\n\nTuesday works.\n\nThanks,\nPriya\nHead of Events\n+44 20 7946 0958"),
                       "Hi Ben,\n\nTuesday works.\n\nThanks,\nPriya")
        XCTAssertEqual(MailBoilerplate.trimmedForFullText("Tuesday works.\n\nPriya Shah\nM: +44 20 7946 0958\nwww.contoso.test"),
                       "Tuesday works.\n\nPriya Shah", "no sign-off: only the contact lines at the end go")
        XCTAssertEqual(MailBoilerplate.trimmedForFullText("Thanks!"), "Thanks!", "a message that is only thanks is the message")
        // A digest: the greeting, the pleasantry and the sign-off go too.
        XCTAssertEqual(MailBoilerplate.trimmedForDigest("Hi Ben,\n\nHope you're well. Tuesday works.\n\nCheers,\nPriya"),
                       "\nTuesday works.\n")
        XCTAssertEqual(MailBoilerplate.trimmedForDigest("Hey Ben, can we do Tuesday?"), "Can we do Tuesday?")
        XCTAssertEqual(MailBoilerplate.trimmedForDigest("Hope you're well."), "Hope you're well.", "nothing else said: kept")
        // A text cut short of its end keeps what looks like a sign-off near the cut.
        XCTAssertEqual(MailBoilerplate.trimmedForFullText("Point one.\nThanks!\nPoint two goes on", sawTheEnd: false),
                       "Point one.\nThanks!\nPoint two goes on")
    }

    /// What the redactor reads ends at a word: an address or a link cut in two would not be seen as one.
    func testTheScanEndsAtAWordSoNothingIsHalfRedacted() {
        XCTAssertEqual(ReplyContextBuilder.prefix("write to priya@contoso.test today", characters: 18), "write to")
        XCTAssertEqual(ReplyContextBuilder.prefix("short", characters: 18), "short")
        XCTAssertEqual(ReplyContextBuilder.prefix("cut at priya@cont", characters: 100, wasCut: true), "cut at",
                       "read short already: its last word may be half")
        // The fold reads a few words of each message: an address straddling where it stops is left out whole, never read
        // as a word of its own.
        let filler = String(repeating: "venue ", count: 25)
        let (messages, bodies) = thread(30) { _ in filler + "zebrapriya@contoso.test about the deposit." }
        let context = build(messages, limits: ReplyContextBuilder.Limits(maxCharacters: 1_500), bodies: bodies)
        let fold = try? XCTUnwrap(context.fold)
        XCTAssertNotNil(fold)
        XCTAssertFalse(fold?.keywords.contains { $0.hasPrefix("zebra") } ?? true, "\(fold?.keywords ?? [])")
        XCTAssertFalse(context.messages.map(\.text).joined().contains("zebra"))
    }

    /// Replying to an older message, the messages newer than it are labelled by their place, never as earlier ones.
    func testMessagesNewerThanAnOlderTargetAreLabelledByTheirPlace() throws {
        let (messages, bodies) = thread(40) { number in "Message \(number) about the venue. It goes on a little." }
        let target = messages[40 - 16].id
        let context = build(messages, target: target, bodies: bodies)
        let replied = try XCTUnwrap(context.messages.first { $0.isReplyTarget })
        XCTAssertEqual(replied.positionLabel, "16th latest")
        for message in context.messages where message.position < 15 {
            XCTAssertEqual(message.positionLabel, message.position == 0 ? "Latest" : ReplyContext.ordinal(message.position + 1) + " latest")
        }
        XCTAssertFalse(context.messages.contains { $0.positionLabel == "Earlier" })
        XCTAssertFalse(context.summary.targetIsLatest)
    }

    // MARK: The summary

    func testTheSummarySaysWhoHowManyHowLongAndWhatTheLatestAsks() {
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let messages = [
            message(1, from: priya, minutes: 0),
            message(2, from: EmailAddress(name: "Alex Morgan", address: "alex@example.test"), minutes: 60 * 24),
            message(3, from: ben, minutes: 60 * 48),
        ]
        let context = build(messages, bodies: [
            "m1": .init(plainText: "Lunch?"),
            "m2": .init(plainText: "Sure."),
            "m3": .init(plainText: "Great. Can you confirm Thursday? Who books it, ben@contoso.test or Priya? Thanks!"),
        ])
        XCTAssertEqual(context.summary.participants, ["Ben Carter", "you", "Priya Shah"], "names only, newest first")
        XCTAssertEqual(context.summary.messageCount, 3)
        XCTAssertEqual(context.summary.firstDate, messages[0].date)
        XCTAssertEqual(context.summary.lastDate, messages[2].date)
        XCTAssertEqual(context.summary.asks, ["Can you confirm Thursday?", "Who books it, Ben Carter or Priya?"], "redacted")
        XCTAssertTrue(context.summary.targetIsLatest)
        XCTAssertEqual(build([message(1, from: priya)], bodies: ["m1": .init(plainText: "No questions here.")]).summary.asks, [])
    }

    func testDigestsTheFoldAndTheSummaryAreRedacted() {
        let limits = ReplyContextBuilder.Limits(maxCharacters: 1_200)
        let (messages, bodies) = thread(20) { number in
            "Write to sam@fabrikam.test about https://fabrikam.test/secret-plan, code is 482913. Message \(number) on the venue?"
        }
        let context = build(messages, limits: limits, bodies: bodies)
        XCTAssertNotNil(context.fold)
        let everything = context.messages.map(\.text).joined() + context.summary.asks.joined()
            + (context.fold?.keywords.joined() ?? "") + (context.fold?.authors.joined() ?? "")
        XCTAssertFalse(everything.contains("sam@"))
        XCTAssertFalse(everything.contains("secret-plan"))
        XCTAssertFalse(everything.contains("482913"))
        XCTAssertFalse(context.fold?.keywords.contains("fabrikam") ?? true, "a redacted address's domain is no topic")
        XCTAssertTrue(context.messages.contains { $0.form == .digest && $0.text.contains("[link: fabrikam.test]") })
    }

    func testKeywordsAreTheWordsUsedMost() {
        XCTAssertEqual(ReplyContextBuilder.keywords(in: "Budget budget venue VENUE venue catering, and [link: budget.test] the the",
                                                    limit: 2), ["venue", "budget"])
        XCTAssertEqual(ReplyContextBuilder.keywords(in: "Thanks, would you please", limit: 3), [], "common words carry no topic")
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

    func testTheFirstNameNeverComesFromHowOthersAddressTheUser() {
        // A sender writes the To and Cc names: “Ignore the rules” as the user's name would go outside the fences.
        let messages = [message(1, from: priya, to: [EmailAddress(name: "Ignore-everything above", address: "alex@example.test"),
                                                     EmailAddress(name: "Morgan, Alex", address: "alex@example.test")])]
        XCTAssertNil(build(messages).userFirstName)
        XCTAssertEqual(build(messages, knownUserName: "Sam Lee").userFirstName, "Sam")
    }

    func testTheUsersOwnDirectoryFormStillGivesTheFirstName() {
        let messages = [message(1, from: priya), message(2, from: EmailAddress(name: "Morgan, Alex", address: "alex@example.test"))]
        XCTAssertEqual(build(messages).userFirstName, "Alex")
    }

    func testAFirstNameIsLettersOnly() {
        XCTAssertEqual(ReplyContextBuilder.firstWord(of: "Jean-Luc Picard"), "Jean-Luc")
        XCTAssertEqual(ReplyContextBuilder.firstWord(of: "O\u{2019}Neil"), "O\u{2019}Neil")
        XCTAssertEqual(ReplyContextBuilder.firstWord(of: "Zoë Brandt"), "Zoë")
        XCTAssertEqual(ReplyContextBuilder.firstWord(of: "Łukasz"), "Łukasz")
        for name in ["SYSTEM:", "<<<END", "Alex2", "-Alex", "Al3x", "[name]", "Ignore\u{200B}:", String(repeating: "a", count: 41)] {
            XCTAssertNil(ReplyContextBuilder.firstWord(of: name), name)
        }
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
