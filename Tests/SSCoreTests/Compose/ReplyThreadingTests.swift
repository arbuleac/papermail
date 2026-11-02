import XCTest
@testable import SSCore

final class ReplyThreadingTests: XCTestCase {
    private let owner = AccountID("a")
    private let other = AccountID("b")

    private var original: MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: owner, providerID: "m1"),
            conversationID: ConversationID(accountID: owner, providerID: "c1"),
            internetMessageID: "<orig@example.com>",
            references: ["<root@example.com>"],
            subject: "Hello", snippet: "",
            from: EmailAddress(address: "alice@example.com"),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
        )
    }

    func testReplyAnswersTheOriginalAndExtendsReferences() {
        let threading = ReplyThreading(original: original, isReply: true)
        XCTAssertEqual(threading.inReplyTo, original.id)
        XCTAssertEqual(threading.inReplyToInternetMessageID, "<orig@example.com>")
        XCTAssertEqual(threading.references, ["<root@example.com>", "<orig@example.com>"])
    }

    func testForwardReferencesWithoutAnswering() {
        let threading = ReplyThreading(original: original, isReply: false)
        XCTAssertNil(threading.inReplyToInternetMessageID)
        XCTAssertEqual(threading.references, ["<root@example.com>", "<orig@example.com>"])
    }

    func testForwardIsMarkedSoProvidersDoNotSendItAsAReply() {
        XCTAssertTrue(ReplyThreading(original: original, isReply: false).isForward)
        XCTAssertFalse(ReplyThreading(original: original, isReply: true).isForward)
    }

    func testHeadersApplyOnlyFromTheOwningAccount() {
        // Switching From to another account must not forget the headers (an undone send reopens with the
        // chosen account), but that account cannot use them, so they are withheld there and only there.
        let threading = ReplyThreading(original: original, isReply: true)
        XCTAssertEqual(threading.applicable(to: owner), threading)
        XCTAssertNil(threading.applicable(to: other))
    }
}
