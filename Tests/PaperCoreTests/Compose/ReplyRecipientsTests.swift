import XCTest
@testable import PaperCore

final class ReplyRecipientsTests: XCTestCase {
    private let account = AccountID("acct")
    private let me = EmailAddress(name: "Me", address: "Me@Example.com")
    private let alice = EmailAddress(name: "Alice", address: "alice@example.com")
    private let bob = EmailAddress(name: "Bob", address: "bob@example.com")
    private let carol = EmailAddress(name: "Carol", address: "carol@example.com")
    private let list = EmailAddress(name: "List", address: "list@example.com")

    private func message(from: EmailAddress?, to: [EmailAddress], cc: [EmailAddress] = [], replyTo: [EmailAddress] = []) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account, providerID: "m1"),
            conversationID: ConversationID(accountID: account, providerID: "c1"),
            subject: "Hello", snippet: "", from: from, to: to, cc: cc, replyTo: replyTo,
            date: Date(timeIntervalSince1970: 1_700_000_000), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
        )
    }

    func testReplyGoesToSenderOnly() {
        let original = message(from: alice, to: [me, bob], cc: [carol])
        let recipients = ReplyRecipients.reply(to: original, ownAddresses: ["me@example.com"])
        XCTAssertEqual(recipients.to, [alice])
        XCTAssertEqual(recipients.cc, [])
    }

    func testReplyPrefersReplyTo() {
        let original = message(from: alice, to: [me], replyTo: [list])
        let recipients = ReplyRecipients.reply(to: original, ownAddresses: ["me@example.com"])
        XCTAssertEqual(recipients.to, [list])
        let all = ReplyRecipients.replyAll(to: original, ownAddresses: ["me@example.com"])
        XCTAssertEqual(all.to, [list])
    }

    func testReplyAllAddsOriginalToAndCcWithoutSelf() {
        let original = message(from: alice, to: [me, bob], cc: [carol, me])
        let recipients = ReplyRecipients.replyAll(to: original, ownAddresses: ["me@example.com"])
        XCTAssertEqual(recipients.to, [alice, bob])
        XCTAssertEqual(recipients.cc, [carol])
    }

    func testSelfExclusionIsCaseInsensitiveAndDedupes() {
        let original = message(from: alice, to: [EmailAddress(address: "ME@EXAMPLE.COM"), alice, EmailAddress(address: "Alice@Example.com")], cc: [bob])
        let recipients = ReplyRecipients.replyAll(to: original, ownAddresses: ["me@example.com"])
        XCTAssertEqual(recipients.to, [alice])
        XCTAssertEqual(recipients.cc, [bob])
    }

    func testReplyAllDoesNotDuplicateSenderInCc() {
        let original = message(from: alice, to: [me], cc: [alice, bob])
        let recipients = ReplyRecipients.replyAll(to: original, ownAddresses: ["me@example.com"])
        XCTAssertEqual(recipients.to, [alice])
        XCTAssertEqual(recipients.cc, [bob])
    }

    func testReplyToOwnSentMessageAddressesOriginalRecipients() {
        let original = message(from: me, to: [alice, bob], cc: [carol])
        let reply = ReplyRecipients.reply(to: original, ownAddresses: ["me@example.com"])
        XCTAssertEqual(reply.to, [alice, bob])
        XCTAssertEqual(reply.cc, [])
        let all = ReplyRecipients.replyAll(to: original, ownAddresses: ["me@example.com"])
        XCTAssertEqual(all.to, [alice, bob])
        XCTAssertEqual(all.cc, [carol])
    }

    func testNoteToSelfRepliesToSelf() {
        let original = message(from: me, to: [me])
        let reply = ReplyRecipients.reply(to: original, ownAddresses: ["me@example.com"])
        XCTAssertEqual(reply.to, [me])
    }

    func testMissingSenderFallsBackToRecipients() {
        let original = message(from: nil, to: [alice])
        XCTAssertEqual(ReplyRecipients.reply(to: original, ownAddresses: ["me@example.com"]).to, [alice])
    }
}
