import Foundation

/// Brings snoozed conversations back to the Inbox when their time comes (Later, docs/ARCHITECTURE.md "Later").
///
/// It keeps no tick. It returns whatever is due, then sleeps on the continuous clock until the soonest snooze falls
/// due, or until woken: a snooze was set or changed, the Mac woke, the app came to the front, the network returned
/// (`MailEngine.checkForMail`), the wall clock was set, or an account it is waiting on checked for mail. A snooze that
/// fell due while the app was closed returns at launch, and one that fell due while the Mac slept returns at wake: the
/// continuous clock counts the sleep, so the timer is already overdue then. With nothing snoozed it keeps no timer.
///
/// A due snooze waits for its account's live lane to finish a check that began at or after its time, which the runner
/// asks for. Mail that reached the provider before the time is then in the store, so a reply, or the conversation put
/// back in the Inbox on another device, ends the snooze first (the store's rules) instead of being returned over: the
/// outbox replays before each poll, so a return queued from what the store held before the check would mark an old
/// message unread on every device and put the Back tag on a conversation the user has already seen. An account that
/// cannot check (offline, signed out, failing) holds its returns for `checkWait` of awake time at most.
///
/// Returning is one store transaction per batch: the snooze row goes, the ordinary move-to-inbox and mark-unread
/// operations are queued (so the phone and the web see the same state) and the conversation is marked returned,
/// which the Inbox sorts by. Nothing is posted: the Inbox badge and the row's “Back” tag say it came back.
actor SnoozeRunner {
    private let store: MailStoring
    private let clock: SendClock
    private let waker: SyncWaker
    private let loop = LoopHandle()
    private let checks = LiveChecks()
    /// The accounts whose operations a return queued, for their live lanes to replay.
    private let onReturn: @Sendable ([AccountID]) -> Void
    /// The accounts whose due snoozes wait for a check, for their live lanes to check now.
    private let requestCheck: @Sendable ([AccountID]) -> Void

    /// Conversations returned per transaction; more due than this go in the next one, at once.
    static let batch = 200
    /// After a store error the runner tries again this much later rather than waiting for a wake that may not come.
    static let retryDelay: TimeInterval = 30
    /// The longest a due snooze waits for its account's check, in awake time. The live lane tries again within its
    /// backoff cap (a minute), so a network that takes a few seconds to come back after a wake is still waited for.
    static let checkWait: TimeInterval = 60

    init(store: MailStoring, clock: SendClock, onReturn: @escaping @Sendable ([AccountID]) -> Void,
         requestCheck: @escaping @Sendable ([AccountID]) -> Void) {
        self.store = store
        self.clock = clock
        self.onReturn = onReturn
        self.requestCheck = requestCheck
        waker = SyncWaker(sleep: clock.sleep)
    }

    nonisolated func start() {
        loop.start { [weak self] in await self?.run() }
    }

    nonisolated func stop() {
        loop.cancel()
    }

    nonisolated func stopAndWait() async {
        await loop.cancelAndWait()
    }

    /// Looks at the snoozes now instead of when the soonest one falls due.
    nonisolated func wake() {
        waker.signal(.operations)
    }

    /// The account's live lane began a full cycle. Called from the lane, in order with `liveCheckCaughtUp`.
    nonisolated func liveCheckStarted(_ account: AccountID) {
        checks.start(account, at: clock.now())
    }

    /// The account's live lane finished that cycle and its poll caught up: what reached the provider before the cycle
    /// began is in the store. Wakes the runner when a return was waiting on it.
    nonisolated func liveCheckCaughtUp(_ account: AccountID) {
        if checks.catchUp(account) { wake() }
    }

    private func run() async {
        while !Task.isCancelled {
            let next = returnDue()
            // The wait is measured against the wall clock the due times are written in, and slept on the continuous
            // clock, which counts while the Mac sleeps. A clock set forward meanwhile wakes the runner (the engine
            // watches for it); one set back only makes the timer early, and the next look finds nothing due.
            let timeout = next.map { max(0, $0.timeIntervalSince(clock.now())) }
            _ = await waker.wait(timeout: timeout)
        }
    }

    /// Returns every snooze due now whose account has checked past its time, or has waited `checkWait` for that. Answers
    /// when to look again (the soonest snooze not yet due, or the end of a wait for a check), or nil when nothing is
    /// snoozed.
    func returnDue() -> Date? {
        do {
            var now = clock.now()
            var hold = LiveChecks.Plan()
            while !Task.isCancelled {
                now = clock.now()
                // Read before the write: the store calls back inside its transaction, where it cannot be read again.
                let due = try store.snoozes().filter { $0.dueAt <= now }
                hold = checks.plan(for: due, awake: clock.awake(), wait: Self.checkWait)
                if !hold.newlyWaiting.isEmpty { requestCheck(hold.newlyWaiting) }
                let kinds = Dictionary(try store.accounts().map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
                // A wait that ends a hair before the wall clock reaches the time finds nothing due and waits that hair again.
                let returned = try store.returnDueSnoozes(at: now, dueBy: hold.dueBy, limit: Self.batch) { id, messages in
                    Self.operations(returning: messages, of: id, kind: kinds[id.accountID] ?? .gmail, at: now)
                }
                if !returned.isEmpty {
                    var accounts: [AccountID] = []
                    for id in returned where !accounts.contains(id.accountID) { accounts.append(id.accountID) }
                    onReturn(accounts)
                    SyncLog.logger.info("snooze: returned \(returned.count, privacy: .public) conversations")
                }
                if returned.count < Self.batch { break }
            }
            let upcoming = try store.snoozes().first { $0.dueAt > now }?.dueAt
            let waitEnds = hold.waitLeft.map { now.addingTimeInterval($0) }
            return [upcoming, waitEnds].compactMap { $0 }.min()
        } catch {
            SyncLog.logger.error("snooze: could not return snoozed mail: \(String(describing: error), privacy: .private)")
            return clock.now().addingTimeInterval(Self.retryDelay)
        }
    }

    /// The ordinary operations that bring a conversation back: the mail the snooze put away to the Inbox
    /// (`MailActionRecord.returnTargets`), and the latest of it unread, so on Microsoft the unread mark lands on the
    /// message in the Inbox rather than the user's own reply in Sent Items.
    static func operations(returning messages: [MessageMetadata], of conversation: ConversationID, kind: ProviderKind,
                           at now: Date) -> [Operation] {
        let account = conversation.accountID
        var operations: [Operation] = []
        let returning = MailActionRecord.returnTargets(in: messages, kind: kind)
        let toInbox = returning.filter { applying(.moveToInbox, to: $0) != $0 }.map(\.id)
        if !toInbox.isEmpty {
            operations.append(Operation(accountID: account, change: .moveToInbox, targets: toInbox, createdAt: now))
        }
        let unread = MailActionRecord.targets(for: .setRead(false), in: returning, kind: kind).filter(\.isRead).map(\.id)
        if !unread.isEmpty {
            // A millisecond after the move, so the outbox, which orders by creation time, replays them in this order.
            operations.append(Operation(accountID: account, change: .setRead(false), targets: unread, createdAt: now.addingTimeInterval(0.001)))
        }
        return operations
    }
}

/// What the live lanes report about their checks, and which accounts the runner is waiting on. Behind a lock rather than
/// on the runner's actor, so a lane's start and end of a cycle land in the order it made them, without a hop.
private final class LiveChecks: @unchecked Sendable {
    /// What the runner may return now and how long it may still wait.
    struct Plan {
        /// For each account still waited on, the latest due time it may return: when its last check that caught up began.
        var dueBy: [AccountID: Date] = [:]
        /// Accounts the runner began waiting on just now, whose lanes are asked to check.
        var newlyWaiting: [AccountID] = []
        /// Seconds until the first wait for a check runs out, when one is under way.
        var waitLeft: TimeInterval?
    }

    private let lock = NSLock()
    /// When each account's cycle under way began, on the runner's wall clock.
    private var started: [AccountID: Date] = [:]
    /// When each account's last cycle whose poll caught up began.
    private var caughtUp: [AccountID: Date] = [:]
    /// When the runner began waiting on each account, in awake time.
    private var waiting: [AccountID: TimeInterval] = [:]
    /// Accounts whose wait ran out: what they have due goes without the check, however many batches that takes.
    private var gaveUp: Set<AccountID> = []

    func start(_ account: AccountID, at now: Date) {
        lock.withLock { started[account] = now }
    }

    /// Records the check; answers whether the runner is waiting on the account.
    func catchUp(_ account: AccountID) -> Bool {
        lock.withLock {
            if let began = started.removeValue(forKey: account) { caughtUp[account] = max(began, caughtUp[account] ?? began) }
            return waiting[account] != nil
        }
    }

    /// Splits the due snoozes: those whose account has checked since their time go, and so does all of an account that
    /// has waited `wait` already; the rest wait, and an account not waited on before is asked to check.
    func plan(for due: [Snooze], awake: TimeInterval, wait: TimeInterval) -> Plan {
        lock.withLock {
            var plan = Plan()
            var latestDue: [AccountID: Date] = [:]
            for snooze in due {
                let account = snooze.conversationID.accountID
                latestDue[account] = max(snooze.dueAt, latestDue[account] ?? snooze.dueAt)
            }
            // An account with nothing due any more (it came back, or its snoozes ended) is waited on no longer.
            waiting = waiting.filter { latestDue[$0.key] != nil }
            gaveUp = gaveUp.filter { latestDue[$0] != nil }
            for (account, latest) in latestDue.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let checked = caughtUp[account] ?? .distantPast
                if latest <= checked {
                    waiting[account] = nil
                    gaveUp.remove(account)
                    continue
                }
                if gaveUp.contains(account) { continue }
                guard let since = waiting[account] else {
                    waiting[account] = awake
                    plan.newlyWaiting.append(account)
                    plan.dueBy[account] = checked
                    plan.waitLeft = min(plan.waitLeft ?? wait, wait)
                    continue
                }
                let left = wait - (awake - since)
                if left <= 0 {
                    // Offline, signed out or failing: it comes back without the check rather than not at all.
                    waiting[account] = nil
                    gaveUp.insert(account)
                } else {
                    plan.dueBy[account] = checked
                    plan.waitLeft = min(plan.waitLeft ?? left, left)
                }
            }
            return plan
        }
    }
}
