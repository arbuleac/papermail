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
        XCTAssertTrue(RenderPayloadBuilder.palette.contains(m1.from.color))
        XCTAssertEqual(m1.to, "me")
        XCTAssertEqual(m1.cc, "")
        XCTAssertEqual(m1.dateISO, "2025-01-03T14:05:00Z")
        XCTAssertEqual(m1.dateDisplay, "3 Jan 2025 14:05")
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
        XCTAssertEqual(payload.messages[0].html, "<div class=\"ss-plain\">Hello &lt;there&gt;<br>World</div>")
        XCTAssertTrue(payload.messages[0].hasBody)
    }

    func testPlainTextFallbackWhenOnlyExtractedTextExists() {
        let message = F.message("m1")
        let payload = builder.build(
            messages: [message],
            bodies: [message.id: F.body(html: "", text: nil, plainText: "Extracted")],
            accounts: F.accounts,
            now: now
        )
        XCTAssertEqual(payload.messages[0].html, "<div class=\"ss-plain\">Extracted</div>")
    }

    func testSnippetFallbackWhenBodyIsMissing() {
        let message = F.message("m1", snippet: "Tom & Jerry")
        let payload = builder.build(messages: [message], bodies: [:], accounts: F.accounts, now: now)
        XCTAssertFalse(payload.messages[0].hasBody)
        XCTAssertEqual(payload.messages[0].html, "<p class=\"ss-pending\">Tom &amp; Jerry</p>")
        XCTAssertEqual(payload.messages[0].blockedRemoteImageCount, 0)
        XCTAssertFalse(payload.messages[0].hasQuotedContent)
    }

    func testUnknownSenderGetsPlaceholder() {
        let message = F.message("m1", from: nil)
        let sender = builder.build(messages: [message], bodies: [:], accounts: F.accounts, now: now).messages[0].from
        XCTAssertEqual(sender.name, "Unknown sender")
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
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 7, 14, 5), now: now), "Today 14:05")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 7, 0, 0), now: now), "Today 00:00")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 6, 9, 12), now: now), "Yesterday 09:12")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 6, 23, 59), now: now), "Yesterday 23:59")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 5, 8, 0), now: now), "Wed 5 Mar")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 4, 8, 0), now: now), "Tue 4 Mar")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 1, 8, 0), now: now), "Sat 1 Mar", "six days ago is still a weekday")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 2, 28, 8, 0), now: now), "28 Feb 2025 08:00", "a week ago is a full date")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2024, 12, 25, 18, 30), now: now), "25 Dec 2024 18:30")
        XCTAssertEqual(builder.dateDisplay(for: F.utc(2025, 3, 9, 10, 0), now: now), "9 Mar 2025 10:00", "clock skew never says Today")
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

    func testAvatarColorIsStableAndFromPalette() {
        let color = RenderPayloadBuilder.avatarColor(name: "Ada", address: "Ada@Example.com")
        XCTAssertTrue(RenderPayloadBuilder.palette.contains(color))
        XCTAssertEqual(color, RenderPayloadBuilder.avatarColor(name: "Someone Else", address: "ada@example.com"), "address decides, case-insensitively")
        XCTAssertEqual(RenderPayloadBuilder.avatarColor(name: "Only Name", address: ""), RenderPayloadBuilder.avatarColor(name: "Only Name", address: ""))
        XCTAssertTrue(RenderPayloadBuilder.palette.contains(RenderPayloadBuilder.avatarColor(name: nil, address: "")))
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
}
