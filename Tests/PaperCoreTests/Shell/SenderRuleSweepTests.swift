import XCTest
import PaperCore

/// What setting a sender rule takes of the mail already stored (spec §5.52): Always Archive their mail in every
/// account's Inbox, Block their mail in the conversation it was set from, each message through
/// `SenderRule.Action.change(for:)`, never an account's mail from its own address; the conversations it took, the one
/// it was set from first, and the undo's steps.
final class SenderRuleSweepTests: XCTestCase {
    private let a = AccountID("a"), b = AccountID("b")
    private let letter = EmailAddress(name: "Weekly", address: "news@letter.example")

    private func message(_ id: String, _ conversation: String, account: AccountID? = nil, from: EmailAddress? = nil,
                         roles: Set<MailboxRole> = [.inbox]) -> MessageMetadata {
        let account = account ?? a
        return MessageMetadata(id: MessageID(accountID: account, providerID: id),
                               conversationID: ConversationID(accountID: account, providerID: conversation), subject: "", snippet: "",
                               from: from ?? letter, date: Date(timeIntervalSince1970: 0), roles: roles, isRead: true, isStarred: false,
                               hasAttachments: false)
    }

    private var own: [AccountID: String] { [a: "me@a.example", b: "me@b.example"] }

    func testAlwaysArchiveTakesTheirInboxMailInEveryAccount() {
        let open = ConversationID(accountID: a, providerID: "open")
        let thread = [message("o1", "open"), message("o2", "open", from: EmailAddress(address: "me@a.example"), roles: [.sent]),
                      message("o3", "open", from: EmailAddress(address: "ben@example.com"))]
        let inbox = [message("o1", "open"), message("x1", "x", account: b), message("y1", "y", from: EmailAddress(address: "NEWS@letter.example")),
                     message("y2", "y"), message("s1", "s", roles: [.inbox, .spam]), message("t1", "t", roles: [.inbox, .sent])]
        let sweep = SenderRuleSweep(.archive, address: "News@Letter.example", setFrom: open, conversationMessages: thread,
                                    inboxMessages: inbox, ownAddresses: own)
        XCTAssertEqual(sweep.record?.targets.map(\.providerID), ["o1", "x1", "y1", "y2"],
                       "theirs in the Inbox, once each: never Spam, never the user's own sent mail, never someone else's")
        XCTAssertEqual(sweep.conversations.map(\.providerID), ["open", "x", "y"], "the one it was set from first")
        XCTAssertEqual(sweep.steps, [MailActionRecord.Step(change: .archive, targets: sweep.record?.targets ?? [])])
        XCTAssertEqual(sweep.inverse, [MailActionRecord.Step(change: .moveToInbox, targets: sweep.record?.targets ?? [])])
        XCTAssertEqual(sweep.accounts, [a, b])
        XCTAssertTrue(sweep.takesItsConversation)
        XCTAssertTrue(sweep.reachesBeyondItsConversation)
    }

    func testOnlyTheOpenConversationOrNothingReachesNoFurther() {
        let open = ConversationID(accountID: a, providerID: "open")
        let alone = SenderRuleSweep(.archive, address: letter.address, setFrom: open, conversationMessages: [message("o1", "open")],
                                    inboxMessages: [message("o1", "open")], ownAddresses: own)
        XCTAssertEqual(alone.conversations, [open])
        XCTAssertFalse(alone.reachesBeyondItsConversation)

        let archived = SenderRuleSweep(.archive, address: letter.address, setFrom: open,
                                       conversationMessages: [message("o1", "open", roles: [])], inboxMessages: [], ownAddresses: own)
        XCTAssertNil(archived.record, "nothing in the Inbox: nothing to take, nothing to undo but the rule")
        XCTAssertEqual(archived.conversations, [])
        XCTAssertEqual(archived.steps, [])
        XCTAssertEqual(archived.accounts, [])
        XCTAssertFalse(archived.takesItsConversation)

        let elsewhere = SenderRuleSweep(.archive, address: letter.address, setFrom: open,
                                        conversationMessages: [message("o1", "open", roles: [])], inboxMessages: [message("x1", "x", account: b)],
                                        ownAddresses: own)
        XCTAssertEqual(elsewhere.conversations.map(\.providerID), ["x"])
        XCTAssertFalse(elsewhere.takesItsConversation)
        XCTAssertTrue(elsewhere.reachesBeyondItsConversation, "another conversation, though not the open one")
    }

    /// A rule set in one account for the address of another of the user's accounts never archives that account's own mail.
    func testAnAccountsMailFromItsOwnAddressIsNeverTaken() {
        let me = EmailAddress(address: "Me@B.example")
        let open = ConversationID(accountID: a, providerID: "open")
        let sweep = SenderRuleSweep(.archive, address: "me@b.example", setFrom: open, conversationMessages: [message("o1", "open", from: me)],
                                    inboxMessages: [message("o1", "open", from: me), message("n1", "note", account: b, from: me)],
                                    ownAddresses: own)
        XCTAssertEqual(sweep.record?.targets.map(\.providerID), ["o1"], "account A's mail from it; not B's notes to itself")
    }

    func testBlockStaysInItsConversation() {
        let open = ConversationID(accountID: a, providerID: "open")
        let sweep = SenderRuleSweep(.trash, address: letter.address, setFrom: open,
                                    conversationMessages: [message("o1", "open"), message("o2", "open", roles: []),
                                                           message("o3", "open", roles: [.trash]), message("o4", "open", roles: [.spam])],
                                    inboxMessages: [message("x1", "x", account: b)], ownAddresses: own)
        XCTAssertEqual(sweep.record?.targets.map(\.providerID), ["o1", "o2"], "out of the Trash's way; never Spam; never elsewhere")
        XCTAssertEqual(sweep.conversations, [open])
        XCTAssertFalse(sweep.reachesBeyondItsConversation)
        XCTAssertEqual(sweep.inverse.map(\.change), [.restoreFromTrash, .archive], "the archived one goes back to the archive")
    }
}
