import Foundation
import SSCore
import XCTest
@testable import SSGmail

final class GmailMessageMapperTests: XCTestCase {
    private let accountID = AccountID("acct-map")

    private func decode(_ json: String) throws -> GmailMessage {
        try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    private func map(_ json: String, labels: [String]? = nil) throws -> MessageMetadata {
        var message = try decode(json)
        if let labels { message.labelIds = labels }
        return GmailMessageMapper.metadata(from: message, accountID: accountID)
    }

    func testMapsEveryField() throws {
        let metadata = try map(GmailFixtures.metadataM1)

        XCTAssertEqual(metadata.id, MessageID(accountID: accountID, providerID: "m1"))
        XCTAssertEqual(metadata.conversationID, ConversationID(accountID: accountID, providerID: "t1"))
        XCTAssertEqual(metadata.internetMessageID, "<m1@example.com>")
        XCTAssertEqual(metadata.inReplyTo, "<m0@example.com>")
        XCTAssertEqual(metadata.references, ["<root@example.com>", "<m0@example.com>"])
        XCTAssertEqual(metadata.subject, "Analytical Engine \u{2014} notes")
        XCTAssertEqual(metadata.snippet, "Hello & welcome to the team 'Ada' <3")
        XCTAssertEqual(metadata.from, EmailAddress(name: "Lovelace, Ada", address: "ada@example.com"))
        XCTAssertEqual(metadata.to, [
            EmailAddress(name: "Charles Babbage", address: "charles@example.com"),
            EmailAddress(name: nil, address: "grace@example.com"),
        ])
        XCTAssertEqual(metadata.cc, [EmailAddress(name: "Hopper, Grace", address: "grace.h@example.com")])
        XCTAssertEqual(metadata.bcc, [EmailAddress(name: nil, address: "secret@example.com")])
        XCTAssertEqual(metadata.replyTo, [EmailAddress(name: "Ada Replies", address: "reply@example.com")])
        XCTAssertEqual(metadata.date, Date(timeIntervalSince1970: 1_730_462_400))
        XCTAssertEqual(metadata.roles, [.inbox])
        XCTAssertFalse(metadata.isRead)
        XCTAssertTrue(metadata.isStarred)
        XCTAssertEqual(metadata.inboxSection, .focused)
        XCTAssertTrue(metadata.hasAttachments, "multipart/mixed is the attachment signal in metadata format")
        XCTAssertEqual(metadata.labelIDs, ["INBOX", "UNREAD", "STARRED", "CATEGORY_PERSONAL", "IMPORTANT"])
        XCTAssertNil(metadata.folderID)
        XCTAssertEqual(metadata.providerVersion, "8675000")
        XCTAssertEqual(metadata.sizeBytes, 4321)
    }

    func testPromotionsMessageIsReadUnstarredAndOther() throws {
        let metadata = try map(GmailFixtures.metadataM2)

        XCTAssertTrue(metadata.isRead)
        XCTAssertFalse(metadata.isStarred)
        XCTAssertEqual(metadata.inboxSection, .other)
        XCTAssertFalse(metadata.hasAttachments)
        XCTAssertEqual(metadata.date, Date(timeIntervalSince1970: 1_730_376_000))
        XCTAssertNil(metadata.inReplyTo)
        XCTAssertTrue(metadata.references.isEmpty)
        XCTAssertTrue(metadata.cc.isEmpty)
    }

    func testRolesComeFromSystemLabels() throws {
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["INBOX"]).roles, [.inbox])
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["SENT"]).roles, [.sent])
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["DRAFT"]).roles, [.drafts])
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["TRASH"]).roles, [.trash])
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["SPAM"]).roles, [.spam])
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["INBOX", "SENT", "Label_7"]).roles, [.inbox, .sent])
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: []).roles, [], "archived mail has no role at all")
        var unlabeled = try decode(GmailFixtures.metadataM2)
        unlabeled.labelIds = nil
        XCTAssertEqual(GmailMessageMapper.metadata(from: unlabeled, accountID: accountID).roles, [])
    }

    func testInboxSectionFromCategories() throws {
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["INBOX", "CATEGORY_PERSONAL"]).inboxSection, .focused)
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["INBOX"]).inboxSection, .focused, "no category means Primary")
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["INBOX", "CATEGORY_PROMOTIONS"]).inboxSection, .other)
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["INBOX", "CATEGORY_SOCIAL"]).inboxSection, .other)
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["INBOX", "CATEGORY_UPDATES"]).inboxSection, .other)
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["INBOX", "CATEGORY_FORUMS"]).inboxSection, .other)
        XCTAssertEqual(try map(GmailFixtures.metadataM2, labels: ["INBOX", "CATEGORY_UPDATES", "CATEGORY_PERSONAL"]).inboxSection, .focused)
    }

    func testReadAndStarredFlags() throws {
        XCTAssertTrue(try map(GmailFixtures.metadataM2, labels: ["INBOX"]).isRead)
        XCTAssertFalse(try map(GmailFixtures.metadataM2, labels: ["INBOX", "UNREAD"]).isRead)
        XCTAssertTrue(try map(GmailFixtures.metadataM2, labels: ["STARRED"]).isStarred)
        XCTAssertFalse(try map(GmailFixtures.metadataM2, labels: ["IMPORTANT"]).isStarred)
    }

    func testHasAttachmentsPrefersPartsWhenPresent() throws {
        let full = try decode(GmailFixtures.fullMessage)
        XCTAssertTrue(GmailMessageMapper.metadata(from: full, accountID: accountID).hasAttachments)

        var alternativeOnly = try decode(GmailFixtures.metadataM4)
        XCTAssertFalse(GmailMessageMapper.metadata(from: alternativeOnly, accountID: accountID).hasAttachments)
        alternativeOnly.payload?.mimeType = "multipart/mixed"
        XCTAssertTrue(GmailMessageMapper.metadata(from: alternativeOnly, accountID: accountID).hasAttachments)
    }

    func testDateFallsBackToHeaderThenEpoch() throws {
        var message = try decode(GmailFixtures.metadataM1)
        message.internalDate = nil
        XCTAssertEqual(GmailMessageMapper.metadata(from: message, accountID: accountID).date, Date(timeIntervalSince1970: 1_730_462_400))

        message.payload?.headers = [GmailHeader(name: "Date", value: "Fri, 1 Nov 2024 13:00:00 +0100 (CET)")]
        XCTAssertEqual(GmailMessageMapper.metadata(from: message, accountID: accountID).date, Date(timeIntervalSince1970: 1_730_462_400))

        message.payload?.headers = []
        XCTAssertEqual(GmailMessageMapper.metadata(from: message, accountID: accountID).date, Date(timeIntervalSince1970: 0))
    }

    func testHeaderNamesMatchCaseInsensitively() throws {
        var message = try decode(GmailFixtures.metadataM2)
        message.payload?.headers = [
            GmailHeader(name: "from", value: "Someone <someone@example.com>"),
            GmailHeader(name: "SUBJECT", value: "  spaced  "),
            GmailHeader(name: "message-id", value: " <x@y> "),
        ]
        let metadata = GmailMessageMapper.metadata(from: message, accountID: accountID)
        XCTAssertEqual(metadata.from?.address, "someone@example.com")
        XCTAssertEqual(metadata.subject, "spaced")
        XCTAssertEqual(metadata.internetMessageID, "<x@y>")
    }

    func testSnippetEntityDecoding() {
        XCTAssertEqual(GmailMessageMapper.decodeSnippet("a &amp; b"), "a & b")
        XCTAssertEqual(GmailMessageMapper.decodeSnippet("&#39;quoted&#39; &quot;double&quot;"), "'quoted' \"double\"")
        XCTAssertEqual(GmailMessageMapper.decodeSnippet("caf&#233; &#x1F600;"), "caf\u{E9} \u{1F600}")
        XCTAssertEqual(GmailMessageMapper.decodeSnippet("R&D &unknown; stays"), "R&D &unknown; stays")
        XCTAssertEqual(GmailMessageMapper.decodeSnippet("  trailing & "), "trailing &")
    }

    func testMissingHeadersProduceEmptyValues() throws {
        var message = try decode(GmailFixtures.metadataM2)
        message.payload = nil
        message.snippet = nil
        let metadata = GmailMessageMapper.metadata(from: message, accountID: accountID)
        XCTAssertEqual(metadata.subject, "")
        XCTAssertEqual(metadata.snippet, "")
        XCTAssertNil(metadata.from)
        XCTAssertTrue(metadata.to.isEmpty)
        XCTAssertFalse(metadata.hasAttachments)
    }
}
