import Foundation

/// What the sync status line under the list says (spec §5.11), reduced from every account's status by the
/// eleven-step precedence: the first rule that matches wins, and the tooltip lists every account's own state in
/// the words Settings › Accounts uses.
///
/// One account in the winning state is named; two or more are counted, never listed (“Sign in required ·
/// Fabrikam” / “Sign in required · 2 accounts”). Pure, so the precedence and the copy are tested without a
/// window.
///
/// A status's `phase` is the live lane's (new mail, sends). Older mail the backfill lane downloads behind it
/// never takes the line: new mail is up to date, so the line says Up to date and how far the older mail has
/// come, or until when the provider has paused it.
public struct SyncLineSummary: Equatable, Sendable {
    public enum State: Int, Equatable, Sendable, CaseIterable {
        case signingIn = 1
        case signInRequired
        case error
        case offline
        case slow
        case sending
        case downloading
        case checking
        /// Mail is current, but sender rules set or removed on this Mac wait for the permission to save them on the
        /// server (spec §5.52): they act nowhere until it is granted, so the line asks rather than leave it to Settings.
        case rulesPermission
        case demo
        case upToDate
    }

    /// The leading glyph, named by meaning; the view maps it to a symbol and colour.
    public enum Glyph: Equatable, Sendable {
        case upToDate
        case spinner
        case offline
        case retrying
        case alert
        case info
    }

    /// The trailing link, when the state offers one.
    public enum Action: Equatable, Sendable {
        /// “Reconnect”: one account needs signing in.
        case reconnect(AccountID)
        /// “Reconnect…”: several do; opens Settings › Accounts, where each row has its own Reconnect.
        case reconnectSeveral
        /// “Retry”: every failed account syncs again.
        case retry([AccountID])
        /// “Cancel”: stops waiting for the browser.
        case cancelSignIn
        /// “Reconnect”: one account's sender rules wait for the rules permission; the sign-in asks for it
        /// (`MailClient.connectRules`).
        case connectRules(AccountID)

        public var title: String {
            switch self {
            case .reconnect, .connectRules: return "Reconnect"
            case .reconnectSeveral: return "Reconnect…"
            case .retry: return "Retry"
            case .cancelSignIn: return "Cancel"
            }
        }
    }

    /// A browser sign-in the user started and the app is waiting on.
    public enum SignIn: Equatable, Sendable {
        /// Adding an account; the provider, when known, names the wait (“· Gmail”).
        case adding(ProviderKind?)
        /// Reconnecting an existing account; its name names the wait (“· Fabrikam”).
        case reconnecting(AccountID)
    }

    /// Everything the line is chosen from.
    public struct Input: Sendable {
        public var statuses: [AccountSyncStatus]
        public var accounts: [Account]
        public var isDemo: Bool
        public var isNetworkReachable: Bool
        public var signIn: SignIn?
        /// Sends past their undo window and still in flight.
        public var sendingCount: Int
        /// A check the user asked for has run at least 150 ms.
        public var isChecking: Bool
        /// The moment “retrying in 30 s” counts from.
        public var now: Date
        /// The accounts with sender rules set or removed on this Mac and not yet on the server (`MailStoring
        /// .pendingSenderRules`); with `AccountSyncStatus.rules == .notConnected` they wait for the permission.
        public var rulesWaiting: Set<AccountID>

        public init(statuses: [AccountSyncStatus], accounts: [Account], isDemo: Bool = false, isNetworkReachable: Bool = true,
                    signIn: SignIn? = nil, sendingCount: Int = 0, isChecking: Bool = false, now: Date = Date(),
                    rulesWaiting: Set<AccountID> = []) {
            self.statuses = statuses
            self.accounts = accounts
            self.isDemo = isDemo
            self.isNetworkReachable = isNetworkReachable
            self.signIn = signIn
            self.sendingCount = sendingCount
            self.isChecking = isChecking
            self.now = now
            self.rulesWaiting = rulesWaiting
        }
    }

    public var state: State
    public var glyph: Glyph
    /// The lead phrase, `metaMedium` `ink2` (`danger` for alerts).
    public var lead: String
    /// What follows the lead after “ · ”, if anything.
    public var detail: String?
    public var action: Action?
    /// The whole line draws in `danger` (Sign in required, Error).
    public var isAlert: Bool
    /// Determinate progress for the contrail along the top edge, while downloading with a known total: the first
    /// page (Downloading), or older mail behind Up to date.
    public var progress: Double?
    /// Every account's own state, for the tooltip.
    public var tooltip: String?
    /// The line counts a retry down (“retrying in 30 s”), so it reads differently every second without a status
    /// changing. Only Slow does: under another line a retry ahead shows no count, or one in the tooltip alone.
    public var countsDown: Bool

