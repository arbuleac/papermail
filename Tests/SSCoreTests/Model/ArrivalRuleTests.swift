import XCTest
@testable import SSCore

/// The pure halves of mute (roadmap Q3.7) and sender rules (Q4.2): what an arriving message is given, how a rule's
/// address is kept, the words feedback uses, and the muted row's mark and VoiceOver word.
final class ArrivalRuleTests: XCTestCase {
    private let account = AccountID("acct-1")

    private func message(roles: Set<MailboxRole>) -> MessageMetadata {
        MessageMetadata(id: MessageID(accountID: account, providerID: "m1"), conversationID: ConversationID(accountID: account, providerID: "c1"),
                        subject: "Hi", snippet: "", from: EmailAddress(address: "x@example.com"), date: Date(timeIntervalSince1970: 0),
                        roles: roles, isRead: false, isStarred: false, hasAttachments: false)
    }

    // MARK: ArrivalRule

    func testTheMuteArchivesWhateverArrivesInTheInbox() {
        XCTAssertEqual(ArrivalRule.change(for: message(roles: [.inbox]), inMutedConversation: true, senderRule: nil), .archive)
        XCTAssertEqual(ArrivalRule.change(for: message(roles: [.inbox, .sent]), inMutedConversation: true, senderRule: nil), .archive,
                       "the user's own copy sent to themselves stays out too")
        XCTAssertNil(ArrivalRule.change(for: message(roles: []), inMutedConversation: true, senderRule: nil), "already out of the Inbox")
        XCTAssertNil(ArrivalRule.change(for: message(roles: [.sent]), inMutedConversation: true, senderRule: nil), "a reply in Sent")
        XCTAssertNil(ArrivalRule.change(for: message(roles: [.inbox]), inMutedConversation: false, senderRule: nil), "nothing set")
    }

    func testSenderRulesNeverTakeTheUsersOwnMailOrSpam() {
        XCTAssertEqual(ArrivalRule.change(for: message(roles: [.inbox]), inMutedConversation: false, senderRule: .archive), .archive)
        XCTAssertEqual(ArrivalRule.change(for: message(roles: [.inbox]), inMutedConversation: false, senderRule: .trash), .trash)
        XCTAssertEqual(ArrivalRule.change(for: message(roles: []), inMutedConversation: false, senderRule: .trash), .trash,
                       "Block takes archived mail too: it goes to the Trash wherever it arrives")
        XCTAssertNil(ArrivalRule.change(for: message(roles: []), inMutedConversation: false, senderRule: .archive))
        for own: Set<MailboxRole> in [[.sent], [.drafts], [.inbox, .sent]] {
            XCTAssertNil(ArrivalRule.change(for: message(roles: own), inMutedConversation: false, senderRule: .trash), "\(own)")
            XCTAssertNil(ArrivalRule.change(for: message(roles: own), inMutedConversation: false, senderRule: .archive), "\(own)")
        }
        XCTAssertNil(ArrivalRule.change(for: message(roles: [.spam, .inbox]), inMutedConversation: true, senderRule: .trash), "spam stays")
        XCTAssertNil(ArrivalRule.change(for: message(roles: [.trash]), inMutedConversation: false, senderRule: .trash), "in the Trash already")
    }

    func testBlockWinsOverTheMute() {
        XCTAssertEqual(ArrivalRule.change(for: message(roles: [.inbox]), inMutedConversation: true, senderRule: .trash), .trash)
        XCTAssertEqual(ArrivalRule.change(for: message(roles: [.inbox]), inMutedConversation: true, senderRule: .archive), .archive)
    }

    // MARK: SenderRule

