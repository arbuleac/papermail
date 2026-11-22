import Foundation
import PaperCore

/// What Settings › Accounts › Senders… shows for one account (spec §5.52): the server's sender rules, and nothing that
/// exists only on this Mac. The server is the one source of truth, so the sheet lists the store's mirror of it (the rows
/// the last read found, with the changes to them on their way) and a rule set here only once the engine can send it.
/// Worked out from the store's rows and the engine's status alone, so the sheet never asks the provider and tests read
/// it without drawing it.
struct SendersSheetContent: Equatable {
    struct Row: Equatable {
        var address: String
        /// What the rule does: “Archived”, “Blocked”.
        var detail: String
        /// Where it stands while the server does not have it as shown: “Saving to Gmail…”, “Removing…”; nil for a saved
        /// rule.
        var state: String?
        /// A rule already being deleted on the server has nothing more to remove.
        var isRemovable: Bool
    }

    /// The banner over the list, one at most.
    enum Notice: Equatable {
        /// The account has not granted the rules permission: Allow… asks for it.
        case needsPermission(String)
        /// That sign-in waits for the browser: Cancel ends it.
        case waitingForBrowser(String)
        /// The last turn failed, in the failure's words (`danger`).
        case failed(String)
    }

    /// The line at the foot, beside Done.
    enum Foot: Equatable {
        /// The first read of this run is out: “Reading Gmail filters…” with the spinner.
        case reading(String)
        /// The server's other rules counted (“12 other filters in Gmail”, nil before a read counted them or for none), then
        /// the link to the provider's own page, nil in the demo, whose mailboxes are made up.
        case others(String?, link: String?)
    }

    var caption: String
    var rows: [Row]
    /// Whether the list is drawn at all. Without the permission the server's rules cannot be read, so there is no list,
    /// not even an empty one saying there are no rules: only the banner asking for it.
    var showsList: Bool
    var notice: Notice?
    var foot: Foot
    /// Where the foot's link goes.
    var webSettingsURL: URL?

    /// - Parameters:
    ///   - rules: the store's rows, every account's or this one's; the sheet lists this account's, by address.
    ///   - status: the engine's last word on the account; nil before it gave one.
    ///   - isReconnecting: a sign-in for this account waits for the browser.
    init(account: Account, rules: [SenderRule], status: AccountSyncStatus?, isReconnecting: Bool, isDemo: Bool) {
        let kind = account.kind
        let state = status?.rules ?? .unknown
        let mine = rules.filter { $0.accountID == account.id }.sorted { $0.address < $1.address }
        caption = SenderRuleCopy.caption(for: account)
        let shown = mine.filter { SendersSheetContent.lists($0, in: state) }
        rows = shown.map { rule in
            Row(address: rule.address, detail: SenderRuleCopy.detail(rule.action), state: SenderRuleCopy.state(of: rule, kind: kind),
                isRemovable: rule.isActive)
        }
        showsList = state != .notConnected
        switch state {
        case .notConnected:
            // Rules kept on this Mac from before 1.14 are counted, never listed: they are no rules until the server has them.
            let uploading = mine.filter { $0.sync == .creating }.count
            notice = isReconnecting ? .waitingForBrowser(SenderRuleCopy.waitingForBrowser(kind))
                : .needsPermission(SenderRuleCopy.needsPermission(kind, uploading: uploading))
        case .failed(let failure, _):
            notice = .failed(failure.words(for: kind))
        case .unknown, .upToDate:
            notice = nil
        }
        let link = isDemo ? nil : SenderRuleCopy.openSettings(kind)
        // An account waiting for sign-in reads nothing until it is reconnected (its Settings row says so): no spinner then.
        if state == .unknown, status?.phase != .needsReauth {
            foot = .reading(SenderRuleCopy.reading(kind))
        } else {
            foot = .others(state.otherCount.flatMap { SenderRuleCopy.others($0, kind: kind) }, link: link)
        }
        webSettingsURL = isDemo ? nil : SenderRuleCopy.webSettingsURL(for: account)
    }

    /// Whether a row is one of the server's rules, or a change the engine is sending there. A row with server ids is the
    /// last read's (saved, being replaced, being removed) and shows while the permission holds. A rule never saved there
    /// shows only while the engine can send it, once a read went through in this run: before the first read, or without
    /// the permission, it would be a rule of this Mac alone. A create the server refused is gone from the store with the
    /// failure's banner, so it is never listed.
    static func lists(_ rule: SenderRule, in state: RulesSyncState) -> Bool {
        switch state {
        case .notConnected: return false
        case .unknown: return !rule.serverIDs.isEmpty
        case .upToDate, .failed: return true
        }
    }
}
