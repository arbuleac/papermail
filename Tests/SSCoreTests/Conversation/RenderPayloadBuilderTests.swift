import XCTest
@testable import SSCore

final class RenderPayloadBuilderTests: XCTestCase {
    private typealias F = ConversationFixtures
    private let builder = F.builder
    /// Friday 7 March 2025, 15:00 UTC.
    private let now = F.utc(2025, 3, 7, 15, 0)

    // MARK: Mapping

    func testBuildMapsMessagesOldestFirst() {
        let first = F.message("m1", date: F.utc(2025, 1, 3, 14, 5))
        let second = F.message(
            "m2",
            from: EmailAddress(name: nil, address: "grace.hopper@navy.mil"),
            to: [F.me, F.bob],
            cc: [F.carol],
            date: F.utc(2025, 3, 7, 14, 5),
            isRead: false,
            isStarred: true
        )
        let firstHTML = "<p>Hi</p><img data-ss-src=\"https://x/a.png\"><img data-ss-src=\"https://x/b.png\">"
            + "<div class=\"ss-quote\">old</div>"
        let file = AttachmentInfo(id: "att-1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 1_234_567, isInline: false)
        let inline = AttachmentInfo(id: "att-2", filename: "logo.png", mimeType: "image/png", sizeBytes: 100, contentID: "logo@cid", isInline: true)
        let bodies: [MessageID: StoredBody] = [
            first.id: F.body(html: firstHTML),
            second.id: F.body(html: "<p>Reply</p>", attachments: [file, inline]),
        ]

        let payload = builder.build(messages: [second, first], bodies: bodies, accounts: F.accounts, now: now)

        XCTAssertEqual(payload.subject, "Engines")
        XCTAssertEqual(payload.messages.map(\.id), [RenderPayload.messageKey(for: first.id), RenderPayload.messageKey(for: second.id)])

        let m1 = payload.messages[0]
        XCTAssertEqual(m1.from.name, "Ada Lovelace")
        XCTAssertEqual(m1.from.address, "ada@example.com")
        XCTAssertEqual(m1.from.initials, "AL")
        XCTAssertEqual(m1.from.tint, RenderPayloadBuilder.avatarTint(name: nil, address: "ada@example.com"))
        XCTAssertEqual(m1.to, "me")
        XCTAssertEqual(m1.cc, "")
        XCTAssertEqual(m1.recipients, [RenderPayload.RecipientField(label: "To", people: [RenderPayload.Person(name: "me", address: "me@example.com")])])
        XCTAssertEqual(m1.dateISO, "2025-01-03T14:05:00Z")
        XCTAssertEqual(m1.dateDisplay, "Fri 3 Jan")
        XCTAssertEqual(m1.bodyState, .ready)
        XCTAssertFalse(m1.isDraft)
        XCTAssertFalse(m1.isUnread)
        XCTAssertFalse(m1.isStarred)
        XCTAssertTrue(m1.hasBody)
        XCTAssertEqual(m1.html, firstHTML)
        XCTAssertTrue(m1.hasQuotedContent)
        XCTAssertEqual(m1.blockedRemoteImageCount, 2)
        XCTAssertTrue(m1.attachments.isEmpty)

        let m2 = payload.messages[1]
        XCTAssertEqual(m2.from.name, "grace.hopper")
        XCTAssertEqual(m2.from.initials, "GH")
        XCTAssertEqual(m2.to, "me, Bob")
        XCTAssertEqual(m2.cc, "Carol")
        XCTAssertEqual(m2.dateDisplay, "Today 14:05")
        XCTAssertTrue(m2.isUnread)
        XCTAssertTrue(m2.isStarred)
        XCTAssertFalse(m2.hasQuotedContent)
        XCTAssertEqual(m2.blockedRemoteImageCount, 0)
        XCTAssertEqual(m2.attachments.count, 1, "inline parts are not chips")
        XCTAssertEqual(m2.attachments.first?.id, "att-1")
        XCTAssertEqual(m2.attachments.first?.name, "plan.pdf")
        XCTAssertEqual(m2.attachments.first?.size, "1.2 MB")
        XCTAssertEqual(m2.attachments.first?.mime, "application/pdf")
        XCTAssertEqual(m2.attachments.first?.symbol, "doc")
        XCTAssertEqual(m2.attachments.first?.kind, "PDF")
        XCTAssertEqual(m2.recipients.map(\.label), ["To", "Cc"], "Bcc only on messages the user sent")
        XCTAssertEqual(payload.participants, "Ada Lovelace, Me, grace.hopper, Bob +1")
    }

    func testParticipantsLineNamesFourThenCounts() {
        let one = F.message("m1", from: F.ada, to: [F.me], cc: [F.bob])
        let two = F.message("m2", from: F.carol, to: [F.ada], date: F.utc(2025, 1, 4))
        XCTAssertEqual(RenderPayloadBuilder.participantsLine([one, two], accounts: F.accounts), "Ada Lovelace, Me, Bob, Carol")
        let three = F.message("m3", from: EmailAddress(name: "Dan", address: "dan@example.com"), to: [F.me], date: F.utc(2025, 1, 5))
        XCTAssertEqual(RenderPayloadBuilder.participantsLine([one, two, three], accounts: F.accounts), "Ada Lovelace, Me, Bob, Carol +1")
    }

    func testBccShowsOnlyOnMessagesTheUserSent() {
        var sent = F.message("m1", from: F.me, to: [F.ada], roles: [.sent])
        sent.bcc = [F.bob]
        var received = F.message("m2", from: F.ada, to: [F.me], date: F.utc(2025, 1, 4))
        received.bcc = [F.carol]
        let payload = builder.build(messages: [sent, received], bodies: [:], accounts: F.accounts, now: now)
        XCTAssertEqual(payload.messages[0].recipients.map(\.label), ["To", "Bcc"])
        XCTAssertEqual(payload.messages[0].recipients.last?.people, [RenderPayload.Person(name: "Bob", address: "bob@example.com")])
        XCTAssertEqual(payload.messages[1].recipients.map(\.label), ["To"])
    }

    func testDraftsAreMarkedAndDatedAsEdited() {
        let draft = F.message("d1", from: F.me, to: [F.ada], date: F.utc(2025, 3, 7, 9, 30), roles: [.drafts])
        let payload = builder.build(messages: [draft], bodies: [:], accounts: F.accounts, now: now)
        XCTAssertTrue(payload.messages[0].isDraft)
        XCTAssertEqual(payload.messages[0].dateDisplay, "Edited 09:30")
    }

    func testMissingBodiesCarryTheirFetchState() {
        let loading = F.message("m1")
        let offline = F.message("m2", date: F.utc(2025, 1, 4))
        let ready = F.message("m3", date: F.utc(2025, 1, 5))
        let payload = builder.build(
            messages: [loading, offline, ready], bodies: [ready.id: F.body(html: "<p>Hi</p>")], accounts: F.accounts,
            bodyStates: [offline.id: .offline, ready.id: .failed], now: now
        )
        XCTAssertEqual(payload.messages.map(\.bodyState), [.loading, .offline, .ready], "a stored body is ready whatever the fetch said")
    }

    func testPreferencesTravelInThePayload() {
        let payload = builder.build(messages: [F.message("m1")], bodies: [:], accounts: F.accounts,
                                    readingSans: true, colorsNoticeDismissed: true, now: now)
        XCTAssertTrue(payload.readingSans)
        XCTAssertTrue(payload.colorsNoticeDismissed)
    }

    func testAttachmentTypesUseOnlyReaderSymbols() {
        let cases: [(String, String, String, String)] = [
            ("plan.pdf", "application/pdf", "doc", "PDF"),
            ("cutover-runbook.docx", "application/octet-stream", "doc.richtext", "Word"),
            ("capacity-plan.numbers", "", "tablecells", "Numbers"),
            ("walkthrough.mov", "video/quicktime", "film", "QuickTime"),
            ("logs.zip", "application/zip", "doc.zipper", "Archive"),
            ("sunset.JPG", "image/jpeg", "photo", "JPEG"),
            ("noextension", "image/png", "photo", "Image"),
            ("sso-metadata.xml", "text/xml", "doc", "XML"),
        ]
        for (name, mime, symbol, kind) in cases {
            let type = RenderPayloadBuilder.attachmentType(filename: name, mimeType: mime)
            XCTAssertEqual(type.symbol, symbol, name)
            XCTAssertEqual(type.kind, kind, name)
            XCTAssertTrue(ConversationShellAssets.symbols.contains(type.symbol), name)
        }
    }

    func testSubjectComesFromFirstNonEmptyMessageUnlessOverridden() {
        let blank = F.message("m1", subject: "  ", date: F.utc(2025, 1, 1))
        let named = F.message("m2", subject: "Re: Engines", date: F.utc(2025, 1, 2))
        XCTAssertEqual(builder.build(messages: [named, blank], bodies: [:], accounts: F.accounts, now: now).subject, "Re: Engines")
        XCTAssertEqual(builder.build(messages: [blank], bodies: [:], accounts: F.accounts, now: now).subject, "")
        XCTAssertEqual(builder.build(messages: [named], bodies: [:], accounts: F.accounts, subject: "List subject", now: now).subject, "List subject")
    }

    func testTextFallbackWhenRenderedHTMLIsEmpty() {
        let message = F.message("m1")
        let payload = builder.build(
            messages: [message],
            bodies: [message.id: F.body(html: "", text: "Hello <there>\nWorld")],
            accounts: F.accounts,
            now: now
        )
        XCTAssertEqual(payload.messages[0].html, "<div class=\"ss-body ss-plain\"><p>Hello &lt;there&gt;<br>World</p></div>")
        XCTAssertTrue(payload.messages[0].hasBody)
    }

    /// m2: a fallback is set like every plain body: real paragraphs (the reading page's gap, not empty 24 pt
    /// lines), links, and folded quotes.
    func testTextFallbackHasParagraphsLinksAndQuotes() {
        let message = F.message("m1")
        let text = "Para one\n\nPara two https://example.com\n\n> quoted line"
        let payload = builder.build(messages: [message], bodies: [message.id: F.body(html: "", text: text)], accounts: F.accounts, now: now)
        let html = payload.messages[0].html
        XCTAssertTrue(html.hasPrefix("<div class=\"ss-body ss-plain\"><p>Para one</p><p>Para two "), html)
        XCTAssertFalse(html.contains("<br><br>"))
        XCTAssertTrue(html.contains("href=\"https://example.com\""), html)
        XCTAssertTrue(payload.messages[0].hasQuotedContent)
        XCTAssertEqual(payload.messages[0].typesetting, .plain)
    }

    func testPlainTextFallbackWhenOnlyExtractedTextExists() {
        let message = F.message("m1")
        let payload = builder.build(
            messages: [message],
            bodies: [message.id: F.body(html: "", text: nil, plainText: "Extracted")],
            accounts: F.accounts,
            now: now
        )
        XCTAssertEqual(payload.messages[0].html, "<div class=\"ss-body ss-plain\"><p>Extracted</p></div>")
    }

    func testSnippetFallbackWhenBodyIsMissing() {
        let message = F.message("m1", snippet: "Tom & Jerry")
        let payload = builder.build(messages: [message], bodies: [:], accounts: F.accounts, now: now)
        XCTAssertFalse(payload.messages[0].hasBody)
        XCTAssertEqual(payload.messages[0].html, "<p class=\"ss-pending\">Tom &amp; Jerry</p>")
        XCTAssertEqual(payload.messages[0].blockedRemoteImageCount, 0)
        XCTAssertFalse(payload.messages[0].hasQuotedContent)
    }

    func testUnknownSenderIsLeftForThePlaceholder() {
        // The shell sets "No sender" in the placeholder style (spec §4.1); the payload carries no made-up name.
        let message = F.message("m1", from: nil)
        let sender = builder.build(messages: [message], bodies: [:], accounts: F.accounts, now: now).messages[0].from
        XCTAssertEqual(sender.name, "")
        XCTAssertEqual(sender.address, "")
        XCTAssertEqual(sender.initials, "?")
    }

    func testVisibleMessagesDropSpamAndTrashedMessages() {
        let kept = F.message("b", date: F.utc(2025, 1, 2))
        let older = F.message("a", date: F.utc(2025, 1, 1))
        let spam = F.message("s", date: F.utc(2025, 1, 3), roles: [.spam])
        let trashed = F.message("t", date: F.utc(2025, 1, 4), roles: [.trash])
        XCTAssertEqual(
            RenderPayloadBuilder.visibleMessages([trashed, kept, spam, older]).map(\.id.providerID),
            ["a", "b"]
        )
        // A conversation that lives entirely in the trash still shows its messages.
        let otherTrashed = F.message("u", date: F.utc(2025, 1, 5), roles: [.trash])
        XCTAssertEqual(
            RenderPayloadBuilder.visibleMessages([otherTrashed, spam, trashed]).map(\.id.providerID),
            ["t", "u"]
        )
    }

    func testSameDateOrdersByProviderID() {
        let date = F.utc(2025, 1, 1)
        let ordered = RenderPayloadBuilder.visibleMessages([F.message("z", date: date), F.message("a", date: date)])
        XCTAssertEqual(ordered.map(\.id.providerID), ["a", "z"])
    }

    // MARK: Dates

    func testDateDisplayRules() {
        // Spec §4.13: "Today 09:12", "Yesterday 23:39", "Fri 30 Oct" this year, "30 Oct 2025" before it.
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 7, 14, 5), now: now), "Today 14:05")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 7, 0, 0), now: now), "Today 00:00")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 6, 9, 12), now: now), "Yesterday 09:12")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 6, 23, 59), now: now), "Yesterday 23:59")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 5, 8, 0), now: now), "Wed 5 Mar")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 1, 8, 0), now: now), "Sat 1 Mar")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 1, 2, 8, 0), now: now), "Thu 2 Jan", "this year is a weekday and a date")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2024, 12, 25, 18, 30), now: now), "25 Dec 2024")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 9, 10, 0), now: now), "9 Mar 2025", "clock skew never says Today")
    }

    func testDateDisplayFollowsTheLocalesClock() {
        let american = RenderPayloadBuilder(calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"),
                                            timeZone: TimeZone(identifier: "UTC") ?? .current)
        XCTAssertEqual(american.dateDisplay(for: F.utc(2025, 3, 7, 14, 5), now: now), "Today 2:05\u{202F}PM")
    }

    func testDateISOUsesBuilderTimeZone() {
        let message = F.message("m1", date: F.utc(2025, 3, 7, 14, 5))
        XCTAssertEqual(builder.build(messages: [message], bodies: [:], accounts: F.accounts, now: now).messages[0].dateISO, "2025-03-07T14:05:00Z")
    }

    // MARK: Initials and colors

    func testInitialsFromNames() {
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "Ada Lovelace", address: "ada@example.com"), "AL")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "ada", address: "ada@example.com"), "A")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "  mary   jane  watson ", address: ""), "MW")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "\"Bob\" (Work)", address: ""), "BW")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "émile zola", address: ""), "ÉZ")
    }

    func testInitialsFromAddressOnly() {
        XCTAssertEqual(RenderPayloadBuilder.initials(name: nil, address: "ada.lovelace@example.com"), "AL")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "", address: "grace@navy.mil"), "G")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "   ", address: "first_last-x@example.com"), "FX")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: nil, address: "42@example.com"), "4")
    }

    func testInitialsWithUnicodeAndDegenerateInput() {
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "Zoë Åström", address: ""), "ZÅ")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "李 小龙", address: ""), "李小")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "🙂", address: ""), "?")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: nil, address: ""), "?")
        XCTAssertEqual(RenderPayloadBuilder.initials(name: "---", address: "@example.com"), "?")
    }

    func testAvatarTintIsFNV1aModuloEight() {
        // The published FNV-1a 32-bit vectors, the same ones SSDesign's AvatarTintTests hold
        // `Quire.avatarTintIndex(forAddress:)` to, so the list and the reader give a sender one face.
        XCTAssertEqual(RenderPayloadBuilder.avatarTint(name: nil, address: "a"), Int(0xE40C_292C % 8))
        XCTAssertEqual(RenderPayloadBuilder.avatarTint(name: nil, address: "foobar"), Int(0xBF9C_F968 % 8))
        XCTAssertEqual(RenderPayloadBuilder.avatarTint(name: nil, address: ""), Int(0x811C_9DC5 % 8))
        let tint = RenderPayloadBuilder.avatarTint(name: "Ada", address: "Ada@Example.com")
        XCTAssertEqual(tint, RenderPayloadBuilder.avatarTint(name: "Someone Else", address: "ada@example.com"), "address decides, case-insensitively")
        XCTAssertTrue((0..<RenderPayloadBuilder.avatarTintCount).contains(tint))
    }

    // MARK: Recipients and sizes

    func testRecipientsDisplayNamesTheUserMe() {
        let own: Set<String> = ["me@example.com"]
        let recipients = [EmailAddress(name: nil, address: "ME@example.com"), F.bob, EmailAddress(name: nil, address: "dan@example.com")]
        XCTAssertEqual(RenderPayloadBuilder.recipientsDisplay(recipients, ownAddresses: own), "me, Bob, dan")
        XCTAssertEqual(RenderPayloadBuilder.recipientsDisplay([], ownAddresses: own), "")
    }

    func testSizeStrings() {
        XCTAssertEqual(RenderPayloadBuilder.sizeString(bytes: 0), "0 B")
        XCTAssertEqual(RenderPayloadBuilder.sizeString(bytes: 999), "999 B")
        XCTAssertEqual(RenderPayloadBuilder.sizeString(bytes: 1000), "1 KB")
        XCTAssertEqual(RenderPayloadBuilder.sizeString(bytes: 1234), "1.2 KB")
        XCTAssertEqual(RenderPayloadBuilder.sizeString(bytes: 45_000), "45 KB")
        XCTAssertEqual(RenderPayloadBuilder.sizeString(bytes: 1_234_567), "1.2 MB")
        XCTAssertEqual(RenderPayloadBuilder.sizeString(bytes: 10_000_000), "10 MB")
        XCTAssertEqual(RenderPayloadBuilder.sizeString(bytes: 2_500_000_000), "2.5 GB")
        XCTAssertEqual(RenderPayloadBuilder.sizeString(bytes: -5), "0 B")
    }

    func testEscapeHTML() {
        XCTAssertEqual(RenderPayloadBuilder.escapeHTML("<a href=\"x\">Tom & 'Jerry'</a>"), "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;")
    }

    /// The facts the sanitizer worked out at sync time are used as stored; scanning every body of a thread
    /// on each render cost about 100 ms for a long thread of newsletters.
    func testStoredRenderFactsAreUsedWithoutScanning() {
        let message = F.message("m1")
        var body = F.body(html: "<div class=\"ss-quote\"><img data-ss-src=\"https://x/a.png\"></div>")
        body.hasQuotedContent = false
        body.blockedRemoteImageCount = 7
        let payload = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts, loadRemoteImages: true)
        XCTAssertEqual(payload.messages[0].hasQuotedContent, false)
        XCTAssertEqual(payload.messages[0].blockedRemoteImageCount, 7)
        XCTAssertTrue(payload.loadRemoteImages)

        body.hasQuotedContent = nil
        body.blockedRemoteImageCount = nil
        let legacy = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts)
        XCTAssertEqual(legacy.messages[0].hasQuotedContent, true, "bodies stored before the facts were kept are scanned")
        XCTAssertEqual(legacy.messages[0].blockedRemoteImageCount, 1)
        XCTAssertFalse(legacy.loadRemoteImages)
    }

    // MARK: Design facts

    func testStoredDesignFactsPassThrough() {
        let plain = F.message("m1", date: F.utc(2025, 1, 1))
        let unstyled = F.message("m2", date: F.utc(2025, 1, 2))
        let styled = F.message("m3", date: F.utc(2025, 1, 3))
        func body(_ typesetting: BodyTypesetting, colors: Bool, covered: Bool) -> StoredBody {
            var body = F.body(html: "<div class=\"ss-body\">x</div>")
            body.typesetting = typesetting
            body.declaresColors = colors
            body.coveredByNewYork = covered
            return body
        }
        let payload = builder.build(
            messages: [styled, plain, unstyled],
            bodies: [
                plain.id: body(.plain, colors: false, covered: true),
                unstyled.id: body(.unstyled, colors: false, covered: false),
                styled.id: body(.styled, colors: true, covered: true),
            ],
            accounts: F.accounts,
            now: now
        )
        XCTAssertEqual(payload.messages.map(\.typesetting), [.plain, .unstyled, .styled])
        XCTAssertEqual(payload.messages.map(\.declaresColors), [false, false, true])
        XCTAssertEqual(payload.messages.map(\.coveredByNewYork), [true, false, true])
        XCTAssertEqual(payload.messages.map(\.hasBody), [true, true, true])
    }

    func testBodiesStoredBeforeTheFactsRenderStyledWithColours() {
        let message = F.message("m1")
        // A styled body that declares nothing keeps that answer; only unknown facts fall back.
        var known = F.body(html: "<p>x</p>")
        known.typesetting = .styled
        known.declaresColors = false
        known.coveredByNewYork = true
        let legacy = F.body(html: "<p>x</p>")
        let payloads = [known, legacy].map { builder.build(messages: [message], bodies: [message.id: $0], accounts: F.accounts, now: now) }
        XCTAssertEqual(payloads.map { $0.messages[0].typesetting }, [.styled, .styled])
        XCTAssertEqual(payloads.map { $0.messages[0].declaresColors }, [false, true], "NULL counts as declaring colours for a styled body")
        XCTAssertEqual(payloads.map { $0.messages[0].coveredByNewYork }, [true, false])
    }

    func testFallbacksArePlainAndCheckTheirOwnCoverage() {
        let pending = F.message("m1", snippet: "Привет, как дела?", date: F.utc(2025, 1, 1))
        let pendingCJK = F.message("m2", snippet: "会議の件", date: F.utc(2025, 1, 2))
        let textOnly = F.message("m3", date: F.utc(2025, 1, 3))
        var styledButEmpty = F.body(html: "", text: "مرحبا")
        // Facts stored for HTML that came out empty describe that HTML, not the text shown instead.
        styledButEmpty.typesetting = .styled
        styledButEmpty.declaresColors = true
        styledButEmpty.coveredByNewYork = true
        let payload = builder.build(
            messages: [pending, pendingCJK, textOnly],
            bodies: [textOnly.id: styledButEmpty],
            accounts: F.accounts,
            now: now
        )
        XCTAssertEqual(payload.messages.map(\.hasBody), [false, false, true])
        XCTAssertEqual(payload.messages.map(\.typesetting), [.plain, .plain, .plain])
        XCTAssertEqual(payload.messages.map(\.declaresColors), [false, false, false])
        XCTAssertEqual(payload.messages.map(\.coveredByNewYork), [true, false, false])
    }

    func testPayloadCarriesTheAccountsInkSlot() {
        var account = F.account
        account.inkSlot = 6
        let message = F.message("m1")
        let payload = builder.build(messages: [message], bodies: [:], accounts: [F.accountID: account], now: now)
        XCTAssertEqual(payload.inkSlot, 6)
        XCTAssertEqual(builder.build(messages: [message], bodies: [:], accounts: [:], now: now).inkSlot, 0, "unknown account")
        XCTAssertEqual(builder.build(messages: [], bodies: [:], accounts: [F.accountID: account], now: now).inkSlot, 0)
    }

    /// The sanitizer's facts survive the trip through the store into the payload unchanged.
    func testSanitizedFactsReachThePayloadThroughTheStore() throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(F.account)
        let message = F.message("m1")
        try store.upsertMessages([message])
        let source = MessageBody(html: MailShapeFixtures.newsletter, text: nil)
        let sanitized = HTMLSanitizer().sanitize(source, messageID: message.id)
        try store.saveBody(StoredBody(
            body: source, renderedHTML: sanitized.html, plainText: sanitized.plainText,
            hasQuotedContent: sanitized.hasQuotedContent, blockedRemoteImageCount: sanitized.blockedRemoteImageCount,
            typesetting: sanitized.typesetting, declaresColors: sanitized.declaresColors,
            coveredByNewYork: sanitized.coveredByNewYork
        ), for: message.id)
        let body = try XCTUnwrap(try store.body(for: message.id))
        let rendered = builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts, now: now).messages[0]
        XCTAssertEqual(rendered.typesetting, .styled)
        XCTAssertTrue(rendered.declaresColors)
        XCTAssertTrue(rendered.coveredByNewYork)
    }
}
