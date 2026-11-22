import XCTest
@testable import PaperCore

/// The pure halves of mute (roadmap Q3.7) and sender rules (Q4.2, kept on the server since v23): what an arriving message
/// is given, what setting a rule does to stored mail, how a rule's address is kept and recognized on the server, the words
/// feedback uses, and the muted row's mark and VoiceOver word.
final class ArrivalRuleTests: XCTestCase {
    private let account = AccountID("acct-1")

    private func message(roles: Set<MailboxRole>) -> MessageMetadata {
        MessageMetadata(id: MessageID(accountID: account, providerID: "m1"), conversationID: ConversationID(accountID: account, providerID: "c1"),
                        subject: "Hi", snippet: "", from: EmailAddress(address: "x@example.com"), date: Date(timeIntervalSince1970: 0),
                        roles: roles, isRead: false, isStarred: false, hasAttachments: false)
    }

    // MARK: ArrivalRule

    func testTheMuteArchivesWhateverArrivesInTheInbox() {
        XCTAssertEqual(ArrivalRule.change(for: message(roles: [.inbox]), inMutedConversation: true), .archive)
        XCTAssertEqual(ArrivalRule.change(for: message(roles: [.inbox, .sent]), inMutedConversation: true), .archive,
                       "the user's own copy sent to themselves stays out too")
        XCTAssertNil(ArrivalRule.change(for: message(roles: []), inMutedConversation: true), "already out of the Inbox")
        XCTAssertNil(ArrivalRule.change(for: message(roles: [.sent]), inMutedConversation: true), "a reply in Sent")
        XCTAssertNil(ArrivalRule.change(for: message(roles: [.spam, .inbox]), inMutedConversation: true), "spam stays")
        XCTAssertNil(ArrivalRule.change(for: message(roles: [.inbox]), inMutedConversation: false), "nothing set")
    }

    // MARK: What setting a rule does to stored mail

    /// A server rule acts only on mail that arrives after it exists, so the app applies the rule once to the sender's mail
    /// where it was set: the same test the arrival rule made before rules moved to the server.
    func testSettingARuleTakesTheSendersStoredMailButNeverTheUsersOwnOrSpam() {
        XCTAssertEqual(SenderRule.Action.archive.change(for: message(roles: [.inbox])), .archive)
        XCTAssertEqual(SenderRule.Action.trash.change(for: message(roles: [.inbox])), .trash)
        XCTAssertEqual(SenderRule.Action.trash.change(for: message(roles: [])), .trash,
                       "Block takes archived mail too: it goes to the Trash wherever it is")
        XCTAssertNil(SenderRule.Action.archive.change(for: message(roles: [])), "archived already")
        for own: Set<MailboxRole> in [[.sent], [.drafts], [.inbox, .sent]] {
            XCTAssertNil(SenderRule.Action.trash.change(for: message(roles: own)), "\(own)")
            XCTAssertNil(SenderRule.Action.archive.change(for: message(roles: own)), "\(own)")
        }
        XCTAssertNil(SenderRule.Action.trash.change(for: message(roles: [.spam, .inbox])), "spam stays")
        XCTAssertNil(SenderRule.Action.trash.change(for: message(roles: [.trash])), "in the Trash already")
        XCTAssertNil(SenderRule.Action.archive.change(for: message(roles: [.inbox, .trash])), "in the Trash, not the Inbox")
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
        XCTAssertEqual(SenderRule.Sync.allCases.map(\.rawValue), ["saved", "creating", "replacing", "deleting"], "stored raw values")
        XCTAssertEqual(rule.sync, .saved, "a row is as the server has it unless said otherwise")
        XCTAssertEqual(rule.serverIDs, [])
    }

    /// A rule removed on this Mac is no longer the user's while its delete is on its way; every other state is.
    func testOnlyARuleBeingDeletedIsNoLongerTheUsers() {
        for sync in SenderRule.Sync.allCases {
            let rule = SenderRule(accountID: account, address: "a@b.example", action: .archive, createdAt: Date(), sync: sync)
            XCTAssertEqual(rule.isActive, sync != .deleting, "\(sync)")
            XCTAssertEqual(rule.isPending, sync != .saved, "\(sync)")
        }
    }

    // MARK: Server rules

    /// A server rule is shown as a sender rule only when its condition names one plain address: anything Gmail's search
    /// grammar or a header would read as more is some other rule.
    func testOnlyOnePlainAddressIsASenderRulesAddress() {
        XCTAssertEqual(ServerSenderRule.singleAddress(" Deals@Shop.Example "), "deals@shop.example")
        XCTAssertEqual(ServerSenderRule.singleAddress("o'brien+news@mail.example.co.uk"), "o'brien+news@mail.example.co.uk")
        for other in ["", "   ", "a@b.example OR c@d.example", "a@b.example c@d.example", "{a@b.example c@d.example}",
                      "(a@b.example)", "\"a@b.example\"", "*@b.example", "a@*.example", "-a@b.example", "Ann <a@b.example>",
                      "b.example", "@b.example", "a@", "a@b@c.example", "a@b.example,c@d.example", "a@.example", "a@example.",
                      "a@b.example;", "a|b@c.example", "[a@b.example]", "from:a@b.example"] {
            XCTAssertNil(ServerSenderRule.singleAddress(other), other)
        }
        XCTAssertEqual(ServerSenderRule(serverID: "f1", address: "  A@B.Example", action: .trash).address, "a@b.example")
    }

    func testTheRulesFailuresWordsNameTheProvidersRules() {
        XCTAssertEqual(RulesSyncFailure.limitReached.words(for: .gmail), "Gmail has too many filters to save this one.")
        XCTAssertEqual(RulesSyncFailure.limitReached.words(for: .microsoft), "Outlook has too many rules to save this one.")
        XCTAssertEqual(RulesSyncFailure.refused.words(for: .gmail), "Gmail didn’t accept this filter.")
        XCTAssertEqual(RulesSyncFailure.refused.words(for: .microsoft), "Outlook didn’t accept this rule.")
        XCTAssertEqual(RulesSyncFailure.unreachable.words(for: .gmail), "Couldn’t reach Gmail. Trying again soon.")
        XCTAssertEqual(RulesSyncFailure.unreachable.words(for: .microsoft), "Couldn’t reach Outlook. Trying again soon.")
        XCTAssertEqual(RulesSyncState.upToDate(otherCount: 12, readAt: Date()).otherCount, 12)
        XCTAssertEqual(RulesSyncState.failed(.refused, otherCount: 3).otherCount, 3)
        XCTAssertNil(RulesSyncState.notConnected.otherCount)
        XCTAssertNil(RulesSyncState.unknown.otherCount)
    }

    /// Mail a mute or a sender rule covers is not news, whatever became of it: it never ends a snooze.
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
