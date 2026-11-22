import Foundation

/// A reconcile's care of the mail its enumeration leaves out though the store holds it (Gmail's Trash and Spam,
/// `MailProvider.mailOutsideEnumeration`). Both lanes run it before their sweep, which deletes every stored message the
/// listing did not mark seen.
///
/// The provider's ids alone say only that the message sits there now. A stored row already in Trash or Spam is
/// right, and is marked seen so the sweep keeps it: nothing after the reset would bring it back. A stored row shown
/// anywhere else moved there during the gap the reset covers (trashed or marked spam on the phone), and marked seen
/// as it is it would keep its old roles, in the Inbox say, for good. So its metadata is fetched and written first; one
/// the provider no longer has or will not return stays unmarked and the sweep takes it, as it did before. Ids the store
/// does not hold need nothing: the sweep only looks at stored rows.
enum OutsideEnumeration {
    /// Of a page of those ids, the stored ones already in Trash or Spam (`kept`) and the stored ones shown elsewhere
    /// (`moved`), in the page's order.
    static func sort(_ ids: [String], store: MailStoring, accountID: AccountID) throws -> (kept: [String], moved: [String]) {
        let roles = try store.storedRoles(accountID: accountID, providerIDs: ids)
        var kept: [String] = []
        var moved: [String] = []
        var seen: Set<String> = []
        for id in ids where seen.insert(id).inserted {
            guard let stored = roles[id] else { continue }
            if stored.contains(.trash) || stored.contains(.spam) {
                kept.append(id)
            } else {
                moved.append(id)
            }
        }
        return (kept, moved)
    }

    /// The messages a lookup of `asked` returned for this account, to write and mark seen.
    static func refreshed(_ lookup: MetadataLookup, asked: [String], accountID: AccountID) -> [MessageMetadata] {
        let wanted = Set(asked)
        return lookup.messages.filter { $0.id.accountID == accountID && wanted.contains($0.id.providerID) }
    }
}

extension Array {
    /// The array in consecutive slices of at most `size` (at least one) elements.
    func chunked(_ size: Int) -> [[Element]] {
        let step = Swift.max(1, size)
        return stride(from: 0, to: count, by: step).map { Array(self[$0..<Swift.min($0 + step, count)]) }
    }
}
