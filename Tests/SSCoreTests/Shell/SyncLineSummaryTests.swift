import XCTest
@testable import SSCore

final class SyncLineSummaryTests: XCTestCase {
    private let contoso = Account(id: AccountID("c"), kind: .microsoft, email: "alex@contoso.test", displayName: "Alex",
                                  addedAt: Date(timeIntervalSince1970: 0))
    private let fabrikam = Account(id: AccountID("f"), kind: .microsoft, email: "alex@fabrikam.test", displayName: "Alex",
                                   addedAt: Date(timeIntervalSince1970: 1))
    private let gmail = Account(id: AccountID("g"), kind: .gmail, email: "alex@gmail.com", displayName: "Alex",
                                addedAt: Date(timeIntervalSince1970: 2))
    private var accounts: [Account] { [contoso, fabrikam, gmail] }

    private func status(_ account: Account, _ phase: AccountSyncPhase, message: String? = nil, progress: Int? = nil,
                        checked: Date? = nil) -> AccountSyncStatus {
        AccountSyncStatus(accountID: account.id, phase: phase, lastSuccessfulSyncAt: checked, bootstrapProgress: progress, message: message)
    }

    private func make(_ statuses: [AccountSyncStatus], accounts: [Account]? = nil, isDemo: Bool = false, reachable: Bool = true,
                      signIn: SyncLineSummary.SignIn? = nil, sending: Int = 0, checking: Bool = false) -> SyncLineSummary {
        SyncLineSummary.make(
            SyncLineSummary.Input(statuses: statuses, accounts: accounts ?? self.accounts, isDemo: isDemo, isNetworkReachable: reachable,
                                  signIn: signIn, sendingCount: sending, isChecking: checking),
            checkedFormatter: { _ in "23:41" },
            numberFormatter: { "\($0)" }
        )
    }

    // MARK: States and copy

    func testUpToDateCountsAccountsAndNamesTheCheckTime() {
        let s = make(accounts.map { status($0, .idle, checked: Date()) })
        XCTAssertEqual(s.state, .upToDate)
        XCTAssertEqual(s.lead, "Up to date")
        XCTAssertEqual(s.detail, "3 accounts · checked 23:41")
        XCTAssertNil(s.action)
    }

    func testUpToDateNamesASingleAccount() {
        let s = make([status(contoso, .idle, checked: Date())], accounts: [contoso])
        XCTAssertEqual(s.detail, "Contoso · checked 23:41")
    }

    func testDownloadingNamesOrCountsAndSums() {
        let one = make([status(contoso, .bootstrapping, progress: 3412), status(fabrikam, .idle), status(gmail, .idle)])
        XCTAssertEqual(one.state, .downloading)
        XCTAssertEqual(one.lead, "Downloading mail")
        XCTAssertEqual(one.detail, "Contoso · 3412 messages")
        let two = make([status(contoso, .bootstrapping, progress: 3000), status(fabrikam, .bootstrapping, progress: 412), status(gmail, .idle)])
        XCTAssertEqual(two.detail, "2 accounts · 3412 messages")
        let starting = make([status(contoso, .bootstrapping)], accounts: [contoso])
        XCTAssertEqual(starting.detail, "Contoso…")
    }

    func testHydrationNeverTakesTheLine() {
        XCTAssertEqual(make([status(contoso, .hydrating)], accounts: [contoso]).state, .upToDate)
    }

    func testSignInRequiredNamesOneAndCountsSeveral() {
        let one = make([status(contoso, .idle), status(fabrikam, .needsReauth), status(gmail, .idle)])
        XCTAssertEqual(one.state, .signInRequired)
        XCTAssertEqual(one.lead, "Sign in required")
        XCTAssertEqual(one.detail, "Fabrikam")
        XCTAssertEqual(one.action, .reconnect(fabrikam.id))
        XCTAssertEqual(one.action?.title, "Reconnect")
        XCTAssertTrue(one.isAlert)
        let two = make([status(contoso, .needsReauth), status(fabrikam, .needsReauth), status(gmail, .idle)])
        XCTAssertEqual(two.detail, "2 accounts")
        XCTAssertEqual(two.action, .reconnectSeveral)
        XCTAssertEqual(two.action?.title, "Reconnect…")
    }

