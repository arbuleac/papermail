import XCTest
@testable import SSCore

final class ComposeLinkAndWordingTests: XCTestCase {
    func testWebAddressesAndEmailAddressesAreAccepted() {
        XCTAssertEqual(ComposeLink.normalized("https://contoso.test/runbook"), "https://contoso.test/runbook")
        XCTAssertEqual(ComposeLink.normalized("contoso.test/runbook"), "https://contoso.test/runbook")
        XCTAssertEqual(ComposeLink.normalized("  www.contoso.com "), "https://www.contoso.com")
        XCTAssertEqual(ComposeLink.normalized("ben@contoso.test"), "mailto:ben@contoso.test")
        XCTAssertEqual(ComposeLink.normalized("mailto:ben@contoso.test"), "mailto:ben@contoso.test")
    }

    func testAnythingElseIsRejected() {
        XCTAssertNil(ComposeLink.normalized(""))
        XCTAssertNil(ComposeLink.normalized("not a link"))
        XCTAssertNil(ComposeLink.normalized("runbook"))
        XCTAssertNil(ComposeLink.normalized("ben@contoso"))
        XCTAssertNil(ComposeLink.normalized("https://"))
        // Only web schemes: a link must open a page, not run a script or reach into the recipient's disk.
        XCTAssertNil(ComposeLink.normalized("javascript://x/%0Aalert(1)"))
        XCTAssertNil(ComposeLink.normalized("javascript:alert(1)"))
        XCTAssertNil(ComposeLink.normalized("file://host/etc/passwd"))
        XCTAssertNil(ComposeLink.normalized("smb://server/share"))
        XCTAssertEqual(ComposeLink.normalized("HTTP://contoso.test"), "HTTP://contoso.test")
        XCTAssertEqual(ComposeLink.invalidMessage, "Enter a web address or an email address.")
    }

    func testSendFailuresAreSaidInPlainWords() {
        XCTAssertEqual(SendFailureWording.banner(lastError: "HTTP 413 request entity too large", provider: .microsoft),
                       "Couldn't send: Microsoft 365 rejected the attachment size.")
        XCTAssertEqual(SendFailureWording.reason(lastError: "network: The Internet connection appears to be offline.", provider: .gmail),
                       "the connection to Gmail was lost.")
        XCTAssertEqual(SendFailureWording.reason(lastError: "HTTP 401 unauthorized", provider: .gmail),
                       "Gmail needs you to sign in again.")
        XCTAssertEqual(SendFailureWording.reason(lastError: nil, provider: .gmail), "Gmail didn't accept the message.")
    }

    /// The folded original names what will be sent, with an absolute date (§5.15): never “wrote on Today”.
    func testFoldedAttributionReadsLikeTheSentHeader() {
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "Europe/London")!
        calendar.timeZone = zone
        let sent = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 39))!
        let british = Locale(identifier: "en_GB")
        let when = QuotedReply.headerDate(sent, locale: british, timeZone: zone)
        let reply = QuotedReply.Rendering(html: "", text: "", header: "On …, Ben <ben@example.com> wrote:", author: "Ben Carter", date: sent)
        XCTAssertEqual(reply.foldedAttribution(locale: british, timeZone: zone), "On \(when), Ben Carter wrote:")
        XCTAssertFalse(reply.foldedAttribution(locale: british, timeZone: zone).contains("Yesterday"))
        let forward = QuotedReply.Rendering(html: "", text: "", header: "---", author: "Ben Carter", date: sent, isForward: true)
        XCTAssertEqual(forward.foldedAttribution(locale: british, timeZone: zone), "Forwarded message from Ben Carter \u{00b7} \(when)")
        let bare = QuotedReply.Rendering(html: "", text: "", header: "On …, Ben wrote:")
        XCTAssertEqual(bare.foldedAttribution(), "On …, Ben wrote:")
    }

    func testDraftRecordsSurviveARoundTrip() throws {
        let account = AccountID("acct")
        let record = ComposeDraftRecord(
            id: UUID(), kind: .reply, originalMessageID: MessageID(accountID: account, providerID: "m1"), accountID: account,
            to: [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")], cc: [], bcc: [], subject: "Re: Rollout",
            attachments: [.init(id: UUID(), filename: "a.pdf", mimeType: "application/pdf", sizeBytes: 10, contentID: nil,
                                fileURL: URL(fileURLWithPath: "/tmp/a.pdf"), storedFile: nil)],
            quoted: QuotedReply.Rendering(html: "<p>x</p>", text: "x", author: "Ben", date: Date(timeIntervalSince1970: 1_800_000_000)),
            threading: ReplyThreading(inReplyTo: MessageID(accountID: account, providerID: "m1"), references: ["<a@b>"]),
            editedAt: Date(timeIntervalSince1970: 1_800_000_100))
        let decoded = try ComposeDraftRecord.decode(try record.encoded())
        XCTAssertEqual(decoded, record)
    }
}