    public init(state: State, glyph: Glyph, lead: String, detail: String? = nil, action: Action? = nil, isAlert: Bool = false,
                progress: Double? = nil, tooltip: String? = nil, countsDown: Bool = false) {
        self.state = state
        self.glyph = glyph
        self.lead = lead
        self.detail = detail
        self.action = action
        self.isAlert = isAlert
        self.progress = progress
        self.tooltip = tooltip
        self.countsDown = countsDown
    }

    /// The whole line as one sentence, for VoiceOver: “Sign in required, Fabrikam. Reconnect.”
    public var spokenText: String {
        var text = lead
        if let detail { text += ", " + detail }
        return text
    }

    // MARK: Choosing

    public static func make(_ input: Input, checkedFormatter: (Date) -> String = SyncLineSummary.timeOfDay,
                            numberFormatter: (Int) -> String = SyncLineSummary.grouped) -> SyncLineSummary {
        let byID = Dictionary(input.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A status can outlive its account by a moment (removal, a store swapped underneath); only accounts the
        // shell shows take part.
        let statuses = input.statuses.filter { byID[$0.accountID] != nil }
        // Offline: no network path, or everything that is not idle failed on the network.
        let busy = statuses.filter { isActive($0) }
        let isOffline = !input.isNetworkReachable || (!busy.isEmpty && busy.allSatisfy { $0.phase == .error && isNetworkFailure($0) })
        let tooltip = tooltipText(statuses: statuses, accounts: byID, signIn: input.signIn, isOffline: isOffline, isDemo: input.isDemo,
                                  isChecking: input.isChecking, now: input.now, numberFormatter: numberFormatter,
                                  timeFormatter: checkedFormatter, rulesWaiting: input.rulesWaiting)
        func name(_ id: AccountID) -> String {
            byID[id].map(AccountLabels.name(for:)) ?? "an account"
        }
        func named(_ ids: [AccountID]) -> String {
            ids.count == 1 ? name(ids[0]) : "\(ids.count) accounts"
        }

        // 1. A sign-in the user started answers their own action, and its Cancel lives only here.
        if let signIn = input.signIn {
            let detail: String?
            switch signIn {
            case .adding(let kind): detail = kind.map(providerName)
            case .reconnecting(let id): detail = name(id)
            }
            return SyncLineSummary(state: .signingIn, glyph: .spinner, lead: "Finish signing in in your browser", detail: detail,
                                   action: .cancelSignIn, tooltip: tooltip)
        }
        // 2. Sign-in required.
        let reauth = statuses.filter { $0.phase == .needsReauth }.map(\.accountID)
        if !reauth.isEmpty {
            return SyncLineSummary(state: .signInRequired, glyph: .alert, lead: "Sign in required", detail: named(reauth),
                                   action: reauth.count == 1 ? .reconnect(reauth[0]) : .reconnectSeveral, isAlert: true, tooltip: tooltip)
        }
        // 3. A failure that is not the network's.
        let failed = statuses.filter { $0.phase == .error && !isNetworkFailure($0) }
        if !failed.isEmpty {
            let ids = failed.map(\.accountID)
            let lead = "Couldn't sync \(named(ids))"
            let detail = ids.count == 1 ? reason(for: failed[0].message) : nil
            return SyncLineSummary(state: .error, glyph: .alert, lead: lead, detail: detail, action: .retry(ids), isAlert: true,
                                   tooltip: tooltip)
        }
        // 4. Offline.
        if isOffline {
            return SyncLineSummary(state: .offline, glyph: .offline, lead: "Offline", detail: "changes will sync when you're back",
                                   tooltip: tooltip)
        }
        // 5. Slow or retrying: a network failure while others are online, or the server asked the live lane to slow
        // down. A throttled backfill is not here: new mail still arrives, so it reads as paused under Up to date.
        let networkFailed = statuses.filter { $0.phase == .error && isNetworkFailure($0) }
        let slow = networkFailed + statuses.filter(isRateLimited)
        if !slow.isEmpty {
            let ids = slow.map(\.accountID)
            let lead = ids.count == 1 ? "\(name(ids[0])) is slow to respond" : "\(ids.count) accounts are slow to respond"
            // The soonest retry, counted down; “shortly” while the engine has not said when.
            let soonest = slow.compactMap { retrySeconds(until: $0.retryAt, now: input.now) }.min()
            let detail = soonest.map { "retrying in \($0) s" } ?? "retrying shortly"
            return SyncLineSummary(state: .slow, glyph: .retrying, lead: lead, detail: detail, tooltip: tooltip, countsDown: soonest != nil)
        }
        // 6. Sending after the undo window.
        if input.sendingCount > 0 {
            let lead = input.sendingCount == 1 ? "Sending 1 message" : "Sending \(numberFormatter(input.sendingCount)) messages"
            return SyncLineSummary(state: .sending, glyph: .spinner, lead: lead, tooltip: tooltip)
        }
        // 7. A new account's first page of newest mail, before it has a change cursor. The older mail downloaded
        // behind it (the backfill) and body downloads never take the line.
        let downloading = statuses.filter { $0.phase == .bootstrapping }
        if !downloading.isEmpty {
            let ids = downloading.map(\.accountID)
            let count = downloading.compactMap(\.bootstrapProgress).reduce(0, +)
            // “3,412 of 8,120” summed over the downloading accounts, only while every one of them has a total.
            let totals = downloading.compactMap { status in status.bootstrapTotal.map { max($0, status.bootstrapProgress ?? 0) } }
            let total = totals.count == downloading.count ? totals.reduce(0, +) : nil
            let detail: String
            var progress: Double?
            if let total, total > 0 {
                detail = "\(named(ids)) · \(numberFormatter(count)) of \(numberFormatter(total))"
                progress = min(1, Double(count) / Double(total))
            } else {
                detail = count > 0 ? "\(named(ids)) · \(numberFormatter(count)) messages" : "\(named(ids))…"
            }
            return SyncLineSummary(state: .downloading, glyph: .spinner, lead: "Downloading mail", detail: detail, progress: progress,
                                   tooltip: tooltip)
        }
        // 8. A check the user asked for.
        if input.isChecking {
            return SyncLineSummary(state: .checking, glyph: .spinner, lead: "Checking for mail…", tooltip: tooltip)
        }
        // 9. Sender rules waiting for the permission to save them on the server: they act nowhere until then (an
        // existing user's rules, uploaded once, among them), so the line asks, with the sign-in that grants it.
        let rulesBlocked = statuses.filter { $0.rules == .notConnected && input.rulesWaiting.contains($0.accountID) }.map(\.accountID)
        if !rulesBlocked.isEmpty {
            return SyncLineSummary(state: .rulesPermission, glyph: .info, lead: "Sender rules need permission", detail: named(rulesBlocked),
                                   action: rulesBlocked.count == 1 ? .connectRules(rulesBlocked[0]) : .reconnectSeveral, tooltip: tooltip)
        }
        // 10. Demo mode replaces Up to date.
        if input.isDemo {
            return SyncLineSummary(state: .demo, glyph: .info, lead: "Demo", detail: "made-up mail, nothing syncs", tooltip: tooltip)
        }
        // 11. Up to date, and how far older mail has come while any account downloads it.
        let ids = input.accounts.map(\.id)
        var parts: [String] = []
        if !ids.isEmpty { parts.append(named(ids)) }
        let older = statuses.compactMap { OlderMail($0, now: input.now) }
        let checked = statuses.compactMap(\.lastSuccessfulSyncAt).max().map(checkedFormatter)
        var progress: Double?
        var fullTooltip = tooltip
        if !older.isEmpty {
            // The line has room for one figure and the download's is the news, so “checked 23:41” moves to the
            // tooltip, on a line of its own after the accounts.
            let line = olderMailLine(older, numberFormatter: numberFormatter, timeFormatter: checkedFormatter)
            parts.append(line.words)
            progress = line.progress
            if let checked { fullTooltip = [tooltip, "Checked \(checked)"].compactMap { $0 }.joined(separator: "\n") }
        } else if let checked {
            parts.append("checked \(checked)")
        }
        return SyncLineSummary(state: .upToDate, glyph: .upToDate, lead: "Up to date",
                               detail: parts.isEmpty ? nil : parts.joined(separator: " · "), progress: progress, tooltip: fullTooltip)
    }

    /// “older mail 3,412 of 8,120” summed over every account downloading older mail, paused ones included so the
    /// figure does not jump when one pauses; “older mail paused until 10:42” (the soonest resume) once all of
    /// them are paused. The fraction only while every total is known and one of them is running.
    private static func olderMailLine(_ older: [OlderMail], numberFormatter: (Int) -> String,
                                      timeFormatter: (Date) -> String) -> (words: String, progress: Double?) {
        let pauses = older.compactMap(\.pausedUntil)
        if pauses.count == older.count, let soonest = pauses.min() {
            return ("older mail paused until \(timeFormatter(soonest))", nil)
        }
        let done = older.map(\.done).reduce(0, +)
        let totals = older.compactMap(\.total)
        let total = totals.count == older.count ? totals.reduce(0, +) : 0
        if total > 0 {
            return ("older mail \(numberFormatter(done)) of \(numberFormatter(total))", min(1, Double(done) / Double(total)))
        }
        return (done > 0 ? "older mail \(numberFormatter(done))" : "older mail…", nil)
    }

    // MARK: Classifying

    /// The engine writes network failures as “network: …” (`SyncErrorDescription`).
    public static func isNetworkFailure(_ status: AccountSyncStatus) -> Bool {
        (status.message ?? "").hasPrefix("network")
    }

    /// The engine pauses a throttled account with a “Rate limited” message; a plain pause is the engine stopping.
    public static func isRateLimited(_ status: AccountSyncStatus) -> Bool {
        status.phase == .paused && (status.message ?? "").localizedCaseInsensitiveContains("rate limited")
    }

    /// Doing something, or failed: every phase but idle and a plain pause.
    private static func isActive(_ status: AccountSyncStatus) -> Bool {
        switch status.phase {
        case .idle: return false
        case .paused: return isRateLimited(status)
        default: return true
        }
    }

    /// A short reason in plain words for the line; the full message stays in Settings.
    static func reason(for message: String?) -> String? {
        guard let message, !message.isEmpty else { return nil }
        if message.hasPrefix("server") { return "the server returned an error" }
        if message.hasPrefix("decoding") { return "unexpected reply from the server" }
        if message.hasPrefix("not found") { return "the mailbox wasn't found" }
        return "see Settings"
    }

    public static func providerName(_ kind: ProviderKind) -> String {
        switch kind {
        case .gmail: return "Gmail"
        case .microsoft: return "Microsoft"
        }
    }

    // MARK: Tooltip

    /// “Contoso: Downloading 3,412 messages · Fabrikam: Sign in required · Gmail: Offline”. While the line says
    /// Offline, every account that has not failed for another reason says so too; demo accounts that are not
    /// doing anything read as Settings shows them, “Made up, nothing syncs”.
    ///
    /// A check nobody asked for (the live lane's, every 5 s while the app is frontmost) reads as idle, as Settings
    /// shows it once the account has synced: otherwise the tooltip would flip between “Checking for mail…” and
    /// “Up to date” with every poll while the line, rightly, stays put.
    static func tooltipText(statuses: [AccountSyncStatus], accounts: [AccountID: Account], signIn: SignIn?, isOffline: Bool,
                            isDemo: Bool, isChecking: Bool = false, now: Date = Date(), numberFormatter: (Int) -> String,
                            timeFormatter: (Date) -> String = timeOfDay, rulesWaiting: Set<AccountID> = []) -> String? {
        let parts = statuses.compactMap { original -> String? in
            guard let account = accounts[original.accountID] else { return nil }
            var status = original
            if status.phase == .syncing, status.lastSuccessfulSyncAt != nil, !isChecking { status.phase = .idle }
            let words: String
            if case .reconnecting(let id)? = signIn, id == status.accountID {
                words = "Waiting for your browser"
            } else if isOffline, status.phase != .needsReauth, status.phase != .error || isNetworkFailure(status) {
                words = "Offline"
            } else if isDemo, status.phase == .idle || (status.phase == .paused && !isRateLimited(status)) {
                words = "Made up, nothing syncs"
            } else {
                words = accountWords(status, now: now, numberFormatter: numberFormatter, timeFormatter: timeFormatter,
                                     rulesWaiting: rulesWaiting.contains(status.accountID))
            }
            return "\(AccountLabels.name(for: account)): \(words)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The per-account words Settings › Accounts uses (§5.40). Up to date carries the older-mail download behind
    /// it: “Up to date · older mail 3,412 of 8,120”, “Up to date · older mail paused until 10:42”, and once that
    /// mail is listed, “Up to date · downloading messages…” while its bodies arrive. `rulesWaiting`: the account has
    /// sender rules on their way to the server, which wait while it lacks the rules permission.
    public static func accountWords(_ status: AccountSyncStatus, now: Date = Date(), numberFormatter: (Int) -> String = grouped,
                                    timeFormatter: (Date) -> String = timeOfDay, rulesWaiting: Bool = false) -> String {
        let retrying = retrySeconds(until: status.retryAt, now: now).map { "Retrying in \($0) s" } ?? "Retrying shortly"
        let upToDate = olderMailWords(status, now: now, numberFormatter: numberFormatter, timeFormatter: timeFormatter)
            .map { "Up to date · \($0)" } ?? (status.backfillDownloadingBodies ? "Up to date · downloading messages…" : "Up to date")
        switch status.phase {
        // Mail is current, but an answered invitation, or a sender rule, waits for a permission (spec §5.40): Settings
        // asks to reconnect. The invitation's first, as Settings shows it.
        case .idle:
            if !status.permissionsNeeded.isEmpty { return "Calendar permission needed" }
            return rulesWaiting && status.rules == .notConnected ? "Sender rules need permission" : upToDate
        case .bootstrapping:
            let count = status.bootstrapProgress ?? 0
            if let total = status.bootstrapTotal, total > 0 {
                return "Downloading \(numberFormatter(count)) of \(numberFormatter(max(total, count)))"
            }
            return count > 0 ? "Downloading \(numberFormatter(count)) messages" : "Downloading"
        case .hydrating: return "Downloading messages…"
        case .syncing: return "Checking for mail…"
        case .paused: return isRateLimited(status) ? retrying : upToDate
        case .needsReauth: return "Sign in required"
        case .error: return isNetworkFailure(status) ? retrying : "Couldn't sync"
        }
    }

    /// One account's older-mail download in words, without the lead: “older mail 3,412 of 8,120”, “older mail
    /// 3,412” while the total is unknown, “older mail paused until 10:42” while the provider holds it back. Nil
    /// while no backfill runs.
    public static func olderMailWords(_ status: AccountSyncStatus, now: Date = Date(), numberFormatter: (Int) -> String = grouped,
                                      timeFormatter: (Date) -> String = timeOfDay) -> String? {
        guard let older = OlderMail(status, now: now) else { return nil }
        return olderMailLine([older], numberFormatter: numberFormatter, timeFormatter: timeFormatter).words
    }

    /// The fraction of one account's older mail downloaded, for Settings' bar: only while the total is known and
    /// the download is not paused.
    public static func olderMailFraction(_ status: AccountSyncStatus, now: Date = Date()) -> Double? {
        guard let older = OlderMail(status, now: now) else { return nil }
        return olderMailLine([older], numberFormatter: grouped, timeFormatter: timeOfDay).progress
    }

    /// Whole seconds until `retryAt`, at least 1 while it is ahead; nil when unknown or past (“Retrying shortly”).
    public static func retrySeconds(until retryAt: Date?, now: Date) -> Int? {
        guard let retryAt else { return nil }
        let interval = retryAt.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        return max(1, Int(interval.rounded(.up)))
    }

    /// The backfill lane's listing for one account, as of `now`. Only while it lists: once the older mail is
    /// listed, a throttle on its body downloads is no older mail to report (rule 7: bodies never take the line), and
    /// counting it would also drop another account's total from the sum.
    private struct OlderMail {
        var done: Int
        /// Never below `done`: the provider's figure is an estimate, and “9 of 8” would read as a mistake.
        var total: Int?
        /// Only while still ahead of `now`: a resume time that has passed reads as running until the engine says.
        var pausedUntil: Date?

        init?(_ status: AccountSyncStatus, now: Date) {
            guard let done = status.backfillProgress else { return nil }
            let pausedUntil = status.backfillPausedUntil.flatMap { $0 > now ? $0 : nil }
            self.done = done
            total = status.backfillTotal.map { max($0, done) }
            self.pausedUntil = pausedUntil
        }
    }

    // MARK: Formatting

    /// “23:41”, in the user's 12/24-hour setting.
    public static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// “3,412”, in the locale's grouping.
    public static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
