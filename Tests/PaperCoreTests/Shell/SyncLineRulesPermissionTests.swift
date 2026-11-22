import XCTest
@testable import PaperCore

/// The sync line's “Sender rules need permission” (spec §5.11 rule 9, §5.52): sender rules set or removed on this Mac
/// (an existing user's rules, uploaded once, among them) act nowhere until the account grants the rules permission, so
/// the line asks, with Reconnect running the sign-in that grants it; Settings' line alone is too far out of sight.
final class SyncLineRulesPermissionTests: XCTestCase {
    private let contoso = Account(id: AccountID("c"), kind: .microsoft, email: "alex@contoso.test", displayName: "Alex",
                                  addedAt: Date(timeIntervalSince1970: 0))
    private let gmail = Account(id: AccountID("g"), kind: .gmail, email: "alex@gmail.com", displayName: "Alex",
                                addedAt: Date(timeIntervalSince1970: 1))
    private var accounts: [Account] { [contoso, gmail] }

    private func idle(_ account: Account, rules: RulesSyncState = .upToDate(otherCount: 0, readAt: Date())) -> AccountSyncStatus {
        AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: Date(), rules: rules)
    }

    private func make(_ statuses: [AccountSyncStatus], waiting: Set<AccountID>, isDemo: Bool = false, sending: Int = 0,
                      checking: Bool = false, signIn: SyncLineSummary.SignIn? = nil) -> SyncLineSummary {
        SyncLineSummary.make(
            SyncLineSummary.Input(statuses: statuses, accounts: accounts, isDemo: isDemo, signIn: signIn, sendingCount: sending,
                                  isChecking: checking, rulesWaiting: waiting),
            checkedFormatter: { _ in "23:41" },
            numberFormatter: { "\($0)" }
        )
    }

    func testOneAccountsWaitingRulesAskToReconnect() {
        let s = make([idle(contoso), idle(gmail, rules: .notConnected)], waiting: [gmail.id])
        XCTAssertEqual(s.state, .rulesPermission)
        XCTAssertEqual(s.lead, "Sender rules need permission")
        XCTAssertEqual(s.detail, "Gmail")
        XCTAssertEqual(s.action, .connectRules(gmail.id))
        XCTAssertEqual(s.action?.title, "Reconnect")
        XCTAssertEqual(s.glyph, .info)
        XCTAssertFalse(s.isAlert, "mail still syncs")
        XCTAssertEqual(s.spokenText, "Sender rules need permission, Gmail")
        XCTAssertEqual(s.tooltip, "Contoso: Up to date · Gmail: Sender rules need permission")
    }

    func testSeveralAreCountedAndSentToSettings() {
        let s = make([idle(contoso, rules: .notConnected), idle(gmail, rules: .notConnected)], waiting: [contoso.id, gmail.id])
        XCTAssertEqual(s.detail, "2 accounts")
        XCTAssertEqual(s.action, .reconnectSeveral, "each row in Settings › Accounts has its own Reconnect")
    }

    /// Nothing waiting, or the permission there (the rules go out on their own), or not known yet: Up to date.
    func testOnlyRulesThatWaitForThePermissionTakeTheLine() {
        XCTAssertEqual(make([idle(contoso), idle(gmail, rules: .notConnected)], waiting: []).state, .upToDate, "no rule waits")
        XCTAssertEqual(make([idle(contoso), idle(gmail)], waiting: [gmail.id]).state, .upToDate, "the permission is there")
        XCTAssertEqual(make([idle(contoso), idle(gmail, rules: .unknown)], waiting: [gmail.id]).state, .upToDate, "not known yet")
        XCTAssertEqual(make([idle(contoso), idle(gmail, rules: .failed(.unreachable, otherCount: nil))], waiting: [gmail.id]).state,
                       .upToDate, "a failure is Settings' to show")
        XCTAssertEqual(make([idle(contoso, rules: .notConnected), idle(gmail)], waiting: [gmail.id]).state, .upToDate,
                       "the other account's permission is not this one's")
        XCTAssertEqual(SyncLineSummary.accountWords(idle(gmail, rules: .notConnected)), "Up to date")
    }

    /// Below what answers the user's own action or keeps mail from syncing, above Demo and Up to date.
    func testPrecedence() {
        let waiting = [idle(contoso), idle(gmail, rules: .notConnected)]
        XCTAssertEqual(make(waiting, waiting: [gmail.id], signIn: .reconnecting(gmail.id)).state, .signingIn)
        XCTAssertEqual(make([AccountSyncStatus(accountID: contoso.id, phase: .needsReauth), idle(gmail, rules: .notConnected)],
                            waiting: [gmail.id]).state, .signInRequired)
        XCTAssertEqual(make(waiting, waiting: [gmail.id], sending: 1).state, .sending)
        XCTAssertEqual(make(waiting, waiting: [gmail.id], checking: true).state, .checking)
        XCTAssertEqual(make(waiting, waiting: [gmail.id], isDemo: true).state, .rulesPermission, "above Demo, though the demo grants it")
        XCTAssertLessThan(SyncLineSummary.State.checking.rawValue, SyncLineSummary.State.rulesPermission.rawValue)
        XCTAssertLessThan(SyncLineSummary.State.rulesPermission.rawValue, SyncLineSummary.State.demo.rawValue)
    }

    /// The tooltip's words are Settings': an answered invitation waiting for the calendar's permission first.
    func testTheCalendarsPermissionComesFirstInTheWords() {
        var both = idle(gmail, rules: .notConnected)
        both.permissionsNeeded = [.calendar]
        XCTAssertEqual(SyncLineSummary.accountWords(both, rulesWaiting: true), "Calendar permission needed")
        XCTAssertEqual(SyncLineSummary.accountWords(idle(gmail, rules: .notConnected), rulesWaiting: true), "Sender rules need permission")
    }
}
