import Foundation

/// A reconcile's sweep keeps every stored message a live operation targets, though its listing did not return it:
/// the operation is the user's intent and settles it. Not when the provider deleted the message in the gap the
/// reset covers: that deletion is in the expired history, so no later poll mentions it, and with the marks gone no
/// later sweep looks at it either. Before a sweep, both lanes ask the provider about those targets and delete the
/// ones it no longer has; an operation on a missing row is harmless (a give-back skips it, a confirm keeps nothing).
enum LostTargets {
    /// Stored messages of the account that a pending or uncertain operation targets, minus `listed`: the ones a
    /// sweep would keep without knowing whether the provider still has them.
    static func candidates(store: MailStoring, accountID: AccountID, listed: Set<String> = [], limit: Int) throws -> [String] {
        var seen: Set<String> = []
        return try store.pendingOperations(accountID: accountID, limit: limit)
            .flatMap(\.targets)
            .filter { $0.accountID == accountID && !listed.contains($0.providerID) && seen.insert($0.providerID).inserted }
            .filter { try store.message($0) != nil }
            .map(\.providerID)
    }

    /// Asks `fetch` (the provider's `metadata(for:)`, which leaves out ids it does not know) about `candidates`,
    /// `chunk` at a time, and returns the ones it no longer has.
    static func lost(_ candidates: [String], chunk: Int,
                     fetch: ([String]) async throws -> [MessageMetadata]) async throws -> [String] {
        var lost: [String] = []
        let size = max(1, chunk)
        for start in stride(from: 0, to: candidates.count, by: size) {
            let asked = Array(candidates[start..<min(start + size, candidates.count)])
            let found = Set(try await fetch(asked).map(\.id.providerID))
            lost.append(contentsOf: asked.filter { !found.contains($0) })
        }
        return lost
    }
}