    func testErrorRetriesEveryFailedAccount() {
        let one = make([status(contoso, .error, message: "server 500: boom"), status(fabrikam, .idle), status(gmail, .idle)])
        XCTAssertEqual(one.state, .error)
        XCTAssertEqual(one.lead, "Couldn't sync Contoso")
        XCTAssertEqual(one.action, .retry([contoso.id]))
        let two = make([status(contoso, .error, message: "decoding: x"), status(fabrikam, .error, message: "server 503: y"), status(gmail, .idle)])
        XCTAssertEqual(two.lead, "Couldn't sync 2 accounts")
        XCTAssertNil(two.detail)
        XCTAssertEqual(two.action, .retry([contoso.id, fabrikam.id]))
    }

    func testOfflineWhenNoPathOrEveryBusyAccountFailedOnTheNetwork() {
        XCTAssertEqual(make(accounts.map { status($0, .idle) }, reachable: false).state, .offline)
        let allNetwork = make([status(contoso, .error, message: "network: down"), status(fabrikam, .error, message: "network: down"),
                               status(gmail, .idle)])
        XCTAssertEqual(allNetwork.state, .offline)
        XCTAssertEqual(allNetwork.detail, "changes will sync when you're back")
    }

    func testSlowWhenOneFailsOnTheNetworkWhileOthersWork() {
        let s = make([status(contoso, .error, message: "network: timeout"), status(fabrikam, .bootstrapping, progress: 10), status(gmail, .idle)])
        XCTAssertEqual(s.state, .slow)
        XCTAssertEqual(s.lead, "Contoso is slow to respond")
        XCTAssertEqual(s.detail, "retrying shortly")
    }

    func testRateLimitedCountsAsSlow() {
        let s = make([status(gmail, .paused, message: "Rate limited; retrying shortly"), status(contoso, .paused, message: "Rate limited"),
                      status(fabrikam, .idle)])
        XCTAssertEqual(s.state, .slow)
        XCTAssertEqual(s.lead, "2 accounts are slow to respond")
    }

    func testAPlainPauseIsNotProgress() {
        XCTAssertEqual(make(accounts.map { status($0, .paused) }).state, .upToDate)
    }

    func testSendingCheckingAndDemo() {
        XCTAssertEqual(make(accounts.map { status($0, .idle) }, sending: 1).lead, "Sending 1 message")
        XCTAssertEqual(make(accounts.map { status($0, .idle) }, sending: 2).lead, "Sending 2 messages")
        XCTAssertEqual(make(accounts.map { status($0, .idle) }, checking: true).lead, "Checking for mail…")
        let demo = make(accounts.map { status($0, .idle) }, isDemo: true)
        XCTAssertEqual(demo.state, .demo)
        XCTAssertEqual(demo.lead, "Demo")
        XCTAssertEqual(demo.detail, "made-up mail, nothing syncs")
        XCTAssertEqual(demo.glyph, .info)
    }

    func testSigningInNamesTheProviderOrTheAccount() {
        let adding = make(accounts.map { status($0, .idle) }, signIn: .adding(.gmail))
        XCTAssertEqual(adding.state, .signingIn)
        XCTAssertEqual(adding.lead, "Finish signing in in your browser")
        XCTAssertEqual(adding.detail, "Gmail")
        XCTAssertEqual(adding.action, .cancelSignIn)
        let reconnecting = make([status(contoso, .idle), status(fabrikam, .needsReauth)], accounts: [contoso, fabrikam],
                                signIn: .reconnecting(fabrikam.id))
        XCTAssertEqual(reconnecting.detail, "Fabrikam")
        XCTAssertEqual(reconnecting.tooltip, "Contoso: Up to date · Fabrikam: Waiting for your browser")
    }

    // MARK: Precedence

