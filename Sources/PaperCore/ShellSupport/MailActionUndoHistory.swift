import Foundation

/// What Z and ⌘Z can still revert (spec §5.30, §6.1), and which toast offers it.
///
/// Each group is one step as the user saw it: a mail action, or several of the same kind within 1000 ms that
/// coalesced into one toast (“Archived 3 conversations”), or a step that is not a mail action at all (a
/// composer's discarded draft, §5.20), which the caller reverts itself. The history keeps the latest `capacity` steps;
/// the next one drops the oldest.
///
/// Z reaches a group with a toast while the toast is visible and for the grace period after it leaves, and a group the
/// row shows by itself (a star, one mark as unread, §4.13), which never gets a toast, for the grace period from when it
/// happened. ⌘Z goes further: once no toast is up it reverts the latest group still in the history, however old, and
/// takes it out, so each press walks one step further back, newest first.
///
/// A visible toast is a promise (“Undo Z”), so while one shows Z and ⌘Z revert its group even when a quieter action
/// came after it. A toast's own Undo button always reverts its own group. Pure, so the shell's undo rules are tested
/// without a window.
public struct MailActionUndoHistory: Sendable {
    public struct Group: Sendable {
        public let id: Int
        /// Empty for an external step.
        public fileprivate(set) var records: [MailActionRecord]
        /// The mail action; nil for an external step (`addExternal`).
        public let change: MetadataChange?
        /// The command's menu name for an external step (“Discard Draft”), which Edit › Undo and the undo
        /// confirmation repeat; nil for a mail action.
        public let externalCommand: String?
        /// The accounts the step touched: its records' for a mail action, what the caller named for an external step
        /// (none when it named none). A removed account takes its share of the history with it (`removeAccounts`).
        public fileprivate(set) var accounts: Set<AccountID>
        public fileprivate(set) var lastActionAt: Date
        /// The toast offering the group, while that toast is visible.
        public fileprivate(set) var toastID: Int?
        /// Once its toast has gone, or from the start when it never had one: Z reaches it until then.
        public fileprivate(set) var expiresAt: Date?
        /// False for a step whose toast says more than its action (the archive of an unsubscribe, whose toast also
        /// names the request): a later action of the same kind starts a toast of its own rather than renaming it. An
        /// external step joins one only through `coalesceExternal`, which asks this too.
        public let coalesces: Bool
    }

    /// How many steps ⌘Z can walk back (§6.1): the 51st drops the oldest.
    public static let capacity = 50

    /// How long Z still reaches a group after its toast has gone (10000 ms, §6.1).
    public let grace: TimeInterval
    /// How close together actions must be to coalesce into one toast (1000 ms, §5.30).
    public let coalesceWindow: TimeInterval

    public private(set) var groups: [Group] = []
    private var nextID = 1

    public init(grace: TimeInterval = 10, coalesceWindow: TimeInterval = 1) {
        self.grace = grace
        self.coalesceWindow = coalesceWindow
    }

    // MARK: Recording

    /// Adds `record` to the latest group when that group is the same kind of action, its toast is still the
    /// visible one and the last action was within the coalescing window. Returns the grown group, or nil when
    /// `record` must start a group of its own.
    public mutating func coalesce(_ record: MailActionRecord, at now: Date, visibleToastID: Int?) -> Group? {
        coalesce([record], at: now, visibleToastID: visibleToastID)
    }

    /// `records` are one action on several selected conversations (spec §5.19): they join the latest group on
    /// the same terms as a single record, so “Archived 3 conversations” can grow to 4 with one more E.
    public mutating func coalesce(_ records: [MailActionRecord], at now: Date, visibleToastID: Int?) -> Group? {
        guard let change = records.first?.change, records.allSatisfy({ $0.change == change }),
              var last = groups.last, last.coalesces, last.change == .some(change), let toastID = last.toastID,
              toastID == visibleToastID,
              now.timeIntervalSince(last.lastActionAt) <= coalesceWindow else { return nil }
        last.records.append(contentsOf: records)
        last.accounts.formUnion(Self.accounts(of: records))
        last.lastActionAt = now
        groups[groups.count - 1] = last
        return last
    }

    /// Starts a group for `record` and returns its identifier. A group that gets a toast is bound to it with
    /// `bindToast(_:to:)`; one that does not starts its grace now.
    @discardableResult
    public mutating func add(_ record: MailActionRecord, at now: Date, toasted: Bool) -> Int {
        add([record], at: now, toasted: toasted)
    }

    /// Starts one group for an action on several conversations at once: one toast, one undo (spec §5.19).
    /// `records` must be non-empty and of one kind of action. With `coalesces` false nothing joins the group later
    /// (`Group.coalesces`).
    @discardableResult
    public mutating func add(_ records: [MailActionRecord], at now: Date, toasted: Bool, coalesces: Bool = true) -> Int {
        precondition(!records.isEmpty, "a group holds at least one action")
        return append(records: records, change: records[0].change, externalCommand: nil, accounts: Self.accounts(of: records),
                      at: now, toasted: toasted, coalesces: coalesces)
    }

    /// Starts a group for a step the caller reverts itself (the composer's “Draft discarded”), named by its
    /// command (“Discard Draft”). It sits in the same history as the mail actions, so Z and ⌘Z reach
    /// whichever came last, and it coalesces only when its caller asks (`coalesceExternal`) and `coalesces` allows it:
    /// an unsubscribe in Later is named Archive, as E there is, yet takes in no later E. `accounts` are those whose mail
    /// or settings the revert writes to, so the step leaves the history with any of them (`removeAccounts`).
    @discardableResult
    public mutating func addExternal(command: String, accounts: Set<AccountID> = [], at now: Date, toasted: Bool,
                                     coalesces: Bool = true) -> Int {
        append(records: [], change: nil, externalCommand: command, accounts: accounts, at: now, toasted: toasted,
               coalesces: coalesces)
    }

