import AppKit
import SSCore
import SSDesign
import SwiftUI

/// What the Settings window shows and does (spec §5.40). The app delegate supplies the account actions, since
/// sign-in and removal go through the engine and may show alerts; colour and monogram write the store.
@MainActor
final class SettingsModel: ObservableObject {
    enum Tab: Hashable {
        case accounts
        case oauth
        case general
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
        }
    }

    @Published private(set) var accounts: [Account] = []
    @Published var statuses: [AccountID: AccountSyncStatus] = [:] {
        didSet { updateRetryClock() }
    }
    /// The moment “Retrying in 30 s” counts from; ticks once a second while an account waits to retry.
    @Published private(set) var now = Date()
    private var retryClock: Timer?
    /// The selected account's id (`AccountID.rawValue`).
    @Published var selection: String?
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

    init(isDemo: Bool, oauthFileURL: URL) {
        self.isDemo = isDemo
        self.oauthFileURL = oauthFileURL
        reloadOAuth()
    }

    // MARK: Accounts

    func setAccounts(_ fresh: [Account]) {
        if fresh != accounts { accounts = fresh }
        if selection == nil || !fresh.contains(where: { $0.id.rawValue == selection }) {
            selection = fresh.first?.id.rawValue
        }
        userChecks.formIntersection(fresh.map(\.id))
    }

    var selectedAccount: Account? {
        accounts.first { $0.id.rawValue == selection }
    }

    /// One sign-in at a time (§5.44): while one runs, + and every other Reconnect and Retry are disabled.
    var isSigningIn: Bool { pendingSignIn != nil || reconnecting != nil }

    var rows: [QuireAccountRowContent] {
        let monograms = AccountLabels.monograms(for: accounts)
        return accounts.map { account in
            QuireAccountRowContent(id: account.id.rawValue, name: AccountLabels.name(for: account), tag: tag(for: account),
                                   address: account.email, monogram: monograms[account.id] ?? "?", inkSlot: account.inkSlot,
                                   status: status(for: account))
        }
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
            return .upToDate(checked: status.lastSuccessfulSyncAt.map { $0.formatted(date: .omitted, time: .shortened) })
        case .bootstrapping:
            // The provider's figure is an estimate; the count never runs past it.
            let done = status.bootstrapProgress ?? 0
            return .downloading(done: done, total: status.bootstrapTotal.map { max($0, done) })
        case .syncing:
            if userChecks.contains(account.id) { return .checking }
            if status.lastSuccessfulSyncAt == nil { return .waitingToSync }
            return .upToDate(checked: status.lastSuccessfulSyncAt.map { $0.formatted(date: .omitted, time: .shortened) })
        case .hydrating:
            return .downloadingMessages
        case .paused:
            // The engine pauses every account when it stops (no message); only a throttle carries one.
            guard status.message != nil else { return .waitingToSync }
            return .retrying(inSeconds: SyncLineSummary.retrySeconds(until: status.retryAt, now: now), cause: "\(service) is limiting requests.")
        case .needsReauth:
            return .signInRequired
        case .error:
            guard ErrorText.isNetwork(status.message) else {
                return .error(reason: ErrorText.sync(status.message, kind: account.kind))
            }
            // Offline when every account that is not idle failed on the network; otherwise this one retries.
            let busy = statuses.values.filter { $0.phase != .idle }
            if busy.allSatisfy({ $0.phase == .error && ErrorText.isNetwork($0.message) }) { return .offline }
            return .retrying(inSeconds: SyncLineSummary.retrySeconds(until: status.retryAt, now: now), cause: "Couldn't reach \(service).")
        }
    }

    /// Runs a one-second clock while any account has a retry ahead, so “Retrying in 30 s” counts down.
    private func updateRetryClock() {
        now = Date()
        let waiting = statuses.values.contains { ($0.retryAt ?? .distantPast) > now }
        if waiting, retryClock == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickRetryClock() }
            }
            RunLoop.main.add(timer, forMode: .common)
            retryClock = timer
        } else if !waiting {
            retryClock?.invalidate()
            retryClock = nil
        }
    }

    private func tickRetryClock() {
        now = Date()
        if !statuses.values.contains(where: { ($0.retryAt ?? .distantPast) > now }) {
            retryClock?.invalidate()
            retryClock = nil
        }
    }

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
