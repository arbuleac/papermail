import AppKit
import PaperCore
import PaperDesign
import SwiftUI

/// What the Settings window shows and does (spec §5.40). The app delegate supplies the account actions, since
/// sign-in and removal go through the engine and may show alerts; colour, monogram and signature write the store.
@MainActor
final class SettingsModel: ObservableObject {
    enum Tab: Hashable {
        case accounts
        case oauth
        case general
        case appearance
        /// Help Me Write's provider, key or CLI, model and permission (§5.40, §5.56).
        case ai
        /// Features still taking shape, each off until turned on (§5.58).
        case experimental
    }

    /// A failure at the top of Accounts. Info notices (demo, seven accounts) come from state, not from here.
    enum AccountsNotice: Equatable {
        case addFailed(kind: ProviderKind, reason: String)
    }

    /// The banner at the top of OAuth: info when an add found no client, danger for failures.
    enum OAuthNotice: Equatable {
        case needsClient(ProviderKind)
        case unreadable(reason: String)
        case saveFailed(reason: String)
    }

    @Published var tab: Tab = .accounts {
        didSet {
            // The incoming notice stays until Save succeeds or the tab is left.
            if oldValue == .oauth, tab != .oauth, case .needsClient = oauthNotice { oauthNotice = nil }
            // The face picker is a card over Accounts: the tab's toolbar is outside its click-catching layer, so leaving
            // the tab must close it, or it would be open again over Accounts on the way back (Quire §5.55).
            if tab != oldValue { showsFacePicker = false }
        }
    }

    @Published private(set) var accounts: [Account] = []
    @Published var statuses: [AccountID: AccountSyncStatus] = [:] {
        didSet { updateRetryClock() }
    }
    /// The moment “Retrying in 30 s” counts from; ticks once a second while the window shows that count.
    @Published private(set) var now = Date()
    private var retryClock: Timer?
    /// The window is open; set by its controller. A closed window keeps its model (and the status observation
    /// feeding it), so without this the clock would tick for rows nobody sees.
    var isWindowOpen = false {
        didSet {
            if isWindowOpen != oldValue { updateRetryClock() }
            // The model outlives the window: a card left open would show again, without focus, when Settings next opens.
            if !isWindowOpen { showsFacePicker = false }
        }
    }
    /// The selected account's id (`AccountID.rawValue`). Another account's selection closes the face picker: it was this one's.
    @Published var selection: String? {
        didSet { if selection != oldValue { showsFacePicker = false } }
    }
    /// The selected account's face picker is open over Accounts (Quire §5.55). Selecting another account, leaving the
    /// Accounts tab and closing the window all close it.
    @Published var showsFacePicker = false
    /// A sign-in adding an account is waiting for the browser (the pending row).
    @Published var pendingSignIn: ProviderKind?
    /// A reconnect is waiting for the browser.
    @Published var reconnecting: AccountID?
    /// Accounts whose check the user asked for (a reconnect, Check for New Mail): their sync shows as
    /// “Checking for mail…” until it lands. Background polls never change a row.
    @Published var userChecks: Set<AccountID> = []
    @Published var accountsNotice: AccountsNotice?

    @Published var oauth = OAuthClientFile() {
        didSet { if oauth != oldValue { oauthSaved = false } }
    }
    @Published private(set) var savedOAuth = OAuthClientFile()
    @Published var oauthNotice: OAuthNotice?
    @Published private(set) var oauthSaved = false
    @Published private(set) var oauthFileExists = false

    let isDemo: Bool
    let oauthFileURL: URL

