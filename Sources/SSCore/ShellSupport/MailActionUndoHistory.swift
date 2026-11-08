import Foundation

/// What Z and ⌘Z can still revert in the main window (spec §5.30, §6.1), and which toast offers it.
///
/// Each group is one step as the user saw it: a mail action, or several of the same kind within 1000 ms that
/// coalesced into one toast (“Archived 3 conversations”), or a step that is not a mail action at all (a
/// composer's discarded draft, §5.20), which the caller reverts itself. A group with a toast is reachable while the toast is
/// visible and for the grace period after it leaves; a group the row shows by itself (a star, one mark as
/// unread, §4.13) never gets a toast and is reachable for the grace period from when it happened.
///
/// A visible toast is a promise (“Undo Z”), so while one shows Z reverts its group even when a quieter action
/// came after it; otherwise Z reverts the latest group still within its grace. A toast's own Undo button always
/// reverts its own group. Pure, so the shell's undo rules are tested without a window.
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

    public static let capacity = 20

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
        return append(records: records, change: records[0].change, externalCommand: nil, at: now, toasted: toasted,
                      coalesces: coalesces)
    }

    /// Starts a group for a step the caller reverts itself (the composer's “Draft discarded”), named by its
    /// command (“Discard Draft”). It sits in the same history as the mail actions, so Z and ⌘Z reach
    /// whichever came last, and it coalesces only when its caller asks (`coalesceExternal`) and `coalesces` allows it:
    /// an unsubscribe in Later is named Archive, as E there is, yet takes in no later E.
    @discardableResult
    public mutating func addExternal(command: String, at now: Date, toasted: Bool, coalesces: Bool = true) -> Int {
        append(records: [], change: nil, externalCommand: command, at: now, toasted: toasted, coalesces: coalesces)
    }

    /// One more external step of `command` joins the latest group on the terms `coalesce` sets for mail actions: that
    /// group is a step of the same command, its toast is still the visible one and the last step was within the
    /// coalescing window. E in Later ends snoozes rather than archiving, so it is no mail action, yet it coalesces as E
    /// does everywhere. Returns the grown group, whose revert the caller extends, or nil when the step must start a group
    /// of its own.
    public mutating func coalesceExternal(command: String, at now: Date, visibleToastID: Int?) -> Group? {
        guard var last = groups.last, last.coalesces, last.externalCommand == command, let toastID = last.toastID,
              toastID == visibleToastID, now.timeIntervalSince(last.lastActionAt) <= coalesceWindow else { return nil }
        last.lastActionAt = now
        groups[groups.count - 1] = last
        return last
    }

    private mutating func append(records: [MailActionRecord], change: MetadataChange?, externalCommand: String?, at now: Date,
                                 toasted: Bool, coalesces: Bool) -> Int {
        let id = nextID
        nextID += 1
        groups.append(Group(id: id, records: records, change: change, externalCommand: externalCommand, lastActionAt: now,
                            toastID: nil, expiresAt: toasted ? nil : now.addingTimeInterval(grace), coalesces: coalesces))
        if groups.count > Self.capacity { groups.removeFirst(groups.count - Self.capacity) }
        return id
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

    /// The group Z and ⌘Z revert now, if any.
    public func target(at now: Date, visibleToastID: Int?) -> Group? {
        if let shown = toastGroup(visibleToastID: visibleToastID) { return shown }
        return graceGroup(at: now)
    }

    /// The group the visible toast offers (§6.1 ⌘Z row 2), if a toast is up and offers one.
    public func toastGroup(visibleToastID: Int?) -> Group? {
        guard let visibleToastID else { return nil }
        return groups.last { $0.toastID == visibleToastID }
    }

    /// The latest group whose toast has gone (or that never had one) and is still within its grace (row 3).
    public func graceGroup(at now: Date) -> Group? {
        guard let last = groups.last, let expiresAt = last.expiresAt, now <= expiresAt else { return nil }
        return last
    }

    /// Takes group `id` out of the history to revert it; nil when it is no longer there.
    public mutating func remove(_ id: Int) -> Group? {
        guard let index = groups.lastIndex(where: { $0.id == id }) else { return nil }
        return groups.remove(at: index)
    }
}
