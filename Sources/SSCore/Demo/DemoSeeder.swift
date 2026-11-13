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
            added.append(try await client.addAccount(kind: profile.kind))
        }
        return added
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
