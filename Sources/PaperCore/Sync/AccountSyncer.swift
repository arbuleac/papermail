import Foundation

/// Drives one account in two lanes that run side by side and stop together, plus the calendar lane for a provider that
/// has a calendar and the rules lane for one that keeps server rules.
///
/// The `LiveLane` owns the change cursor: it takes one from the newest page when the account has none, replays
/// the outbox and polls for changes every few seconds, so new mail and the user's own actions never queue
/// behind older mail. The `BackfillLane` downloads that older mail and the missing bodies behind it, paced by
/// the account's `QuotaBudget`. They share a `LaneLink`: the live lane wakes the backfill lane when it sets up
/// a backfill or leaves bodies for it, either lane parks both when the token is refused, and the live lane
/// fences off backfill writes while it replaces the backfill. The `CalendarLane` sends the time set aside and removed
/// on this Mac and reads the account's calendar; the live lane tells it each time a full cycle has caught up, and it
/// shares the link only to send nothing while the account is parked (docs/ARCHITECTURE.md, "Calendar"). The `RulesLane`
/// reads the server's rules and sends the sender rules set and removed on this Mac, woken the same way
/// (docs/ARCHITECTURE.md, "Rules").
///
/// `wake(.poll)` and `wake(.operations)` reach the live lane; the backfill lane is the live lane's to wake.
/// `refreshCalendar()`, `refreshCalendar(covering:)` and `sendCalendarWrites()` reach the calendar lane, and the live
/// lane wakes it when the outbox has sent an answer to an invitation.
final class AccountSyncer: Sendable {
    let accountID: AccountID
    private let live: LiveLane
    private let backfill: BackfillLane
    /// Nil when the provider has no calendar (`CalendarProvider`).
    private let calendar: CalendarLane?
    /// Nil when the provider keeps no server rules (`RuleProvider`).
    private let rules: RulesLane?
    private let link = LaneLink()
    private let loop = LoopHandle()

    init(
        accountID: AccountID,
        store: MailStoring,
        provider: MailProvider,
        hydrator: Hydrator,
        runner: OperationRunner,
        statusCenter: SyncStatusCenter,
        tokenProvider: AccessTokenProvider,
        tuning: SyncTuning,
        budget: QuotaBudget,
        isAppActive: @escaping @Sendable () -> Bool,
        firstLiveCycleEnded: @escaping @Sendable () -> Void = {},
        backfillEnded: @escaping @Sendable () -> Void = {},
        liveCheckStarted: @escaping @Sendable () -> Void = {},
        liveCheckCaughtUp: @escaping @Sendable () -> Void = {}
    ) {
        self.accountID = accountID
        var calendar: CalendarLane?
        if let calendarProvider = provider as? CalendarProvider {
            calendar = CalendarLane(accountID: accountID, store: store, provider: calendarProvider, statusCenter: statusCenter,
                                    tuning: tuning, budget: budget, link: link, isAppActive: isAppActive)
        }
        self.calendar = calendar
        var rules: RulesLane?
        if let ruleProvider = provider as? RuleProvider {
            rules = RulesLane(accountID: accountID, store: store, provider: ruleProvider, statusCenter: statusCenter,
                              tuning: tuning, budget: budget, link: link, isAppActive: isAppActive)
        }
        self.rules = rules
        live = LiveLane(
            accountID: accountID,
            store: store,
            provider: provider,
            hydrator: hydrator,
            runner: runner,
            statusCenter: statusCenter,
            tokenProvider: tokenProvider,
            tuning: tuning,
            budget: budget,
            link: link,
            isAppActive: isAppActive,
            firstCycleEnded: firstLiveCycleEnded,
            checkStarted: liveCheckStarted,
            checkCaughtUp: liveCheckCaughtUp,
            cycleCaughtUp: { [calendar, rules] in
                calendar?.wake(.check)
                rules?.wake(.check)
            },
            invitationAnswered: { [calendar] in calendar?.wake(.poll) }
        )
        backfill = BackfillLane(
            accountID: accountID,
            store: store,
            provider: provider,
            hydrator: hydrator,
            statusCenter: statusCenter,
            tuning: tuning,
            budget: budget,
            link: link,
            backfillEnded: backfillEnded
        )
    }

    var isRunning: Bool { loop.isRunning }

    /// Starts the lanes unless they are running. A fresh start tries the token again.
    func start() {
        loop.start { [live, backfill, calendar, rules, link] in
            link.reset()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await live.run() }
                group.addTask { await backfill.run() }
                if let calendar { group.addTask { await calendar.run() } }
                if let rules { group.addTask { await rules.run() } }
            }
        }
    }

    func stop() {
        loop.cancel()
    }

    /// Returns once every lane has finished.
    func stopAndWait() async {
        await loop.cancelAndWait()
    }

    func wake(_ reason: WakeReason) {
        link.liveWaker.signal(reason)
    }

    /// Has the calendar lane read at its next chance: at once when it is idle and the account is not parked, otherwise
    /// as soon as it is (`MailClient.refreshCalendars`).
    func refreshCalendar() {
        calendar?.wake(.poll)
    }

    /// Has the calendar lane read `interval` once at its next turn, besides its window (`MailClient.refreshCalendars(
    /// accountID:covering:)`).
    func refreshCalendar(covering interval: DateInterval) {
        calendar?.read(covering: interval)
    }

    /// A card is open on the event: the calendar lane reads its details at its next chance.
    func readCalendarDetails(_ eventID: String) {
        calendar?.readDetails(eventID)
    }

    /// Time set aside or removed on this Mac waits for the provider: the calendar lane sends it at its next chance.
    func sendCalendarWrites() {
        calendar?.wake(.operations)
    }

    /// Whether the provider keeps server rules, so the account has a rules lane.
    var hasRulesLane: Bool {
        rules != nil
    }

    /// Has the rules lane read the server's rules at its next chance (`MailClient.refreshServerRules`).
    func refreshRules() {
        rules?.wake(.poll)
    }

    /// A sender rule set, changed or removed on this Mac waits for the server: the rules lane sends it at its next chance.
    func sendRuleWrites() {
        rules?.wake(.operations)
    }
}