    func testPrecedenceTopToBottom() {
        let everything: [AccountSyncStatus] = [
            status(contoso, .needsReauth), status(fabrikam, .error, message: "server 500: x"), status(gmail, .bootstrapping, progress: 5),
        ]
        XCTAssertEqual(make(everything, signIn: .adding(nil)).state, .signingIn)
        XCTAssertEqual(make(everything).state, .signInRequired)
        XCTAssertEqual(make(Array(everything.dropFirst())).state, .error)
        XCTAssertEqual(make([status(gmail, .bootstrapping, progress: 5)], reachable: false).state, .offline)
        XCTAssertEqual(make([status(gmail, .bootstrapping, progress: 5)], sending: 1).state, .sending)
        XCTAssertEqual(make([status(gmail, .bootstrapping, progress: 5)], isDemo: true, checking: true).state, .downloading)
        XCTAssertEqual(make([status(gmail, .idle)], isDemo: true, checking: true).state, .checking)
    }

    func testStatusesOfAccountsTheShellDoesNotShowAreIgnored() {
        let ghost = Account(id: AccountID("x"), kind: .gmail, email: "x@gone.test", displayName: "X", addedAt: Date(timeIntervalSince1970: 3))
        let s = make([status(ghost, .error, message: "server 500: gone"), status(contoso, .idle, checked: Date())], accounts: [contoso])
        XCTAssertEqual(s.state, .upToDate)
        XCTAssertEqual(make([status(ghost, .needsReauth)], accounts: []).state, .upToDate)
    }

    func testTooltipListsEveryAccountInSettingsWords() {
        let s = make([status(contoso, .bootstrapping, progress: 3412), status(fabrikam, .needsReauth),
                      status(gmail, .error, message: "network: x")])
        XCTAssertEqual(s.tooltip, "Contoso: Downloading 3412 messages · Fabrikam: Sign in required · Gmail: Retrying shortly")
    }

    func testTooltipSaysOfflineWhileTheLineDoes() {
        let noPath = make([status(contoso, .idle), status(fabrikam, .needsReauth), status(gmail, .error, message: "server 500: x")],
                          reachable: false)
        XCTAssertEqual(noPath.tooltip, "Contoso: Offline · Fabrikam: Sign in required · Gmail: Couldn't sync")
        let allNetwork = make([status(contoso, .error, message: "network: down"), status(gmail, .idle)], accounts: [contoso, gmail])
        XCTAssertEqual(allNetwork.state, .offline)
        XCTAssertEqual(allNetwork.tooltip, "Contoso: Offline · Gmail: Offline")
    }

    func testDemoTooltipUsesTheDemoAccountWords() {
        let demo = make([status(contoso, .idle), status(fabrikam, .bootstrapping, progress: 12)], accounts: [contoso, fabrikam],
                        isDemo: true)
        XCTAssertEqual(demo.tooltip, "Contoso: Made up, nothing syncs · Fabrikam: Downloading 12 messages")
    }
}

/// The provider's total during a first download and the engine's retry time, in the line and in Settings'
/// words (spec §5.11, §5.40).
final class SyncLineProgressTests: XCTestCase {
    private let contoso = Account(id: AccountID("c"), kind: .microsoft, email: "alex@contoso.test", displayName: "Alex",
                                  addedAt: Date(timeIntervalSince1970: 0))
    private let fabrikam = Account(id: AccountID("f"), kind: .microsoft, email: "alex@fabrikam.test", displayName: "Alex",
                                   addedAt: Date(timeIntervalSince1970: 1))
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func make(_ statuses: [AccountSyncStatus], accounts: [Account]) -> SyncLineSummary {
        SyncLineSummary.make(SyncLineSummary.Input(statuses: statuses, accounts: accounts, now: now), numberFormatter: { "\($0)" })
    }

    func testAKnownTotalCountsBothAndFillsTheContrail() {
        let s = make([AccountSyncStatus(accountID: contoso.id, phase: .bootstrapping, bootstrapProgress: 3_412, bootstrapTotal: 8_120)],
                     accounts: [contoso])
        XCTAssertEqual(s.detail, "Contoso · 3412 of 8120")
        XCTAssertEqual(s.progress ?? 0, 3_412.0 / 8_120.0, accuracy: 0.0001)
        XCTAssertEqual(SyncLineSummary.accountWords(AccountSyncStatus(accountID: contoso.id, phase: .bootstrapping, bootstrapProgress: 3,
                                                                      bootstrapTotal: 9), numberFormatter: { "\($0)" }),
                       "Downloading 3 of 9")
    }

