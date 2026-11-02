import Foundation

/// What Z and ⌘Z can still revert in the main window (spec §5.30, §6.1), and which toast offers it.
///
/// Each group is one step as the user saw it: a mail action, or several of the same kind within 1000 ms that
/// coalesced into one toast (“Archived 3 conversations”). A group with a toast is reachable while the toast is
/// visible and for the grace period after it leaves; a group the row shows by itself (a star, one mark as
/// unread, §4.13) never gets a toast and is reachable for the grace period from when it happened.
///
/// A visible toast is a promise (“Undo Z”), so while one shows Z reverts its group even when a quieter action
/// came after it; otherwise Z reverts the latest group still within its grace. A toast's own Undo button always
/// reverts its own group. Pure, so the shell's undo rules are tested without a window.
public struct MailActionUndoHistory: Sendable {
    public struct Group: Sendable {
        public let id: Int
        public fileprivate(set) var records: [MailActionRecord]
        public let change: MetadataChange
        public fileprivate(set) var lastActionAt: Date
        /// The toast offering the group, while that toast is visible.
        public fileprivate(set) var toastID: Int?
        /// Once its toast has gone, or from the start when it never had one: Z reaches it until then.
        public fileprivate(set) var expiresAt: Date?
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
        guard var last = groups.last, last.change == record.change, let toastID = last.toastID, toastID == visibleToastID,
              now.timeIntervalSince(last.lastActionAt) <= coalesceWindow else { return nil }
        last.records.append(record)
        last.lastActionAt = now
        groups[groups.count - 1] = last
        return last
    }

    /// Starts a group for `record` and returns its identifier. A group that gets a toast is bound to it with
    /// `bindToast(_:to:)`; one that does not starts its grace now.
    @discardableResult
    public mutating func add(_ record: MailActionRecord, at now: Date, toasted: Bool) -> Int {
        let id = nextID
        nextID += 1
        groups.append(Group(id: id, records: [record], change: record.change, lastActionAt: now,
                            toastID: nil, expiresAt: toasted ? nil : now.addingTimeInterval(grace)))
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
        if let visibleToastID, let shown = groups.last(where: { $0.toastID == visibleToastID }) { return shown }
        guard let last = groups.last, let expiresAt = last.expiresAt, now <= expiresAt else { return nil }
        return last
    }

    /// Takes group `id` out of the history to revert it; nil when it is no longer there.
    public mutating func remove(_ id: Int) -> Group? {
        guard let index = groups.lastIndex(where: { $0.id == id }) else { return nil }
        return groups.remove(at: index)
    }
}
