import Foundation

/// Drives one account in two lanes that run side by side and stop together.
///
/// The `LiveLane` owns the change cursor: it takes one from the newest page when the account has none, replays
/// the outbox and polls for changes every few seconds, so new mail and the user's own actions never queue
/// behind older mail. The `BackfillLane` downloads that older mail and the missing bodies behind it, paced by
/// the account's `QuotaBudget`. They share a `LaneLink`: the live lane wakes the backfill lane when it sets up
/// a backfill or leaves bodies for it, either lane parks both when the token is refused, and the live lane
/// fences off backfill writes while it replaces the backfill.
///
/// `wake(.poll)` and `wake(.operations)` reach the live lane; the backfill lane is the live lane's to wake.
final class AccountSyncer: Sendable {
    let accountID: AccountID
    private let live: LiveLane
    private let backfill: BackfillLane
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
            checkCaughtUp: liveCheckCaughtUp
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

    /// Starts both lanes unless they are running. A fresh start tries the token again.
    func start() {
        loop.start { [live, backfill, link] in
            link.reset()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await live.run() }
                group.addTask { await backfill.run() }
            }
        }
    }

    func stop() {
        loop.cancel()
    }

    /// Returns once both lanes have finished.
    func stopAndWait() async {
        await loop.cancelAndWait()
    }

    func wake(_ reason: WakeReason) {
        link.liveWaker.signal(reason)
    }
}