    func testTotalsSumOnlyWhileEveryDownloadHasOne() {
        let both = make([
            AccountSyncStatus(accountID: contoso.id, phase: .bootstrapping, bootstrapProgress: 10, bootstrapTotal: 100),
            AccountSyncStatus(accountID: fabrikam.id, phase: .bootstrapping, bootstrapProgress: 5, bootstrapTotal: 50),
        ], accounts: [contoso, fabrikam])
        XCTAssertEqual(both.detail, "2 accounts · 15 of 150")
        let mixed = make([
            AccountSyncStatus(accountID: contoso.id, phase: .bootstrapping, bootstrapProgress: 10, bootstrapTotal: 100),
            AccountSyncStatus(accountID: fabrikam.id, phase: .bootstrapping, bootstrapProgress: 5),
        ], accounts: [contoso, fabrikam])
        XCTAssertEqual(mixed.detail, "2 accounts · 15 messages")
        XCTAssertNil(mixed.progress)
        // An estimate that runs short never reads “9 of 8”.
        let short = make([AccountSyncStatus(accountID: contoso.id, phase: .bootstrapping, bootstrapProgress: 9, bootstrapTotal: 8)],
                         accounts: [contoso])
        XCTAssertEqual(short.detail, "Contoso · 9 of 9")
    }

    func testARetryTimeCountsDown() {
        let network = AccountSyncStatus(accountID: contoso.id, phase: .error, message: "network: offline", retryAt: now.addingTimeInterval(29.2))
        // Another account is busy and reaching its server, so this one is slow, not offline.
        let syncing = AccountSyncStatus(accountID: fabrikam.id, phase: .syncing)
        let s = make([network, syncing], accounts: [contoso, fabrikam])
        XCTAssertEqual(s.state, .slow)
        XCTAssertEqual(s.detail, "retrying in 30 s")
        XCTAssertEqual(SyncLineSummary.accountWords(network, now: now), "Retrying in 30 s")
        XCTAssertEqual(SyncLineSummary.accountWords(network, now: now.addingTimeInterval(40)), "Retrying shortly", "past it")
        let throttled = AccountSyncStatus(accountID: contoso.id, phase: .paused, message: "Rate limited; retrying shortly")
        XCTAssertEqual(SyncLineSummary.accountWords(throttled, now: now), "Retrying shortly", "no time given")
        XCTAssertEqual(SyncLineSummary.retrySeconds(until: now.addingTimeInterval(0.2), now: now), 1)
        XCTAssertNil(SyncLineSummary.retrySeconds(until: nil, now: now))
    }
}

/// Older mail the backfill lane downloads behind the live lane (spec §5.11, §5.40): the line stays Up to date
/// and says how far it has come, or until when the provider paused it; it never reads as Downloading or Slow.
final class SyncLineOlderMailTests: XCTestCase {
    private let contoso = Account(id: AccountID("c"), kind: .microsoft, email: "alex@contoso.test", displayName: "Alex",
                                  addedAt: Date(timeIntervalSince1970: 0))
    private let fabrikam = Account(id: AccountID("f"), kind: .microsoft, email: "alex@fabrikam.test", displayName: "Alex",
                                   addedAt: Date(timeIntervalSince1970: 1))
    private let gmail = Account(id: AccountID("g"), kind: .gmail, email: "alex@gmail.com", displayName: "Alex",
                                addedAt: Date(timeIntervalSince1970: 2))
    private var accounts: [Account] { [contoso, fabrikam, gmail] }
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let checked = Date(timeIntervalSince1970: 1_789_999_000)

    /// Times read as seconds from `now`, so “paused until” shows which resume time won.
    private func time(_ date: Date) -> String {
        date == checked ? "23:41" : "t+\(Int(date.timeIntervalSince(now)))"
    }

    private func older(_ account: Account, _ phase: AccountSyncPhase = .idle, done: Int?, total: Int? = nil,
                       pausedFor seconds: TimeInterval? = nil, message: String? = nil) -> AccountSyncStatus {
        AccountSyncStatus(accountID: account.id, phase: phase, lastSuccessfulSyncAt: checked, message: message, backfillProgress: done,
                          backfillTotal: total, backfillPausedUntil: seconds.map { now.addingTimeInterval($0) })
    }