    var addAccount: (ProviderKind) -> Void = { _ in }
    var cancelSignIn: () -> Void = {}
    var removeAccount: (Account) -> Void = { _ in }
    var reconnect: (Account) -> Void = { _ in }
    var retry: (Account) -> Void = { _ in }
    var leaveDemo: () -> Void = {}
    var setInkSlot: (Int, Account) -> Void = { _, _ in }
    var setMonogram: (String?, Account) -> Void = { _, _ in }
    /// The face picked in the account's face picker (Quire §5.55).
    var setFace: (AccountFace, Account) -> Void = { _, _ in }
    /// The signature's HTML (nil for none) for an account, when editing it ends. By id: the field saves for the account
    /// it was editing, which may no longer be the selected one.
    var setSignature: (String?, AccountID) -> Void = { _, _ in }
    /// Every sender rule, as the store's observation last delivered them: the server's rules as the store mirrors them,
    /// and the changes on their way there (spec §5.52).
    @Published private(set) var senderRules: [SenderRule] = []
    /// The Senders sheet's −: the rule is deleted on the server (one never saved there just goes), and the mail it moved
    /// stays where it is.
    var removeSenderRule: (SenderRule) -> Void = { _ in }
    /// Allow… in Senders, and the row's Reconnect while sender rules wait: the sign-in asking for the permission to save
    /// rules on the server.
    var connectRules: (Account) -> Void = { _ in }
    /// Senders opening: the engine reads the account's rules from the server now rather than at its own interval.
    var refreshServerRules: (Account) -> Void = { _ in }
    /// The Senders foot's link: the provider's own page of rules, in the browser. Tests replace it, so none opens one.
    var openWebSettings: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(isDemo: Bool, oauthFileURL: URL) {
        self.isDemo = isDemo
        self.oauthFileURL = oauthFileURL
        reloadOAuth()
    }

    // MARK: Accounts

    func setAccounts(_ fresh: [Account]) {
        if fresh != accounts {
            accounts = fresh
            updateRetryClock()
        }
        if selection == nil || !fresh.contains(where: { $0.id.rawValue == selection }) {
            selection = fresh.first?.id.rawValue
        }
        userChecks.formIntersection(fresh.map(\.id))
    }

    var selectedAccount: Account? {
        accounts.first { $0.id.rawValue == selection }
    }

    func setSenderRules(_ fresh: [SenderRule]) {
        if fresh != senderRules { senderRules = fresh }
    }

    /// The account's rules, by address, as the Senders sheet lists them.
    func senderRules(for account: Account) -> [SenderRule] {
        senderRules.filter { $0.accountID == account.id }
    }

    /// What the Senders sheet shows for `account` now.
    func sendersContent(for account: Account) -> SendersSheetContent {
        SendersSheetContent(account: account, rules: senderRules, status: statuses[account.id], isReconnecting: reconnecting == account.id,
                            isDemo: isDemo)
    }

    /// Rules kept on this Mac from before 1.14 wait for the permission to save rules on the server, which the account has
    /// not granted (the account's row asks for it, as it asks for the calendar's). A rule set since never waits: it is set
    /// only with the permission.
    func senderRulesNeedPermission(_ account: Account) -> Bool {
        statuses[account.id]?.rules == .notConnected && senderRules(for: account).contains { $0.isPending }
    }

    /// One sign-in at a time (§5.44): while one runs, + and every other Reconnect and Retry are disabled.
    var isSigningIn: Bool { pendingSignIn != nil || reconnecting != nil }

    var rows: [QuireAccountRowContent] {
        let monograms = AccountLabels.monograms(for: accounts)
        return accounts.map { account in
            let monogram = monograms[account.id] ?? "?"
            return QuireAccountRowContent(id: account.id.rawValue, name: AccountLabels.name(for: account), tag: tag(for: account),
                                          address: account.email, monogram: monogram, inkSlot: account.inkSlot,
                                          status: status(for: account), face: AccountFaces.face(for: account, monogram: monogram))
        }
    }

    /// The account's monogram among the accounts (the Monogram tile's letters) and the face it wears now.
    func face(for account: Account) -> (monogram: String, face: QuireAccountFace) {
        let monogram = AccountLabels.monogram(for: account, among: accounts)
        return (monogram, AccountFaces.face(for: account, monogram: monogram))
    }

    func account(for row: QuireAccountRowContent) -> Account? {
        accounts.first { $0.id.rawValue == row.id }
    }

    func derivedMonogram(for account: Account) -> String {
        AccountLabels.derivedMonogram(for: account, among: accounts)
    }

    private func tag(for account: Account) -> String {
        if isDemo { return "Demo" }
        return account.kind == .gmail ? "Gmail" : "Microsoft 365"
    }

