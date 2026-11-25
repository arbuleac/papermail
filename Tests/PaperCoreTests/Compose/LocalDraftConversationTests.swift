import XCTest
@testable import PaperCore

/// Drafts kept on this Mac as the Drafts view and the reader show them (spec §5.19).
final class LocalDraftConversationTests: XCTestCase {
    private let account = AccountID("acct")
    private let ben = EmailAddress(name: "Ben Carter", address: "ben@example.com")

    private func record(preview: String? = "Hello Ben", continues: MessageID? = nil) -> ComposeDraftRecord {
        ComposeDraftRecord(id: UUID(), kind: .new, originalMessageID: nil, accountID: account, to: [ben], cc: [], bcc: [],
                           subject: "Lisbon", attachments: [], quoted: nil, threading: nil,
                           editedAt: Date(timeIntervalSince1970: 1_790_000_000), preview: preview, continuesDraft: continues)
    }

    func testIdsAreMarkedAndRoundTrip() {
        let id = UUID()
        let conversation = LocalDraftConversation.conversationID(draftID: id, account: account)
        let message = LocalDraftConversation.messageID(draftID: id, account: account)
        XCTAssertTrue(LocalDraftConversation.isLocal(conversation))
        XCTAssertTrue(LocalDraftConversation.isLocal(message))
        XCTAssertEqual(LocalDraftConversation.draftID(of: conversation), id)
        XCTAssertEqual(LocalDraftConversation.draftID(of: message), id)
        XCTAssertNil(LocalDraftConversation.draftID(of: ConversationID(accountID: account, providerID: "thread-1")))
        XCTAssertFalse(LocalDraftConversation.isLocal(MessageID(accountID: account, providerID: "18c2f")))
    }

    func testTheRowAndTheMessage() {
        let record = record()
        let summary = LocalDraftConversation.summary(for: record)
        XCTAssertEqual(summary.subject, "Lisbon")
        XCTAssertEqual(summary.snippet, "Hello Ben")
        XCTAssertEqual(summary.latestDate, record.editedAt)
        XCTAssertEqual(summary.unreadCount, 0)
        XCTAssertFalse(summary.inInbox)
        let message = LocalDraftConversation.message(for: record, sender: EmailAddress(address: "me@example.com"))
        XCTAssertEqual(message.id, summary.latestMessageID)
        XCTAssertEqual(message.conversationID, summary.id)
        XCTAssertEqual(message.roles, [.drafts])
        XCTAssertTrue(message.isRead, "never marked read through the engine")
        XCTAssertEqual(ConversationRowText.recipients(in: [message], kind: .draft), [ben], "the row reads “Draft to Ben Carter”")
    }

    func testTheBodyIsTheTextAsTypedWithTheQuoteFolded() {
        let plain = LocalDraftConversation.body(text: "Hi <Ben>\nSee you", quoted: nil)
        XCTAssertTrue(plain.renderedHTML.contains("Hi &lt;Ben&gt;"), "escaped")
        XCTAssertEqual(plain.hasQuotedContent, false)
        let quoted = LocalDraftConversation.body(text: "Sounds good", quoted: QuotedReply.Rendering(html: "<p>Original</p>", text: "> Original"))
        XCTAssertTrue(quoted.renderedHTML.contains("<div class=\"ss-quote\"><p>Original</p></div>"))
        XCTAssertEqual(quoted.hasQuotedContent, true)
    }

    func testTheRecordKeepsAPreviewAndOlderRecordsStillDecode() throws {
        XCTAssertEqual(ComposeDraftRecord.preview(of: "Hello\n\n  Ben,   see you"), "Hello Ben, see you")
        XCTAssertEqual(ComposeDraftRecord.preview(of: String(repeating: "a", count: 500)).count, ComposeDraftRecord.previewLength)
        let original = MessageID(accountID: account, providerID: "r-1")
        let decoded = try ComposeDraftRecord.decode(try record(continues: original).encoded())
        XCTAssertEqual(decoded.continuesDraft, original)
        // A record written before `preview` and `continuesDraft` existed.
        var json = try JSONSerialization.jsonObject(with: try record(preview: nil).encoded()) as? [String: Any] ?? [:]
        json["preview"] = nil
        json["continuesDraft"] = nil
        let old = try ComposeDraftRecord.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.preview)
        XCTAssertNil(old.continuesDraft)
    }

    /// A draft rebuilt from the outbox says its body is the message's text as sent (Help Me Write then rewrites only a
    /// selection in it); a draft written in a composer does not carry the key at all, and neither does an older record.
    func testTheRecordSaysWhenItsBodyIsTheTextAsSent() throws {
        var rebuilt = record()
        XCTAssertNil(rebuilt.bodyIsAsSent, "not said unless it is so")
        let plain = try JSONSerialization.jsonObject(with: try rebuilt.encoded()) as? [String: Any] ?? [:]
        XCTAssertNil(plain["bodyIsAsSent"], "a composer's own draft writes no such key")
        XCTAssertNil(try ComposeDraftRecord.decode(try JSONSerialization.data(withJSONObject: plain)).bodyIsAsSent, "and an older record decodes")
        rebuilt.bodyIsAsSent = true
        XCTAssertEqual(try ComposeDraftRecord.decode(try rebuilt.encoded()).bodyIsAsSent, true)
    }

    /// A body a mail link or a Service filled in is kept as the digest of that text, never a second copy of it; a body
    /// the user began writes no such key, and a record written before it was kept decodes without one.
    func testTheRecordKeepsOnlyTheDigestOfAFilledInBody() throws {
        var filled = record()
        XCTAssertNil(filled.filledInBodyDigest)
        let plain = try JSONSerialization.jsonObject(with: try filled.encoded()) as? [String: Any] ?? [:]
        XCTAssertNil(plain["filledInBodyDigest"], "a body the user began writes no such key")
        XCTAssertNil(try ComposeDraftRecord.decode(try JSONSerialization.data(withJSONObject: plain)).filledInBodyDigest,
                     "and an older record decodes")
        let digest = String(repeating: "ab", count: 32)
        filled.filledInBodyDigest = digest
        XCTAssertEqual(try ComposeDraftRecord.decode(try filled.encoded()).filledInBodyDigest, digest)
    }
}
