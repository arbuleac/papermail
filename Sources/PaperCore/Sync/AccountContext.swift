import Foundation

/// Everything the engine keeps for one account: the provider and hydrator that serve on-demand fetches, the quota
/// budget they and the lanes spend from, and the syncer that drives its two lanes. Built lazily, so `ensureBody`
/// works even before `start()`.
final class AccountContext: Sendable {
    let account: Account
    let provider: MailProvider
    let hydrator: Hydrator
    let syncer: AccountSyncer
    let budget: QuotaBudget

    init(account: Account, provider: MailProvider, hydrator: Hydrator, syncer: AccountSyncer, budget: QuotaBudget) {
        self.account = account
        self.provider = provider
        self.hydrator = hydrator
        self.syncer = syncer
        self.budget = budget
    }
}