    /// The status block for an account phase: the same words as the sync line's tooltip (§5.11, §5.40).
    func status(for account: Account) -> QuireAccountStatus {
        if reconnecting == account.id { return .reconnecting }
        if isDemo { return .demo }
        guard let status = statuses[account.id] else { return .waitingToSync }
        let service = ErrorText.service(account.kind)
        switch status.phase {
        case .idle:
            return permissionStatus(for: account, status) ?? upToDate(status, service: service)
        case .bootstrapping:
            // The provider's figure is an estimate; the count never runs past it.
            let done = status.bootstrapProgress ?? 0
            return .downloading(done: done, total: status.bootstrapTotal.map { max($0, done) })
        case .syncing:
            if userChecks.contains(account.id) { return .checking }
            if status.lastSuccessfulSyncAt == nil { return .waitingToSync }
            return permissionStatus(for: account, status) ?? upToDate(status, service: service)
        case .hydrating:
            return .downloadingMessages
        case .paused:
            guard let cause = retryCause(status, service: service) else { return .waitingToSync }
            return .retrying(inSeconds: SyncLineSummary.retrySeconds(until: status.retryAt, now: now), cause: cause)
        case .needsReauth:
            return .signInRequired
        case .error:
            guard ErrorText.isNetwork(status.message) else {
                return .error(reason: ErrorText.sync(status.message, kind: account.kind))
            }
            guard let cause = retryCause(status, service: service) else { return .offline }
            return .retrying(inSeconds: SyncLineSummary.retrySeconds(until: status.retryAt, now: now), cause: cause)
        }
    }

    /// Mail is current, but something set on this Mac waits for a permission the account has not granted: an answered
    /// invitation for the calendar's (its outbox waits on it, so it comes first), or rules kept on this Mac from before
    /// 1.14 for the rules'. Nil while nothing waits.
    private func permissionStatus(for account: Account, _ status: AccountSyncStatus) -> QuireAccountStatus? {
        if !status.permissionsNeeded.isEmpty { return .calendarPermission }
        guard senderRulesNeedPermission(account) else { return nil }
        return .senderRulesPermission(rules: "\(SenderRuleCopy.service(account.kind)) \(SenderRuleCopy.rules(account.kind))")
    }

    /// Why the account waits to try again, when its row reads Retrying: a throttle, or a network failure while
    /// another account gets through. Nil for every other row.
    private func retryCause(_ status: AccountSyncStatus, service: String) -> String? {
        switch status.phase {
        case .paused:
            // The engine pauses every account when it stops (no message); only a throttle carries one.
            return status.message == nil ? nil : "\(service) is limiting requests."
        case .error:
            guard ErrorText.isNetwork(status.message) else { return nil }
            // Offline when every account that is not idle failed on the network; otherwise this one retries.
            let busy = statuses.values.filter { $0.phase != .idle }
            if busy.allSatisfy({ $0.phase == .error && ErrorText.isNetwork($0.message) }) { return nil }
            return "Couldn't reach \(service)."
        default:
            return nil
        }
    }

    /// Some row counts its retry down (“Retrying in 30 s”); the guards are `status(for:)`'s earlier cases, which
    /// show something else. A retry ahead behind Offline or Couldn't sync shows no count, and during an outage one
    /// is ahead almost all the time.
    private var showsCountdown: Bool {
        guard !isDemo else { return false }
        return accounts.contains { account in
            guard reconnecting != account.id, let status = statuses[account.id],
                  SyncLineSummary.retrySeconds(until: status.retryAt, now: now) != nil else { return false }
            return retryCause(status, service: ErrorText.service(account.kind)) != nil
        }
    }

    /// Up to date, carrying the older mail the backfill downloads behind it (§5.40): the tooltip's words and,
    /// while the total is known, the Downloading row's bar. A throttle holds back only the older mail, so it is
    /// named in the tooltip rather than shown as Retrying.
    private func upToDate(_ status: AccountSyncStatus, service: String) -> QuireAccountStatus {
        var block = QuireAccountStatus.upToDate(checked: status.lastSuccessfulSyncAt.map { $0.formatted(date: .omitted, time: .shortened) })
        guard let older = SyncLineSummary.olderMailWords(status, now: now) else {
            // The listing is done and the bodies of that mail are still arriving; new mail is current all the same.
            if status.backfillDownloadingBodies { block.words = "Up to date · downloading messages…" }
            return block
        }
        block.words = "Up to date · \(older)"
        block.progress = SyncLineSummary.olderMailFraction(status, now: now)
        if let pausedUntil = status.backfillPausedUntil, pausedUntil > now {
            block.tooltip = [block.tooltip, "\(service) is limiting requests."].compactMap { $0 }.joined(separator: "\n")
        }
        return block
    }

