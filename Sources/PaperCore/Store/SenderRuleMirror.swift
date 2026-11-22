import Foundation

/// The rules of `sender_rules` (v23, docs/DATA-MODEL.md "Sender rules"): the mirror of the server's sender rules plus
/// the user's changes on their way there. Pure, over one account's rows, so the SQLite store and the in-memory store make
/// the same transitions; each store reads the rows it needs, asks here, and writes back what changed.
enum SenderRuleMirror {
    /// What a transition does to the row for one address.
    enum Change: Equatable {
        case keep
        case write(SenderRule)
        case remove
    }

    // MARK: The user's change

    /// `MailStoring.setSenderRule`: the user set `action` for the address (nil removes the rule) at `now`. A rule the
    /// server never had is simply removed; one it has is marked for the engine to delete or replace there. A change back
    /// to a rule still on the server (an undo of a removal or of the other action) is a replacement too: the engine's read
    /// finds the rule it already has and adopts it, with nothing deleted, so the row never claims a rule the server lacks.
    static func setting(_ action: SenderRule.Action?, on row: SenderRule?, accountID: AccountID, address: String,
                        at now: Date) -> Change {
        guard let row else {
            guard let action else { return .keep }
            return .write(SenderRule(accountID: accountID, address: address, action: action, createdAt: now, sync: .creating))
        }
        guard let action else {
            switch row.sync {
            case .creating: return .remove
            case .deleting: return .keep
            case .saved, .replacing: return .write(changed(row, sync: .deleting, at: now))
            }
        }
        switch row.sync {
        case .creating:
            return row.action == action ? .keep : .write(changed(row, action: action, at: now))
        case .saved, .replacing:
            guard row.action != action else { return .keep }
            return .write(changed(row, action: action, sync: .replacing, at: now))
        case .deleting:
            return .write(changed(row, action: action, sync: .replacing, at: now))
        }
    }

    // MARK: A read of the server

    /// `MailStoring.replaceServerSenderRules`: the account's rows once a read listed `server`. Saved rows become the
    /// server's list (several rules for one address fold into one row, the block winning, every id kept); rows on their
    /// way stay as they are, except that a `creating` row whose identical rule the server now has is saved with its ids,
    /// and a `deleting` row whose rules the server no longer has goes (or gives way to the rule the server has for that
    /// address now). Returns the changes keyed by address.
    static func replacing(_ rows: [SenderRule], accountID: AccountID, with server: [ServerSenderRule],
                          readAt: Date) -> [String: Change] {
        let groups = fold(server)
        var byAddress: [String: SenderRule] = [:]
        for row in rows { byAddress[row.address] = row }
        var changes: [String: Change] = [:]
        for row in rows {
            let group = groups[row.address]
            switch row.sync {
            case .saved:
                guard let group else {
                    changes[row.address] = .remove
                    continue
                }
                var fresh = row
                fresh.action = group.action
                fresh.serverIDs = group.ids
                changes[row.address] = fresh == row ? .keep : .write(fresh)
            case .creating:
                guard let group, group.action == row.action else { continue }
                var saved = row
                saved.serverIDs = group.ids
                saved.sync = .saved
                changes[row.address] = .write(saved)
            case .replacing:
                continue
            case .deleting:
                if let group, !Set(group.ids).isDisjoint(with: row.serverIDs) { continue }
                if let group {
                    changes[row.address] = .write(SenderRule(accountID: accountID, address: row.address, action: group.action,
                                                             createdAt: readAt, serverIDs: group.ids, sync: .saved))
                } else {
                    changes[row.address] = .remove
                }
            }
        }
        for (address, group) in groups where byAddress[address] == nil {
            changes[address] = .write(SenderRule(accountID: accountID, address: address, action: group.action, createdAt: readAt,
                                                 serverIDs: group.ids, sync: .saved))
        }
        return changes
    }

    /// The server's rules by address: every id in the server's order, and the block when any of them blocks (Gmail runs
    /// every matching filter, and the Trash is further out than the archive).
    static func fold(_ server: [ServerSenderRule]) -> [String: (action: SenderRule.Action, ids: [String])] {
        var groups: [String: (action: SenderRule.Action, ids: [String])] = [:]
        for rule in server where !rule.address.isEmpty && !rule.serverID.isEmpty {
            var group = groups[rule.address] ?? (rule.action, [])
            if rule.action == .trash { group.action = .trash }
            if !group.ids.contains(rule.serverID) { group.ids.append(rule.serverID) }
            groups[rule.address] = group
        }
        return groups
    }

    // MARK: What the engine did

    /// `MailStoring.settleSenderRule`: `outcome` applied to the row as it stands now. `settled` is false when there is no
    /// row (the rule was removed before it reached the server, or the account went): the engine then deletes what it
    /// just wrote.
    static func settling(_ outcome: SenderRuleOutcome, on row: SenderRule?) -> (change: Change, settled: Bool) {
        guard let row else { return (.keep, false) }
        switch outcome {
        case .written(let action, let ids, let deleted):
            let held = unique(row.serverIDs + ids).filter { !deleted.contains($0) }
            switch row.sync {
            case .creating, .replacing:
                if row.action == action, Set(held) == Set(ids), !ids.isEmpty {
                    return (.write(changed(row, ids: ids, sync: .saved)), true)
                }
                return (.write(changed(row, ids: held, sync: held.isEmpty ? .creating : .replacing)), true)
            case .deleting:
                return (held.isEmpty ? .remove : .write(changed(row, ids: held)), true)
            case .saved:
                guard row.action == action, !held.isEmpty else { return (.keep, true) }
                return (.write(changed(row, ids: held)), true)
            }
        case .deleted(let ids):
            let held = row.serverIDs.filter { !ids.contains($0) }
            guard held != row.serverIDs else { return (.keep, true) }
            switch row.sync {
            case .deleting:
                return (held.isEmpty ? .remove : .write(changed(row, ids: held)), true)
            case .replacing, .saved:
                // The user wants the rule; what the server had of it is gone, so it is made anew.
                return (.write(changed(row, ids: held, sync: held.isEmpty ? .creating : row.sync)), true)
            case .creating:
                return (.keep, true)
            }
        case .refused(let attempted, let serverHas):
            guard row.sync == attempted else { return (.keep, true) }
            switch row.sync {
            case .creating:
                return (.remove, true)
            case .replacing, .deleting:
                guard let serverHas, !row.serverIDs.isEmpty else { return (.remove, true) }
                var back = row
                back.action = serverHas
                back.sync = .saved
                return (.write(back), true)
            case .saved:
                return (.keep, true)
            }
        }
    }

    // MARK: Helpers

    private static func changed(_ row: SenderRule, action: SenderRule.Action? = nil, ids: [String]? = nil,
                                sync: SenderRule.Sync? = nil, at now: Date? = nil) -> SenderRule {
        var copy = row
        if let action { copy.action = action }
        if let ids { copy.serverIDs = ids }
        if let sync { copy.sync = sync }
        if let now { copy.createdAt = now }
        return copy
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