    private func idle(_ account: Account) -> AccountSyncStatus {
        AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: checked)
    }

    private func make(_ statuses: [AccountSyncStatus], accounts: [Account]? = nil, sending: Int = 0, checking: Bool = false,
                      isDemo: Bool = false) -> SyncLineSummary {
        SyncLineSummary.make(
            SyncLineSummary.Input(statuses: statuses, accounts: accounts ?? self.accounts, isDemo: isDemo, sendingCount: sending,
                                  isChecking: checking, now: now),
            checkedFormatter: time, numberFormatter: { "\($0)" })
    }

    private func words(_ status: AccountSyncStatus) -> String {
        SyncLineSummary.accountWords(status, now: now, numberFormatter: { "\($0)" }, timeFormatter: time)
    }

    // MARK: The line

    func testOneAccountWithAKnownTotalIsUpToDateAndFillsTheContrail() {
        let s = make([older(contoso, done: 3_412, total: 8_120)], accounts: [contoso])
        XCTAssertEqual(s.state, .upToDate)
        XCTAssertEqual(s.glyph, .upToDate)
        XCTAssertEqual(s.lead, "Up to date")
        XCTAssertEqual(s.detail, "Contoso · older mail 3412 of 8120", "the check time leaves the line")
        XCTAssertEqual(s.progress ?? 0, 3_412.0 / 8_120.0, accuracy: 0.0001)
        XCTAssertNil(s.action)
        XCTAssertFalse(s.isAlert)
    }

    func testSeveralAccountsAreCountedAndTheirFiguresSummed() {
        let s = make([older(contoso, done: 3_000, total: 7_000), idle(fabrikam), older(gmail, done: 412, total: 1_120)])
        XCTAssertEqual(s.detail, "3 accounts · older mail 3412 of 8120", "named as Up to date names every shown account")
        XCTAssertEqual(s.progress ?? 0, 3_412.0 / 8_120.0, accuracy: 0.0001)
    }

    func testAnUnknownTotalCountsOnlyAndLeavesTheContrailOut() {
        let one = make([older(contoso, done: 3_412)], accounts: [contoso])
        XCTAssertEqual(one.detail, "Contoso · older mail 3412")
        XCTAssertNil(one.progress)
        let mixed = make([older(contoso, done: 3_000, total: 7_000), idle(fabrikam), older(gmail, done: 412)])
        XCTAssertEqual(mixed.detail, "3 accounts · older mail 3412", "every total must be known")
        XCTAssertNil(mixed.progress)
        let starting = make([older(contoso, done: 0)], accounts: [contoso])
        XCTAssertEqual(starting.detail, "Contoso · older mail…")
    }

    func testAShortEstimateNeverReadsAsMoreDoneThanThereIs() {
        let s = make([older(contoso, done: 9, total: 8)], accounts: [contoso])
        XCTAssertEqual(s.detail, "Contoso · older mail 9 of 9")
    }

    func testEveryAccountPausedNamesTheSoonestResume() {
        let one = make([older(contoso, done: 3_412, total: 8_120, pausedFor: 600)], accounts: [contoso])
        XCTAssertEqual(one.state, .upToDate)
        XCTAssertEqual(one.glyph, .upToDate)
        XCTAssertEqual(one.detail, "Contoso · older mail paused until t+600")
        XCTAssertNil(one.progress, "nothing moves while paused")
        let two = make([older(contoso, done: 3_000, pausedFor: 600), idle(fabrikam), older(gmail, done: 412, pausedFor: 300)])
        XCTAssertEqual(two.detail, "3 accounts · older mail paused until t+300")
    }

    func testOnePausedAndOneRunningShowsTheSummedProgress() {
        let s = make([older(contoso, done: 3_000, total: 7_000, pausedFor: 600), idle(fabrikam), older(gmail, done: 412, total: 1_120)])
        XCTAssertEqual(s.detail, "3 accounts · older mail 3412 of 8120", "the paused account's figures stay in, so nothing jumps")
        XCTAssertNotNil(s.progress)
    }

    func testAResumeTimeThatHasPassedReadsAsRunning() {
        let s = make([older(contoso, done: 10, pausedFor: -5)], accounts: [contoso])
        XCTAssertEqual(s.detail, "Contoso · older mail 10")
        let gone = make([older(contoso, done: nil, pausedFor: -5)], accounts: [contoso])
        XCTAssertEqual(gone.detail, "Contoso · checked 23:41", "no backfill left to report")
    }

    func testWithoutOlderMailTheCheckTimeReturns() {
        XCTAssertEqual(make([idle(contoso)], accounts: [contoso]).detail, "Contoso · checked 23:41")
    }

    func testTheCheckTimeMovesToTheTooltip() {
        let s = make([older(contoso, done: 3_412, total: 8_120), idle(gmail)], accounts: [contoso, gmail])
        XCTAssertEqual(s.tooltip, "Contoso: Up to date · older mail 3412 of 8120 · Gmail: Up to date\nChecked 23:41")
        XCTAssertEqual(make([idle(contoso)], accounts: [contoso]).tooltip, "Contoso: Up to date", "unchanged without older mail")
    }

    func testBackgroundChecksAndBodyDownloadsKeepTheOlderMailLine() {
        let s = make([older(contoso, .syncing, done: 5, total: 10), older(gmail, .hydrating, done: 5, total: 10)],
                     accounts: [contoso, gmail])
        XCTAssertEqual(s.state, .upToDate)
        XCTAssertEqual(s.detail, "2 accounts · older mail 10 of 20")
    }

    /// The live lane checks every 5 s while the app is frontmost; the tooltip must not flip with each check while
    /// the line and Settings stay Up to date.
    func testTheTooltipReadsABackgroundCheckAsSettingsDoes() {
        let polling = older(contoso, .syncing, done: 3_412, total: 8_120)
        XCTAssertEqual(make([polling], accounts: [contoso]).tooltip, "Contoso: Up to date · older mail 3412 of 8120\nChecked 23:41")
        let plain = AccountSyncStatus(accountID: contoso.id, phase: .syncing, lastSuccessfulSyncAt: checked)
        XCTAssertEqual(make([plain], accounts: [contoso]).tooltip, "Contoso: Up to date", "without older mail too")
        XCTAssertEqual(make([polling], accounts: [contoso], checking: true).tooltip, "Contoso: Checking for mail…",
                       "a check the user asked for says so")
        let neverSynced = AccountSyncStatus(accountID: contoso.id, phase: .syncing)
        XCTAssertEqual(make([neverSynced], accounts: [contoso]).tooltip, "Contoso: Checking for mail…", "nothing to be up to date with yet")
        XCTAssertEqual(make([polling], accounts: [contoso], isDemo: true).tooltip, "Contoso: Made up, nothing syncs")
    }

    // MARK: Precedence

    func testTheFirstPageStillReadsAsDownloading() {
        let head = AccountSyncStatus(accountID: contoso.id, phase: .bootstrapping, bootstrapProgress: 200)
        let s = make([head, idle(fabrikam), older(gmail, done: 3_412, total: 8_120)])
        XCTAssertEqual(s.state, .downloading)
        XCTAssertEqual(s.lead, "Downloading mail")
        XCTAssertEqual(s.detail, "Contoso · 200 messages", "only the account fetching its first page counts")
    }

    func testTheLiveLanesRateLimitIsStillSlow() {
        let throttled = AccountSyncStatus(accountID: gmail.id, phase: .paused, message: "Rate limited; retrying shortly")
        let s = make([older(contoso, done: 3_412, total: 8_120), idle(fabrikam), throttled])
        XCTAssertEqual(s.state, .slow)
        XCTAssertEqual(s.lead, "Gmail is slow to respond")
    }

    func testAThrottledBackfillIsNeverSlow() {
        let s = make([older(contoso, done: 3_412, pausedFor: 60), older(fabrikam, done: 1, pausedFor: 30), older(gmail, done: 2, pausedFor: 90)])
        XCTAssertEqual(s.state, .upToDate)
        XCTAssertEqual(s.glyph, .upToDate)
    }

    func testHigherRulesStillWin() {
        let backfilling = [older(contoso, done: 3_412, total: 8_120), idle(fabrikam), idle(gmail)]
        XCTAssertEqual(make(backfilling, sending: 1).state, .sending)
        XCTAssertEqual(make(backfilling, checking: true).state, .checking)
        XCTAssertEqual(make(backfilling, isDemo: true).state, .demo)
        let reauth = AccountSyncStatus(accountID: fabrikam.id, phase: .needsReauth)
        XCTAssertEqual(make([older(contoso, done: 1, total: 2), reauth, idle(gmail)]).state, .signInRequired)
    }

    // MARK: Account words

    func testAccountWordsCarryTheOlderMail() {
        XCTAssertEqual(words(older(contoso, done: 3_412, total: 8_120)), "Up to date · older mail 3412 of 8120")
        XCTAssertEqual(words(older(contoso, done: 3_412)), "Up to date · older mail 3412")
        XCTAssertEqual(words(older(contoso, done: 3_412, total: 8_120, pausedFor: 600)), "Up to date · older mail paused until t+600")
        XCTAssertEqual(words(older(contoso, .paused, done: 3_412)), "Up to date · older mail 3412", "a plain pause")
        XCTAssertEqual(words(idle(contoso)), "Up to date")
    }

    /// Once the older mail is listed, its bodies still arriving show in Settings and the tooltip, never on the line.
    func testBodiesStillArrivingShowInTheAccountWordsOnly() {
        let bodies = AccountSyncStatus(accountID: contoso.id, phase: .idle, lastSuccessfulSyncAt: checked, backfillDownloadingBodies: true)
        XCTAssertEqual(words(bodies), "Up to date · downloading messages…")
        var listing = older(contoso, done: 3_412, total: 8_120)
        listing.backfillDownloadingBodies = true
        XCTAssertEqual(words(listing), "Up to date · older mail 3412 of 8120", "the listing's count comes first")
        let s = make([bodies], accounts: [contoso])
        XCTAssertEqual(s.state, .upToDate)
        XCTAssertEqual(s.detail, "Contoso · checked 23:41", "body downloads never take the line (rule 7)")
        XCTAssertEqual(s.tooltip, "Contoso: Up to date · downloading messages…")
    }

    /// After the listing, the backfill lane still fetches bodies, and a throttle there pauses it too. That is no
    /// older mail: it neither takes the line nor hides another account's listing total and contrail.
    func testABodyDownloadPauseIsNoOlderMail() {
        let bodiesPaused = older(fabrikam, done: nil, pausedFor: 600)
        XCTAssertEqual(make([bodiesPaused], accounts: [fabrikam]).detail, "Fabrikam · checked 23:41")
        XCTAssertEqual(words(bodiesPaused), "Up to date")
        var downloading = bodiesPaused
        downloading.backfillDownloadingBodies = true
        XCTAssertEqual(words(downloading), "Up to date · downloading messages…")
        let beside = make([older(contoso, done: 3_412, total: 8_120), bodiesPaused], accounts: [contoso, fabrikam])
        XCTAssertEqual(beside.detail, "2 accounts · older mail 3412 of 8120")
        XCTAssertEqual(beside.progress ?? 0, 3_412.0 / 8_120.0, accuracy: 0.0001)
    }

    func testOtherPhasesKeepTheirWords() {
        XCTAssertEqual(words(older(contoso, .syncing, done: 3_412)), "Checking for mail…")
        XCTAssertEqual(words(older(contoso, .hydrating, done: 3_412)), "Downloading messages…")
        XCTAssertEqual(words(older(contoso, .paused, done: 3_412, message: "Rate limited")), "Retrying shortly")
        XCTAssertEqual(words(older(contoso, .error, done: 3_412, message: "server 500: x")), "Couldn't sync")
    }

    func testTheFractionIsForARunningDownloadWithATotal() {
        XCTAssertEqual(SyncLineSummary.olderMailFraction(older(contoso, done: 1, total: 4), now: now) ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertNil(SyncLineSummary.olderMailFraction(older(contoso, done: 1), now: now))
        XCTAssertNil(SyncLineSummary.olderMailFraction(older(contoso, done: 1, total: 4, pausedFor: 60), now: now))
        XCTAssertNil(SyncLineSummary.olderMailFraction(idle(contoso), now: now))
    }
}