    /// Runs a one-second clock while the open window counts a retry down, so “Retrying in 30 s” moves.
    private func updateRetryClock() {
        now = Date()
        let waiting = isWindowOpen && showsCountdown
        if waiting, retryClock == nil {
            // A replaced model must not leave its clock ticking for ever: with the model gone the timer ends itself.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    self.tickRetryClock()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            retryClock = timer
        } else if !waiting {
            retryClock?.invalidate()
            retryClock = nil
        }
    }

    /// Stops the clock now (the Settings window is being torn down).
    func stopRetryClock() {
        retryClock?.invalidate()
        retryClock = nil
    }

    private func tickRetryClock() {
        now = Date()
        if !isWindowOpen || !showsCountdown {
            retryClock?.invalidate()
            retryClock = nil
        }
    }

    /// Internal so tests check when the clock runs.
    var isRetryClockRunning: Bool { retryClock != nil }

    /// The account detail's Last error, only when there is one.
    func lastError(for account: Account) -> String? {
        guard !isDemo, let status = statuses[account.id], status.phase == .error, !ErrorText.isNetwork(status.message) else { return nil }
        return ErrorText.sync(status.message, kind: account.kind)
    }

    /// The row's status button: Reconnect, Cancel (a reconnect waiting for the browser) or Retry.
    func performRowAction(_ row: QuireAccountRowContent) {
        guard let account = account(for: row) else { return }
        if reconnecting == account.id {
            cancelSignIn()
            return
        }
        switch statuses[account.id]?.phase {
        case .needsReauth?: reconnect(account)
        case .error?: retry(account)
        case .idle?, .syncing?:
            // Calendar permission needed: the reconnect asks for it on top of mail (and for the rules', should they wait too).
            if statuses[account.id]?.permissionsNeeded.isEmpty == false {
                reconnect(account)
            } else if senderRulesNeedPermission(account) {
                // Sender rules need permission: the same reconnect, which reads the rules once they may be saved.
                connectRules(account)
            }
        default: break
        }
    }

    func isRowActionEnabled(_ row: QuireAccountRowContent) -> Bool {
        !isSigningIn || reconnecting?.rawValue == row.id
    }

    // MARK: OAuth

    var oauthChanged: Bool { oauth != savedOAuth }

    /// Reads the file again. A file that exists but cannot be read opens the tab with the danger notice,
    /// which stays until a save succeeds.
    func reloadOAuth() {
        oauthFileExists = FileManager.default.fileExists(atPath: oauthFileURL.path)
        do {
            savedOAuth = try OAuthClientFile.read(from: oauthFileURL)
            if case .unreadable = oauthNotice { oauthNotice = nil }
        } catch {
            savedOAuth = OAuthClientFile()
            oauthNotice = .unreadable(reason: ErrorText.oauthFile(error))
        }
        oauth = savedOAuth
        oauthSaved = false
    }

    func saveOAuth() {
        do {
            try oauth.save(to: oauthFileURL)
            savedOAuth = oauth
            oauthSaved = true
            oauthNotice = nil
            oauthFileExists = true
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Saved", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        } catch {
            oauthSaved = false
            oauthNotice = .saveFailed(reason: AppAlert.sentence(error.localizedDescription))
        }
    }

    /// `--snapshot-settings-states` only: shows “Saved” beside Save without writing the user's file.
    func showSavedForSnapshot() {
        oauthSaved = true
    }

    static func googleClientIDError(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return "That doesn't look like a Google client ID."
    }

    static func microsoftClientIDError(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, UUID(uuidString: trimmed) == nil else { return nil }
        return "That doesn't look like a Microsoft client ID."
    }
}