    /// One more external step of `command` joins the latest group on the terms `coalesce` sets for mail actions: that
    /// group is a step of the same command, its toast is still the visible one and the last step was within the
    /// coalescing window. E in Later ends snoozes rather than archiving, so it is no mail action, yet it coalesces as E
    /// does everywhere. Returns the grown group, whose revert the caller extends, or nil when the step must start a group
    /// of its own.
    public mutating func coalesceExternal(command: String, accounts: Set<AccountID> = [], at now: Date,
                                          visibleToastID: Int?) -> Group? {
        guard var last = groups.last, last.coalesces, last.externalCommand == command, let toastID = last.toastID,
              toastID == visibleToastID, now.timeIntervalSince(last.lastActionAt) <= coalesceWindow else { return nil }
        last.accounts.formUnion(accounts)
        last.lastActionAt = now
        groups[groups.count - 1] = last
        return last
    }

    private mutating func append(records: [MailActionRecord], change: MetadataChange?, externalCommand: String?,
                                 accounts: Set<AccountID>, at now: Date, toasted: Bool, coalesces: Bool) -> Int {
        let id = nextID
        nextID += 1
        groups.append(Group(id: id, records: records, change: change, externalCommand: externalCommand, accounts: accounts,
                            lastActionAt: now, toastID: nil, expiresAt: toasted ? nil : now.addingTimeInterval(grace),
                            coalesces: coalesces))
        if groups.count > Self.capacity { groups.removeFirst(groups.count - Self.capacity) }
        return id
    }

    private static func accounts(of records: [MailActionRecord]) -> Set<AccountID> {
        Set(records.compactMap(\.accountID))
    }

    /// The toast `toastID` now offers group `id`.
    public mutating func bindToast(_ toastID: Int, to id: Int) {
        guard let index = groups.lastIndex(where: { $0.id == id }) else { return }
        groups[index].toastID = toastID
    }

    /// A toast stopped being visible (timed out, dismissed, replaced): its group's grace starts.
    public mutating func toastEnded(_ toastID: Int, at now: Date) {
        guard let index = groups.lastIndex(where: { $0.toastID == toastID }) else { return }
        groups[index].toastID = nil
        groups[index].expiresAt = now.addingTimeInterval(grace)
    }

    // MARK: Undoing

    /// The group Z reverts now, if any: the visible toast's, else the latest group still within its grace (§6.1).
    public func zTarget(at now: Date, visibleToastID: Int?) -> Group? {
        if let shown = toastGroup(visibleToastID: visibleToastID) { return shown }
        return graceGroup(at: now)
    }

    /// The group ⌘Z reverts now when no typing or live send comes first, if any: the visible toast's, else the latest
    /// group in the history, however old (§6.1 ⌘Z rows 2 and 3).
    public func commandZTarget(visibleToastID: Int?) -> Group? {
        toastGroup(visibleToastID: visibleToastID) ?? latest
    }

    /// The group the visible toast offers (§6.1 ⌘Z row 2), if a toast is up and offers one.
    public func toastGroup(visibleToastID: Int?) -> Group? {
        guard let visibleToastID else { return nil }
        return groups.last { $0.toastID == visibleToastID }
    }

    /// The latest group whose toast has gone (or that never had one) and is still within its grace: what Z reaches
    /// once no toast is up.
    public func graceGroup(at now: Date) -> Group? {
        guard let last = groups.last, let expiresAt = last.expiresAt, now <= expiresAt else { return nil }
        return last
    }

    /// The latest group still in the history, however old: what ⌘Z reaches once no toast is up (§6.1 ⌘Z row 3).
    public var latest: Group? { groups.last }

    /// Whether group `id` was taken a moment ago as Z counts it: its toast still shows, or its grace still runs. An undo
    /// that comes later than that is a deeper ⌘Z, which the shell lands in the main window rather than in a reader
    /// window it would have to open again (§5.49).
    public func isRecent(_ id: Int, at now: Date) -> Bool {
        guard let group = groups.last(where: { $0.id == id }) else { return false }
        if group.toastID != nil { return true }
        return group.expiresAt.map { now <= $0 } ?? false
    }

    /// Takes group `id` out of the history to revert it; nil when it is no longer there.
    public mutating func remove(_ id: Int) -> Group? {
        guard let index = groups.lastIndex(where: { $0.id == id }) else { return nil }
        return groups.remove(at: index)
    }

    /// Forgets what `removed` accounts held: their records leave each mail action's group, and a group with nothing
    /// left goes, as does an external step that named any of them, since its revert would write to an account that is
    /// gone. The steps of other accounts stay, in their order. Returns the identifiers of the groups that went.
    @discardableResult
    public mutating func removeAccounts(_ removed: Set<AccountID>) -> [Int] {
        guard !removed.isEmpty else { return [] }
        var gone: [Int] = []
        groups = groups.compactMap { group in
            var group = group
            if group.change == nil {
                guard group.accounts.isDisjoint(with: removed) else {
                    gone.append(group.id)
                    return nil
                }
                return group
            }
            group.records.removeAll { $0.accountID.map(removed.contains) ?? false }
            guard !group.records.isEmpty else {
                gone.append(group.id)
                return nil
            }
            group.accounts.subtract(removed)
            return group
        }
        return gone
    }
}
