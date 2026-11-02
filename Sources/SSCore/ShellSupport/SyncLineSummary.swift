import Foundation

/// What the sync status line under the list says (spec §5.11), reduced from every account's status by the
/// ten-step precedence: the first rule that matches wins, and the tooltip lists every account's own state in
/// the words Settings › Accounts uses.
///
/// One account in the winning state is named; two or more are counted, never listed (“Sign in required ·
/// Fabrikam” / “Sign in required · 2 accounts”). Pure, so the precedence and the copy are tested without a
/// window.
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

        public var title: String {
            switch self {
            case .reconnect: return "Reconnect"
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

        public init(statuses: [AccountSyncStatus], accounts: [Account], isDemo: Bool = false, isNetworkReachable: Bool = true,
                    signIn: SignIn? = nil, sendingCount: Int = 0, isChecking: Bool = false, now: Date = Date()) {
            self.statuses = statuses
            self.accounts = accounts
            self.isDemo = isDemo
            self.isNetworkReachable = isNetworkReachable
            self.signIn = signIn
            self.sendingCount = sendingCount
            self.isChecking = isChecking
            self.now = now
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
    /// Determinate progress for the contrail along the top edge, while downloading with a known total.
    public var progress: Double?
    /// Every account's own state, for the tooltip.
    public var tooltip: String?

    public init(state: State, glyph: Glyph, lead: String, detail: String? = nil, action: Action? = nil, isAlert: Bool = false,
                progress: Double? = nil, tooltip: String? = nil) {
        self.state = state
        self.glyph = glyph
        self.lead = lead
        self.detail = detail
        self.action = action
        self.isAlert = isAlert
        self.progress = progress
        self.tooltip = tooltip
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
                                  now: input.now, numberFormatter: numberFormatter)
        func name(_ id: AccountID) -> String {
            byID[id].map(AccountMonogram.name(for:)) ?? "an account"
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
        // 5. Slow or retrying: a network failure while others are online, or the server asked us to slow down.
        let networkFailed = statuses.filter { $0.phase == .error && isNetworkFailure($0) }
        let slow = networkFailed + statuses.filter(isRateLimited)
        if !slow.isEmpty {
            let ids = slow.map(\.accountID)
            let lead = ids.count == 1 ? "\(name(ids[0])) is slow to respond" : "\(ids.count) accounts are slow to respond"
            // The soonest retry, counted down; “shortly” while the engine has not said when.
            let soonest = slow.compactMap { retrySeconds(until: $0.retryAt, now: input.now) }.min()
            let detail = soonest.map { "retrying in \($0) s" } ?? "retrying shortly"
            return SyncLineSummary(state: .slow, glyph: .retrying, lead: lead, detail: detail, tooltip: tooltip)
        }
        // 6. Sending after the undo window.
        if input.sendingCount > 0 {
            let lead = input.sendingCount == 1 ? "Sending 1 message" : "Sending \(numberFormatter(input.sendingCount)) messages"
            return SyncLineSummary(state: .sending, glyph: .spinner, lead: lead, tooltip: tooltip)
        }
        // 7. A first download. Body downloads after it never take the line.
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
        // 9. Demo mode replaces Up to date.
        if input.isDemo {
            return SyncLineSummary(state: .demo, glyph: .info, lead: "Demo", detail: "made-up mail, nothing syncs", tooltip: tooltip)
        }
        // 10. Up to date.
        let ids = input.accounts.map(\.id)
        var parts: [String] = []
        if !ids.isEmpty { parts.append(named(ids)) }
        if let checked = statuses.compactMap(\.lastSuccessfulSyncAt).max() { parts.append("checked \(checkedFormatter(checked))") }
        return SyncLineSummary(state: .upToDate, glyph: .upToDate, lead: "Up to date",
                               detail: parts.isEmpty ? nil : parts.joined(separator: " · "), tooltip: tooltip)
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
    static func tooltipText(statuses: [AccountSyncStatus], accounts: [AccountID: Account], signIn: SignIn?, isOffline: Bool,
                            isDemo: Bool, now: Date = Date(), numberFormatter: (Int) -> String) -> String? {
        let parts = statuses.compactMap { status -> String? in
            guard let account = accounts[status.accountID] else { return nil }
            let words: String
            if case .reconnecting(let id)? = signIn, id == status.accountID {
                words = "Waiting for your browser"
            } else if isOffline, status.phase != .needsReauth, status.phase != .error || isNetworkFailure(status) {
                words = "Offline"
            } else if isDemo, status.phase == .idle || (status.phase == .paused && !isRateLimited(status)) {
                words = "Made up, nothing syncs"
            } else {
                words = accountWords(status, now: now, numberFormatter: numberFormatter)
            }
            return "\(AccountMonogram.name(for: account)): \(words)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The per-account words Settings › Accounts uses (§5.40).
    public static func accountWords(_ status: AccountSyncStatus, now: Date = Date(), numberFormatter: (Int) -> String = grouped) -> String {
        let retrying = retrySeconds(until: status.retryAt, now: now).map { "Retrying in \($0) s" } ?? "Retrying shortly"
        switch status.phase {
        case .idle: return "Up to date"
        case .bootstrapping:
            let count = status.bootstrapProgress ?? 0
            if let total = status.bootstrapTotal, total > 0 {
                return "Downloading \(numberFormatter(count)) of \(numberFormatter(max(total, count)))"
            }
            return count > 0 ? "Downloading \(numberFormatter(count)) messages" : "Downloading"
        case .hydrating: return "Downloading messages…"
        case .syncing: return "Checking for mail…"
        case .paused: return isRateLimited(status) ? retrying : "Up to date"
        case .needsReauth: return "Sign in required"
        case .error: return isNetworkFailure(status) ? retrying : "Couldn't sync"
        }
    }

    /// Whole seconds until `retryAt`, at least 1 while it is ahead; nil when unknown or past (“Retrying shortly”).
    public static func retrySeconds(until retryAt: Date?, now: Date) -> Int? {
        guard let retryAt else { return nil }
        let interval = retryAt.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        return max(1, Int(interval.rounded(.up)))
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
