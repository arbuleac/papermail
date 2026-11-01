import AppKit
import SSCore

/// Watches the unified inbox: keeps the Dock badge and the strip's unread badges current and feeds new rows
/// to the notifier. One observation serves all three, since each fires on the same store transactions.
@MainActor
final class InboxMonitor {
    static let observedLimit = 300

    var onCounts: ((_ unified: Int, _ perAccount: [AccountID: Int]) -> Void)?
    var onRows: (([ConversationSummary]) -> Void)?

    private let store: MailStoring
    private var observation: StoreObservation?
    private var accountIDs: [AccountID] = []
    private var isCounting = false
    private var countsDirty = false
    private static let countQueue = DispatchQueue(label: "io.supersparrow.mac.inbox-counts", qos: .userInitiated)

    init(store: MailStoring) {
        self.store = store
    }

    func start(accounts: [AccountID]) {
        accountIDs = accounts
        guard observation == nil else { return }
        observation = store.observeConversations(ConversationQuery(view: .inbox, limit: Self.observedLimit)) { [weak self] rows in
            MainActor.assumeIsolated { self?.inboxChanged(rows) }
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
        NSApp.dockTile.badgeLabel = nil
    }

    private func inboxChanged(_ rows: [ConversationSummary]) {
        refreshCounts()
        onRows?(rows)
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
        let label = unified > 0 ? NumberFormatter.localizedString(from: NSNumber(value: unified), number: .decimal) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        onCounts?(unified, perAccount)
    }
}
