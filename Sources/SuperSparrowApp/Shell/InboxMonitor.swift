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

    private func refreshCounts() {
        let unified = (try? store.unreadInboxCount(accountIDs: nil)) ?? 0
        var perAccount: [AccountID: Int] = [:]
        for id in accountIDs {
            perAccount[id] = (try? store.unreadInboxCount(accountIDs: [id])) ?? 0
        }
        let label = unified > 0 ? NumberFormatter.localizedString(from: NSNumber(value: unified), number: .decimal) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        onCounts?(unified, perAccount)
    }
}
