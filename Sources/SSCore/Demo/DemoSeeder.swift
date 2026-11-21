import Foundation

/// Adds the two demo accounts on the first demo launch, through the same `addAccount` path a real sign-in
/// takes, so demo mode exercises the engine end to end.
public enum DemoSeeder {
    /// Adds whichever demo profiles are missing and returns the accounts that were added.
    @discardableResult
    public static func seedIfNeeded(_ client: MailClient) async throws -> [Account] {
        let existing = try client.accounts()
        var added: [Account] = []
        for profile in DemoProfile.all {
            let present = existing.contains {
                $0.kind == profile.kind && $0.email.caseInsensitiveCompare(profile.email) == .orderedSame
            }
            guard !present else { continue }
            let account = try await client.addAccount(kind: profile.kind)
            // As the first read of the demo server's rules would write it, so Senders… shows it from the first launch.
            try client.store.replaceServerSenderRules(
                accountID: account.id,
                with: [ServerSenderRule(serverID: DemoMailbox.blockedRuleID, address: blockedSender, action: .trash)],
                readAt: Date())
            added.append(account)
        }
        return added
    }

    /// A made-up sender each demo account blocks, a rule its made-up server holds from the start (`DemoMailbox`), so
    /// Settings › Accounts › Senders… has a rule to show. No demo mail comes from it, so the demo's mailboxes are as they
    /// were.
    public static let blockedSender = "offers@deals.example"

    /// The demo's Later sample (spec §5.43, §5.54): one of its archived conversations snoozed until tomorrow at 17:00, so
    /// the Later tile shows and the day column and the week mark the time it comes back. Archived already, it needs no
    /// archive step. The app calls it once, with the accounts the first seeding added, as their mail arrives; nil while
    /// none of their conversations can hold a snooze yet (`Snooze.canHold`).
    @discardableResult
    public static func seedLater(_ client: MailClient, accounts: [Account], now: Date = Date(),
                                 calendar: Calendar = .autoupdatingCurrent) throws -> ConversationID? {
        guard !accounts.isEmpty, let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              let due = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: tomorrow) else { return nil }
        // The Gmail mailbox's first: its ink is the calendar's other one, beside the Outlook Send Later sample.
        let ordered = accounts.filter { $0.kind == .gmail } + accounts.filter { $0.kind != .gmail }
        for account in ordered {
            let rows = try client.store.conversations(ConversationQuery(accountIDs: [account.id], view: .all, limit: 100))
            for row in rows where Snooze.canHold(try client.store.messages(in: row.id)) {
                try client.setSnoozes([Snooze.Change(conversationID: row.id, until: due)], performing: [])
                return row.id
            }
        }
        return nil
    }

    /// The demo's Send Later sample (spec §5.43, §5.23): a note to Ben Carter from the Outlook mailbox waiting in the
    /// outbox for Monday 09:00 (Tomorrow's 09:00 on a Sunday), so Drafts shows a row reading “Sends Mon 09:00” from the
    /// start. Built from the outbox row alone, with no kept draft: opening it makes one from the message. The app calls it
    /// once, with the accounts the first seeding added. Returns the pending send id, or nil with no account to send from.
    @discardableResult
    public static func seedSendLater(_ client: MailClient, accounts: [Account], now: Date = Date(),
                                     calendar: Calendar = .autoupdatingCurrent) throws -> String? {
        guard let account = accounts.first(where: { $0.kind == .microsoft }) ?? accounts.first,
              let date = SendLaterPreset.monday.date(after: now, calendar: calendar)
                ?? SendLaterPreset.tomorrow.date(after: now, calendar: calendar) else { return nil }
        let text = """
            Hi Ben,

            Items 8 and 9 are done now that your SSO metadata is in. Your store managers can start training as planned.

            Alex
            """
        let html = text.components(separatedBy: "\n\n").map { "<p>" + $0.replacingOccurrences(of: "\n", with: "<br>") + "</p>" }.joined()
        let message = OutgoingMessage(accountID: account.id, to: [DemoCatalog.ben.email], subject: "Contoso rollout: items 8 and 9",
                                      html: html, text: text)
        return try client.scheduleSend(message, at: date, draftID: nil)
    }
}
