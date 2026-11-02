import XCTest
@testable import SSCore

final class QuickReplyComposerTests: XCTestCase {
    private typealias F = ConversationFixtures

    func testReplyToWinsOverSender() {
        let latest = F.message("m1", from: F.ada, replyTo: [F.bob, EmailAddress(name: nil, address: "BOB@example.com"), F.carol])
        XCTAssertEqual(QuickReplyComposer.replyRecipients(to: latest, accounts: F.accounts).map(\.address), ["bob@example.com", "carol@example.com"])
    }

    func testSenderIsTheDefaultRecipient() {
        let latest = F.message("m1", from: F.ada, to: [F.me, F.bob])
        XCTAssertEqual(QuickReplyComposer.replyRecipients(to: latest, accounts: F.accounts), [F.ada])
    }

    func testOwnMessageRepliesToItsRecipients() {
        let latest = F.message("m1", from: EmailAddress(name: "Me", address: "ME@example.com"), to: [F.bob, F.carol])
        XCTAssertEqual(QuickReplyComposer.replyRecipients(to: latest, accounts: F.accounts), [F.bob, F.carol])
        let note = F.message("m2", from: F.me, to: [])
        XCTAssertEqual(QuickReplyComposer.replyRecipients(to: note, accounts: F.accounts), [F.me], "a note to self stays a note to self")
        XCTAssertEqual(QuickReplyComposer.replyRecipients(to: F.message("m3", from: nil, to: []), accounts: F.accounts), [])
    }

    func testReplyAllCopiesEveryoneElseWithoutTheUser() {
        let latest = F.message("m1", from: F.ada, to: [F.me, F.bob], cc: [F.carol, EmailAddress(name: nil, address: "ADA@example.com")])
        let all = QuickReplyComposer.replyAllRecipients(to: latest, accounts: F.accounts)
        XCTAssertEqual(all.to, [F.ada])
        XCTAssertEqual(all.cc, [F.bob, F.carol], "the sender once, the user never")
        XCTAssertTrue(QuickReplyComposer.replyAllAvailable(for: latest, accounts: F.accounts))
        XCTAssertEqual(QuickReplyComposer.replyAllTargetName(for: latest, accounts: F.accounts), "Ada Lovelace and 2 others")
        let message = QuickReplyComposer.outgoingMessage(text: "Hi", replyingTo: latest, accounts: F.accounts, all: true)
        XCTAssertEqual(message.to, [F.ada])
        XCTAssertEqual(message.cc, [F.bob, F.carol])
    }

    func testReplyAllIsUnavailableWithOneOtherParticipant() {
        let latest = F.message("m1", from: F.ada, to: [F.me])
        XCTAssertFalse(QuickReplyComposer.replyAllAvailable(for: latest, accounts: F.accounts))
        XCTAssertEqual(QuickReplyComposer.outgoingMessage(text: "Hi", replyingTo: latest, accounts: F.accounts).cc, [])
    }

    func testReplyTargetName() {
        XCTAssertEqual(QuickReplyComposer.replyTargetName(for: F.message("m1", from: F.ada), accounts: F.accounts), "Ada Lovelace")
        XCTAssertEqual(QuickReplyComposer.replyTargetName(for: F.message("m2", from: F.me, to: [F.bob, F.carol]), accounts: F.accounts), "Bob and 1 more")
        XCTAssertEqual(QuickReplyComposer.replyTargetName(for: F.message("m3", from: nil, to: []), accounts: F.accounts), "")
    }

    func testReplySubject() {
        XCTAssertEqual(QuickReplyComposer.replySubject(for: "Engines"), "Re: Engines")
        XCTAssertEqual(QuickReplyComposer.replySubject(for: "Re: Engines"), "Re: Engines")
        XCTAssertEqual(QuickReplyComposer.replySubject(for: "  RE: Engines "), "RE: Engines")
        XCTAssertEqual(QuickReplyComposer.replySubject(for: ""), "Re:")
    }

    func testParagraphsHTML() {
        XCTAssertEqual(
            QuickReplyComposer.paragraphsHTML(from: "Hello\n\nWorld & <you>\nthere\n\n\n"),
            "<p>Hello</p><p>World &amp; &lt;you&gt;<br>there</p>"
        )
        XCTAssertEqual(QuickReplyComposer.paragraphsHTML(from: "One\r\n\r\nTwo"), "<p>One</p><p>Two</p>")
        XCTAssertEqual(QuickReplyComposer.paragraphsHTML(from: "   "), "")
    }

    func testOutgoingMessageThreadsOnTheLatestMessage() {
        let latest = F.message(
            "m9",
            from: F.ada,
            subject: "Engines",
            internetMessageID: "<m9@example.com>",
            references: ["<m1@example.com>"]
        )
        let text = "Thanks!\n\nSee you Tuesday."
        let message = QuickReplyComposer.outgoingMessage(text: text, replyingTo: latest, accounts: F.accounts)
        XCTAssertEqual(message.accountID, F.accountID)
        XCTAssertEqual(message.to, [F.ada])
        XCTAssertTrue(message.cc.isEmpty)
        XCTAssertEqual(message.subject, "Re: Engines")
        XCTAssertEqual(message.html, "<p>Thanks!</p><p>See you Tuesday.</p>")
        XCTAssertEqual(message.text, text)
        XCTAssertEqual(message.inReplyTo, latest.id)
        XCTAssertEqual(message.inReplyToInternetMessageID, "<m9@example.com>")
        XCTAssertEqual(message.references, ["<m1@example.com>", "<m9@example.com>"])
        XCTAssertTrue(message.attachments.isEmpty)
    }

    func testReferencesAreNotDuplicated() {
        let latest = F.message("m9", internetMessageID: "<m9@example.com>", references: ["<m9@example.com>"])
        XCTAssertEqual(QuickReplyComposer.outgoingMessage(text: "x", replyingTo: latest, accounts: F.accounts).references, ["<m9@example.com>"])
    }
}
