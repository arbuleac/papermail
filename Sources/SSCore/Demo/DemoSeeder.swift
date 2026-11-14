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
            try client.setSenderRule(.trash, for: blockedSender, accountID: account.id, performing: [])
            added.append(account)
        }
        return added
    }

    /// A made-up sender each demo account blocks, so Settings › Accounts › Senders… has a rule to show. No demo mail comes
    /// from it, so the demo's mailboxes are as they were.
    public static let blockedSender = "offers@deals.example"
}
