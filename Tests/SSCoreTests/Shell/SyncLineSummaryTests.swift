import XCTest
@testable import SSCore

final class SyncLineSummaryTests: XCTestCase {
    private let contoso = Account(id: AccountID("c"), kind: .microsoft, email: "alex@contoso.test", displayName: "Alex",
                                  colorHex: "#000000", addedAt: Date(timeIntervalSince1970: 0))
    private let fabrikam = Account(id: AccountID("f"), kind: .microsoft, email: "alex@fabrikam.test", displayName: "Alex",
                                   colorHex: "#000000", addedAt: Date(timeIntervalSince1970: 1))
    private let gmail = Account(id: AccountID("g"), kind: .gmail, email: "alex@gmail.com", displayName: "Alex",
                                colorHex: "#000000", addedAt: Date(timeIntervalSince1970: 2))
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

    func testTooltipListsEveryAccountInSettingsWords() {
        let s = make([status(contoso, .bootstrapping, progress: 3412), status(fabrikam, .needsReauth),
                      status(gmail, .error, message: "network: x")])
        XCTAssertEqual(s.tooltip, "Contoso: Downloading 3412 messages · Fabrikam: Sign in required · Gmail: Retrying shortly")
    }
}
