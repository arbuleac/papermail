import Foundation

/// Searches the providers for mail this Mac does not have yet (docs/ARCHITECTURE.md, "Server search"), for
/// `MailEngine.searchServer`.
///
/// Per account: one `MailProvider.search` call (the text as typed, the provider's own rules), then metadata only for
/// the hits the store lacks, written in one transaction through `writeBackfillMessages`, which drops in that same
/// transaction whatever got stored meanwhile and whatever the live lane deleted while a backfill runs. The list's
/// search reads the hits from the store like any other mail, and their bodies download when they are opened
/// (`MailClient.ensureBody`), so the search costs a listing plus a metadata fetch per new message, never a body.
/// Everything is recorded as live spend in the account's quota budget before it goes out, and a throttle pauses the
/// backfill, as one on any request that spends the live share does.
struct ServerSearcher: Sendable {
    let store: MailStoring
    /// Hits asked of each provider: about a screen and a half of rows, and on Gmail at most 1,005 units with every hit
    /// new (the listing plus 20 apiece), half the live share of a minute.
    let limit: Int
    /// Accounts searched at once; the rest wait for a slot, so a unified search never fans out over every mailbox.
    let concurrency: Int

    func search(_ text: String, in contexts: [AccountContext]) async throws -> ServerSearchResult {
        var outcomes: [Int: Result<(conversations: Set<ConversationID>, downloaded: Int), Error>] = [:]
        try await withThrowingTaskGroup(of: (Int, Result<(conversations: Set<ConversationID>, downloaded: Int), Error>).self) { group in
            var next = 0
            func startNext() {
                guard next < contexts.count else { return }
                let index = next
                let context = contexts[index]
                next += 1
                // A cancelled search starts no more accounts: each would record live spend for a request never sent.
                _ = group.addTaskUnlessCancelled {
                    do {
                        return (index, .success(try await search(text, in: context)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<max(1, concurrency) { startNext() }
            while let (index, outcome) = try await group.next() {
                outcomes[index] = outcome
                startNext()
            }
        }
        // A cancelled search reports nothing: the list it was for has moved on, and an error it caused is not the
        // account's.
        try Task.checkCancellation()
        var result = ServerSearchResult()
        for (index, context) in contexts.enumerated() {
            switch outcomes[index] {
            case .success(let found)?:
                result.conversations.formUnion(found.conversations)
                result.downloaded += found.downloaded
            case .failure(let error)?:
                result.failedAccounts.append(context.account.id)
                SyncLog.logger.notice("""
                    server search failed for \(context.account.id.rawValue, privacy: .public): \
                    \(String(describing: error), privacy: .private)
                    """)
            case nil:
                result.failedAccounts.append(context.account.id)
            }
        }
        return result
    }

    private func search(_ text: String, in context: AccountContext) async throws -> (conversations: Set<ConversationID>, downloaded: Int) {
        let accountID = context.account.id
        let budget = context.budget
        let quota = budget.quota
        try Task.checkCancellation()
        await budget.recordLive(quota.listCost)
        let listed = try await throttleAware(budget) { try await context.provider.search(text, limit: limit) }
        try Task.checkCancellation()
        var seen: Set<String> = []
        let hits = listed.filter { seen.insert($0).inserted }
        guard !hits.isEmpty else { return ([], 0) }

        // Stored hits (and those the live lane wrote or deleted while a backfill runs) need no request: the stored
        // ones join the results as they are.
        let known = try store.backfillSkippableIDs(accountID: accountID, providerIDs: hits, includeStored: true)
        var conversations: Set<ConversationID> = []
        for providerID in hits where known.contains(providerID) {
            guard let stored = try store.message(MessageID(accountID: accountID, providerID: providerID)) else { continue }
            if Self.isListed(stored) { conversations.insert(stored.conversationID) }
        }
        let missing = hits.filter { !known.contains($0) }
        guard !missing.isEmpty else { return (conversations, 0) }

        await budget.recordLive(Double(missing.count) * quota.metadataCostPerMessage)
        let fetched = try await throttleAware(budget) { try await context.provider.metadata(for: missing) }
        // Fetched metadata is kept even if the search was cancelled meanwhile: the quota is spent, and the messages are
        // real mail the backfill would fetch anyway.
        let wanted = Set(missing)
        let listedHits = fetched.filter { $0.id.accountID == accountID && wanted.contains($0.id.providerID) && Self.isListed($0) }
        let downloaded = try store.writeBackfillMessages(listedHits, refreshExisting: false)
        conversations.formUnion(listedHits.map(\.conversationID))
        return (conversations, downloaded)
    }

    /// Trash and Spam are what the first download leaves out and the list's search never shows.
    private static func isListed(_ message: MessageMetadata) -> Bool {
        !message.roles.contains(.trash) && !message.roles.contains(.spam)
    }

    /// Runs a request that spends the live share; a throttle pauses the backfill too (`QuotaBudget.liveThrottled`).
    private func throttleAware<T>(_ budget: QuotaBudget, _ request: () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch {
            if case .throttled(let retryAfter)? = error as? ProviderError {
                await budget.liveThrottled(retryAfter: retryAfter)
            }
            throw error
        }
    }
}