    func testARulesAddressIsTrimmedAndLowercasedAndNothingElse() {
        XCTAssertEqual(SenderRule.normalizedAddress("  Ann.Lee+News@Example.COM \n"), "ann.lee+news@example.com",
                       "dots and tags name other senders, so they stay")
        let rule = SenderRule(accountID: account, address: "Deals@Shop.Example", action: .trash, createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(rule.address, "deals@shop.example")
        XCTAssertEqual(SenderRule.Action.archive.change, .archive)
        XCTAssertEqual(SenderRule.Action.trash.change, .trash)
        XCTAssertEqual(SenderRule.Action.allCases.map(\.rawValue), ["archive", "trash"], "stored raw values")
    }

    /// Mail a mute or a sender rule covers is not news, whatever the rule does to it: it never ends a snooze.
    func testOnlyMailNoMuteOrRuleCoversCanEndASnooze() {
        XCTAssertFalse(ArrivalRule.keepsSnooze(inMutedConversation: false, senderRule: nil))
        XCTAssertTrue(ArrivalRule.keepsSnooze(inMutedConversation: true, senderRule: nil))
        XCTAssertTrue(ArrivalRule.keepsSnooze(inMutedConversation: false, senderRule: .archive))
        XCTAssertTrue(ArrivalRule.keepsSnooze(inMutedConversation: false, senderRule: .trash))
    }

    // MARK: Copy

    func testTheWords() {
        XCTAssertEqual(MailActionCopy.muteCommand(muting: true), "Mute")
        XCTAssertEqual(MailActionCopy.muteCommand(muting: false), "Unmute")
        XCTAssertEqual(MailActionCopy.muted(true), "Muted")
        XCTAssertEqual(MailActionCopy.muted(true, count: 3), "Muted 3 conversations")
        XCTAssertEqual(MailActionCopy.muted(false, count: 1_200), "Unmuted \(1_200.formatted(.number.grouping(.automatic))) conversations")
        XCTAssertEqual(MailActionCopy.senderRuleCommand(.archive), "Always Archive Mail from This Sender")
        XCTAssertEqual(MailActionCopy.senderRuleCommand(.trash), "Block Sender")
        XCTAssertEqual(MailActionCopy.senderRuleSet(.archive, address: "news@letter.example"), "Always archiving news@letter.example")
        XCTAssertEqual(MailActionCopy.senderRuleSet(.trash, address: "deals@shop.example"), "Blocked deals@shop.example")
        XCTAssertEqual(MailActionCopy.senderRuleDescription(.archive), "Always archived")
        XCTAssertEqual(MailActionCopy.senderRuleDescription(.trash), "Blocked")
    }

    // MARK: The row

    func testAMutedRowSaysSoAndCachesApart() {
        let formatting = DateFormatting(locale: Locale(identifier: "en_GB"), calendar: Calendar(identifier: .gregorian),
                                        timeZone: TimeZone(identifier: "UTC") ?? .current)
        let reference = formatting.reference(now: Date(timeIntervalSince1970: 1_000))
        var summary = ConversationSummary(
            id: ConversationID(accountID: account, providerID: "c1"), subject: "Weekly", snippet: "", participants: [],
            latestDate: Date(timeIntervalSince1970: 0), messageCount: 1, unreadCount: 0, isStarred: false, hasAttachments: false,
            inInbox: false, inboxSection: .unknown, latestMessageID: MessageID(accountID: account, providerID: "m1"), hasPendingOperations: false)
        let plain = ConversationRowText(summary: summary, reference: reference, formatter: formatting)
        XCTAssertFalse(plain.isMuted)
        XCTAssertFalse(plain.accessibilityLabel.contains("Muted"))
        let before = ConversationRowText.cacheKey(for: summary, dayStamp: 1)
        summary.isMuted = true
        let muted = ConversationRowText(summary: summary, reference: reference, formatter: formatting)
        XCTAssertTrue(muted.isMuted)
        XCTAssertTrue(muted.accessibilityLabel.hasPrefix("Muted."), "VoiceOver says it with the row's other marks: \(muted.accessibilityLabel)")
        XCTAssertNotEqual(ConversationRowText.cacheKey(for: summary, dayStamp: 1), before, "a mute redraws the row")
    }
}
