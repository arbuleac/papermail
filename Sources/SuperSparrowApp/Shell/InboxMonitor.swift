import AppKit
import SSCore

/// Watches the unified inbox: keeps the Dock badge (`DockBadge`) and the rail's unread badges current, feeds new
/// rows to the notifier, and reports operations the provider gave up on (the store has already put the row back,
/// so the shell says so in a toast, §5.7). One observation serves all of them, since each fires on the same store
/// transactions. It also prunes failed operations once they are 24 hours old.
@MainActor
final class InboxMonitor {
    static let observedLimit = 300
    /// How often expired failed operations are pruned while the app runs.
    static let pruneInterval: TimeInterval = 60 * 60

    var onCounts: ((_ unified: Int, _ perAccount: [AccountID: Int]) -> Void)?
    var onRows: (([ConversationSummary]) -> Void)?
    /// Conversations that newly carry a failed operation, with its kind.
    var onFailures: (([(ConversationID, OperationKind)]) -> Void)?

    private let store: MailStoring
    private let dockBadge: DockBadge
    private var observation: StoreObservation?
    private var accountIDs: [AccountID] = []
    private var isCounting = false
    private var countsDirty = false
    /// Failures already seen; nil until the first delivery, whose marks predate this launch and stay quiet.
    private var knownFailures: Set<ConversationID>?
    private var pruneTimer: Timer?
    private static let countQueue = DispatchQueue(label: "io.supersparrow.mac.inbox-counts", qos: .userInitiated)

    /// `dockBadge` nil is the app's Dock tile.
    init(store: MailStoring, dockBadge: DockBadge? = nil) {
        self.store = store
        self.dockBadge = dockBadge ?? .app
    }

    func start(accounts: [AccountID]) {
        accountIDs = accounts
        guard observation == nil else { return }
        dockBadge.claim(self)
        observation = store.observeConversations(ConversationQuery(view: .inbox, limit: Self.observedLimit)) { [weak self] rows in
            MainActor.assumeIsolated { self?.inboxChanged(rows) }
        }
        pruneFailedOperations()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneFailedOperations() }
        }
    }

    func updateAccounts(_ accounts: [AccountID]) {
        guard accounts != accountIDs else { return }
        accountIDs = accounts
        refreshCounts()
    }

    func stop() {
        observation?.cancel()
        observation = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
        dockBadge.release(self)
    }

    private func inboxChanged(_ rows: [ConversationSummary]) {
        refreshCounts()
        onRows?(rows)
        reportFailures(in: rows)
    }

    private func reportFailures(in rows: [ConversationSummary]) {
        let failed = rows.filter { $0.failedOperation != nil }
        let ids = Set(failed.map(\.id))
        defer { knownFailures = ids }
        guard let known = knownFailures else { return }
        let fresh = failed.compactMap { row in row.failedOperation.flatMap { known.contains(row.id) ? nil : (row.id, $0) } }
        if !fresh.isEmpty { onFailures?(fresh) }
    }

    /// Off the main thread: one delete per account, each in its own transaction.
    private func pruneFailedOperations() {
        let store = self.store
        let ids = accountIDs
        Self.countQueue.async {
            for id in ids { _ = try? store.pruneFailedOperations(accountID: id, now: Date()) }
        }
    }

    /// Counts run off the main thread: with a large inbox they cost several milliseconds per account, and the
    /// observation fires on every archive, star and sync batch, right when j/k needs the main thread. One read
    /// is in flight at a time; changes that arrive meanwhile fold into a single follow-up read.
    private func refreshCounts() {
        guard !isCounting else {
            countsDirty = true
            return
        }
        isCounting = true
        countsDirty = false
        let store = self.store
        let ids = accountIDs
        Self.countQueue.async { [weak self] in
            var perAccount: [AccountID: Int] = [:]
            for id in ids {
                perAccount[id] = (try? store.unreadInboxCount(accountIDs: [id])) ?? 0
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.countsArrived(perAccount, for: ids) }
            }
        }
    }

    private func countsArrived(_ perAccount: [AccountID: Int], for ids: [AccountID]) {
        isCounting = false
        guard observation != nil else { return }
        if countsDirty || ids != accountIDs {
            refreshCounts()
            return
        }
        // Every account is counted, so the unified badge is their sum; a separate query would repeat the work.
        let unified = perAccount.values.reduce(0, +)
        dockBadge.show(unread: unified, for: self)
        onCounts?(unified, perAccount)
    }
}
