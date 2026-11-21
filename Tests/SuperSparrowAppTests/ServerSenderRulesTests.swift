import AppKit
import SSCore
import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Sender rules on the server (spec §5.52): the first rule's alert on an account that has not allowed rules, Continue
/// setting the rule and asking for the permission, Cancel setting nothing, the toast naming the server, the undo of a
/// rule the server has, Settings › Accounts › Senders… (the server's rules from the mirror, each state's words, the read
/// on opening, the foot's count and link, Allow…, the failure), the account row's “Sender rules need permission”, and the
/// demo's rule and other filters. No test signs in or reaches a server: the sign-in is the controller's and the model's
/// callbacks, the engine never starts except the demo's, whose servers are made up.
@MainActor
final class ServerSenderRulesTests: XCTestCase {
    private let gmail = ListTestSupport.accountA
    private let outlook = ListTestSupport.accountB

    private func open(_ id: ConversationID, in harness: MainWindowHarness) {
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentConversationID == id && !harness.reader.currentMessages.isEmpty }
    }

    /// The first conversation of `account` opened, and its rule target.
    private func target(in harness: MainWindowHarness, of account: Account) throws -> MessageMetadata {
        let row = try XCTUnwrap(harness.list.conversations.first { $0.id.accountID == account.id })
        open(row.id, in: harness)
        return try XCTUnwrap(harness.reader.senderRuleTarget)
    }

    private func status(_ account: Account, _ rules: RulesSyncState, phase: AccountSyncPhase = .idle) -> AccountSyncStatus {
        AccountSyncStatus(accountID: account.id, phase: phase, lastSuccessfulSyncAt: Date(), rules: rules)
    }

    private func store(_ harness: MainWindowHarness) -> MailStoring { harness.environment.store }

    // MARK: The first rule's alert

    /// The alert asks only once the engine knows the account has not allowed rules: with them allowed, or before the
    /// engine knows (the rule then waits as any), the rule is set at once.
    func testTheFirstRulesAlertShowsOnlyWhileTheAccountHasNotAllowedRules() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: gmail)
        var asked: [AppAlert] = []
        harness.controller.presentAlert = { alert, _, _ in asked.append(alert) }

        for state in [RulesSyncState.upToDate(otherCount: 3, readAt: Date()), .unknown, .failed(.unreachable, otherCount: nil)] {
            harness.controller.statusesChanged([status(gmail, state)])
            open(target.conversationID, in: harness)
            harness.controller.blockSender(nil)
            XCTAssertTrue(asked.isEmpty, "no alert while \(state)")
            XCTAssertEqual(try store(harness).senderRules().map(\.action), [.trash], "set at once while \(state)")
            harness.controller.performUndo(harness.controller.zTarget)
            XCTAssertTrue(try store(harness).senderRules().isEmpty)
        }

        harness.controller.statusesChanged([status(gmail, .notConnected)])
        open(target.conversationID, in: harness)
        harness.controller.alwaysArchiveSender(nil)
        let alert = try XCTUnwrap(asked.first)
        XCTAssertEqual(alert.title, "Save sender rules in Gmail?")
        XCTAssertEqual(alert.body, "SuperSparrow saves this as a Gmail filter, so mail from this sender is archived on every device, even "
                           + "when this Mac is off. Gmail asks you to allow it once.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Continue", "Cancel"], "Continue first: the default")
        XCTAssertTrue(try store(harness).senderRules().isEmpty, "nothing set before the answer")
        XCTAssertEqual(try store(harness).message(target.id)?.roles.contains(.inbox), true)
    }

    /// Continue sets the rule, on its way to the server, with its toast and undo, then asks the app's sign-in for the
    /// permission: a sign-in abandoned there leaves the rule waiting.
    func testContinueSetsTheRuleAndAsksForThePermission() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: gmail)
        let address = SenderRule.normalizedAddress(try XCTUnwrap(target.from?.address))
        harness.controller.statusesChanged([status(gmail, .notConnected)])
        var connected: [AccountID] = []
        var ruleWhenAsked: [SenderRule.Sync] = []
        harness.controller.onConnectRules = { account in
            connected.append(account.id)
            ruleWhenAsked = (try? self.store(harness).senderRules().map(\.sync)) ?? []
        }
        harness.controller.presentAlert = { _, _, done in done(0) }

        harness.controller.blockSender(nil)
        XCTAssertEqual(connected, [gmail.id], "the reconnect asking for the rules permission")
        XCTAssertEqual(ruleWhenAsked, [.creating], "stored before the browser opens")
        XCTAssertEqual(try store(harness).senderRules().map(\.address), [address])
        XCTAssertEqual(try store(harness).message(target.id)?.roles.contains(.trash), true, "their mail here goes to the Trash")
        XCTAssertEqual(harness.toastMessage, "Gmail will block \(address)")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Block Sender")

        // The sign-in abandoned in the browser (the callback goes no further here): the rule stays, waiting for the permission.
        XCTAssertEqual(try store(harness).senderRules().map(\.sync), [.creating])
        // Its undo just removes it: it never reached the server.
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertTrue(try store(harness).senderRules().isEmpty, "a rule never saved on the server just goes")
        XCTAssertEqual(try store(harness).message(target.id)?.roles, [.inbox])
    }

    func testCancelSetsNothing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: outlook)
        harness.controller.statusesChanged([status(outlook, .notConnected)])
        var connected: [AccountID] = []
        harness.controller.onConnectRules = { connected.append($0.id) }
        var titles: [String] = []
        harness.controller.presentAlert = { alert, _, done in
            titles.append(alert.title)
            done(1)
        }
        let toastBefore = harness.toastMessage
        harness.controller.blockSender(nil)
        XCTAssertEqual(titles, ["Save sender rules in Outlook?"])
        XCTAssertTrue(try store(harness).senderRules().isEmpty)
        XCTAssertEqual(try store(harness).message(target.id)?.roles, [.inbox], "the mail stays")
        XCTAssertTrue(connected.isEmpty, "no sign-in")
        XCTAssertEqual(harness.toastMessage, toastBefore, "no toast")
        XCTAssertEqual(AppAlert.saveSenderRules(.microsoft, action: .trash).body,
                       "SuperSparrow saves this as an Outlook rule, so mail from this sender goes to the Trash on every device, even "
                           + "when this Mac is off. Outlook asks you to allow it once.")
    }

    // MARK: Toast and undo

    func testTheToastNamesTheServerThatRunsTheRule() {
        XCTAssertEqual(SenderRuleCopy.toast(.archive, address: "news@letter.example", kind: .gmail), "Gmail will archive mail from news@letter.example")
        XCTAssertEqual(SenderRuleCopy.toast(.trash, address: "deals@shop.example", kind: .gmail), "Gmail will block deals@shop.example")
        XCTAssertEqual(SenderRuleCopy.toast(.archive, address: "news@letter.example", kind: .microsoft),
                       "Outlook will archive mail from news@letter.example")
        XCTAssertEqual(SenderRuleCopy.toast(.trash, address: "deals@shop.example", kind: .microsoft), "Outlook will block deals@shop.example")
    }

    /// Undo of a rule the server saved meanwhile deletes it there, not just here.
    func testUndoingARuleTheServerSavedDeletesItThere() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: gmail)
        let address = SenderRule.normalizedAddress(try XCTUnwrap(target.from?.address))
        harness.controller.blockSender(nil)
        // The server saved it, as the rules lane's next read finds it.
        try store(harness).replaceServerSenderRules(accountID: gmail.id, with: [ServerSenderRule(serverID: "f1", address: address, action: .trash)],
                                                   readAt: Date())
        XCTAssertEqual(try store(harness).senderRules().map(\.sync), [.saved])
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertEqual(try store(harness).senderRules().map(\.sync), [.deleting], "deleted on the server, not just here")
        XCTAssertNil(harness.reader.senderRule(for: target), "no longer the sender's")
        XCTAssertEqual(try store(harness).message(target.id)?.roles, [.inbox], "and the mail is back")
    }

    /// Undo of the other action chosen for a rule the server holds puts the server's own rule back.
    func testUndoingAReplacedRulePutsTheServersOwnBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: gmail)
        let address = SenderRule.normalizedAddress(try XCTUnwrap(target.from?.address))
        try store(harness).replaceServerSenderRules(accountID: gmail.id, with: [ServerSenderRule(serverID: "f1", address: address, action: .trash)],
                                                   readAt: Date())
        harness.controller.alwaysArchiveSender(nil)
        XCTAssertEqual(try store(harness).senderRules().map(\.sync), [.replacing])
        XCTAssertEqual(try store(harness).senderRules().map(\.action), [.archive])
        XCTAssertEqual(harness.toastMessage, "Gmail will archive mail from \(address)")
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertEqual(try store(harness).senderRules().map(\.action), [.trash], "the block back")
        XCTAssertEqual(harness.reader.senderRule(for: target), .trash)
    }

    // MARK: The sync line

    /// Rules waiting for the permission (an existing user's, uploaded once, among them) act nowhere until it is granted:
    /// the main window's sync line says so, and its Reconnect runs the rules' sign-in; once the rules are on their way no
    /// more, the line is Up to date again.
    func testTheSyncLineAsksForTheRulesPermission() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let line = { harness.controller.listPane.statusBar.summary }
        let checked = Date()
        harness.controller.statusesChanged([
            AccountSyncStatus(accountID: gmail.id, phase: .idle, lastSuccessfulSyncAt: checked, rules: .notConnected),
            AccountSyncStatus(accountID: outlook.id, phase: .idle, lastSuccessfulSyncAt: checked, rules: .upToDate(otherCount: 0, readAt: checked)),
        ])
        XCTAssertEqual(line().state, .upToDate, "no rule waits yet")

        try store(harness).setSenderRule(.trash, for: "deals@shop.example", accountID: gmail.id, enqueueing: [], at: Date())
        harness.spin { line().state == .rulesPermission }
        XCTAssertEqual(line().lead, "Sender rules need permission")
        XCTAssertEqual(line().detail, AccountLabels.name(for: gmail))
        XCTAssertEqual(line().action, .connectRules(gmail.id))
        let button = harness.controller.listPane.statusBar.actionButton
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.title, "Reconnect")
        var connected: [AccountID] = []
        harness.controller.onConnectRules = { connected.append($0.id) }
        button.performClick(nil)
        XCTAssertEqual(connected, [gmail.id])

        // The rule removed before it reached the server: nothing waits.
        try store(harness).setSenderRule(nil, for: "deals@shop.example", accountID: gmail.id, enqueueing: [], at: Date())
        harness.spin { line().state == .upToDate }
        XCTAssertEqual(line().state, .upToDate)
    }

    // MARK: The Senders sheet

    private func model(isDemo: Bool = false) -> SettingsModel {
        let model = SettingsModel(isDemo: isDemo,
                                  oauthFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID()).json"))
        model.setAccounts([gmail, outlook])
        return model
    }

    private func rule(_ account: Account, _ address: String, _ action: SenderRule.Action, _ sync: SenderRule.Sync) -> SenderRule {
        SenderRule(accountID: account.id, address: address, action: action, createdAt: Date(), serverIDs: sync == .creating ? [] : ["f"],
                   sync: sync)
    }

    /// The account's rules by address, each with what it does and, on its way to the server, where it stands; another
    /// account's are not listed.
    func testTheSheetListsTheServersRulesWithEachStatesWords() {
        let model = model()
        model.setSenderRules([
            rule(gmail, "updates@service.example", .archive, .replacing), rule(gmail, "deals@shop.example", .trash, .saved),
            rule(gmail, "offers@deals.example", .trash, .deleting), rule(gmail, "news@letter.example", .archive, .creating),
            rule(outlook, "other@b.example", .trash, .creating),
        ])
        model.statuses = [gmail.id: status(gmail, .upToDate(otherCount: 12, readAt: Date())),
                          outlook.id: status(outlook, .upToDate(otherCount: 1, readAt: Date()))]
        let content = model.sendersContent(for: gmail)
        XCTAssertEqual(content.caption, "Gmail filters for alex@contoso.test: mail from these senders is archived or moved to the Trash "
                           + "as it arrives, on every device.")
        XCTAssertEqual(content.rows, [
            .init(address: "deals@shop.example", detail: "Blocked", state: nil, isRemovable: true),
            .init(address: "news@letter.example", detail: "Archived", state: "Saving to Gmail…", isRemovable: true),
            .init(address: "offers@deals.example", detail: "Blocked", state: "Removing…", isRemovable: false),
            .init(address: "updates@service.example", detail: "Archived", state: "Saving to Gmail…", isRemovable: true),
        ])
        XCTAssertNil(content.notice)
        XCTAssertEqual(content.foot, .others("12 other filters in Gmail", link: "Open Gmail Settings"))

        let other = model.sendersContent(for: outlook)
        XCTAssertEqual(other.caption, "Outlook rules for alex@fabrikam.test: mail from these senders is archived or moved to the Trash "
                           + "as it arrives, on every device.")
        XCTAssertEqual(other.rows, [.init(address: "other@b.example", detail: "Blocked", state: "Saving to Outlook…", isRemovable: true)])
        XCTAssertEqual(other.foot, .others("1 other rule in Outlook", link: "Open Outlook Settings"))

        // The rows as the list draws them, and the − of a rule already on its way out does nothing more.
        var removed: [String] = []
        model.removeSenderRule = { removed.append($0.address) }
        let sheet = SendersSheet(model: model, account: gmail, onDone: {})
        XCTAssertEqual(sheet.rows.map(\.state), [nil, "Saving to Gmail…", "Removing…", "Saving to Gmail…"])
        XCTAssertEqual(sheet.rows.map(\.isRemovable), [true, true, false, true])
        sheet.remove(sheet.rows[2])
        sheet.remove(sheet.rows[0])
        XCTAssertEqual(removed, ["deals@shop.example"], "the saved one queued for deletion; the one being deleted left alone")
    }

    /// Until this run's first read answers, the foot says it reads; an account waiting for sign-in reads nothing.
    func testTheFootSaysItReadsUntilTheFirstReadAnswers() {
        let model = model()
        XCTAssertEqual(model.sendersContent(for: gmail).foot, .reading("Reading Gmail filters…"), "no status yet")
        model.statuses = [gmail.id: status(gmail, .unknown), outlook.id: status(outlook, .unknown, phase: .needsReauth)]
        XCTAssertEqual(model.sendersContent(for: gmail).foot, .reading("Reading Gmail filters…"))
        XCTAssertEqual(model.sendersContent(for: outlook).foot, .others(nil, link: "Open Outlook Settings"), "no spinner while parked")
        model.statuses = [gmail.id: status(gmail, .upToDate(otherCount: 0, readAt: Date()))]
        XCTAssertEqual(model.sendersContent(for: gmail).foot, .others(nil, link: "Open Gmail Settings"), "no other filters: the link alone")
        XCTAssertEqual(SenderRuleCopy.others(1_234, kind: .gmail), "\(1_234.formatted()) other filters in Gmail")
    }

    /// The foot's link opens the provider's own page of rules: Gmail's filters in the account's session, Outlook.com's or
    /// Microsoft 365's rules.
    func testTheFootsLinkOpensTheProvidersOwnRules() throws {
        let model = model()
        model.statuses = [gmail.id: status(gmail, .upToDate(otherCount: 2, readAt: Date()))]
        var opened: [URL] = []
        model.openWebSettings = { opened.append($0) }
        let sheet = SendersSheet(model: model, account: gmail, onDone: {})
        let foot = try XCTUnwrap(sheet.sheetBody.foot)
        XCTAssertEqual(foot.words, "2 other filters in Gmail")
        XCTAssertEqual(foot.link?.title, "Open Gmail Settings")
        foot.link?.action()
        XCTAssertEqual(opened.map(\.absoluteString), ["https://mail.google.com/mail/u/?authuser=alex@contoso.test#settings/filters"])

        func url(_ email: String, _ kind: ProviderKind) -> String? {
            SenderRuleCopy.webSettingsURL(for: Account(id: AccountID(email), kind: kind, email: email, displayName: "", addedAt: Date()))?
                .absoluteString
        }
        XCTAssertEqual(url("alex+news@gmail.com", .gmail), "https://mail.google.com/mail/u/?authuser=alex%2Bnews@gmail.com#settings/filters",
                       "a + reaches Google as itself, not a space")
        XCTAssertEqual(url("alex@outlook.com", .microsoft), "https://outlook.live.com/mail/0/options/mail/rules")
        XCTAssertEqual(url("alex@hotmail.co.uk", .microsoft), "https://outlook.live.com/mail/0/options/mail/rules")
        XCTAssertEqual(url("alex@fabrikam.test", .microsoft), "https://outlook.office.com/mail/options/mail/rules")
    }

    /// Without the permission, every rule on its way waits for it and the banner's Allow… asks for it; while that sign-in
    /// waits for the browser, the banner says so and its Cancel ends it.
    func testWithoutThePermissionAllowAsksForIt() throws {
        let model = model()
        model.setSenderRules([rule(gmail, "news@letter.example", .archive, .creating), rule(gmail, "deals@shop.example", .trash, .deleting)])
        model.statuses = [gmail.id: status(gmail, .notConnected)]
        var connected: [AccountID] = []
        var cancelled = 0
        model.connectRules = { connected.append($0.id) }
        model.cancelSignIn = { cancelled += 1 }
        let content = model.sendersContent(for: gmail)
        XCTAssertEqual(content.rows.map(\.state), ["Waiting for permission", "Waiting for permission"])
        XCTAssertEqual(content.notice, .needsPermission("SuperSparrow needs permission to read and save Gmail filters."))
        XCTAssertEqual(content.foot, .others(nil, link: "Open Gmail Settings"))

        let parts = try XCTUnwrap(SendersSheet(model: model, account: gmail, onDone: {}).sheetBody.noticeParts)
        XCTAssertEqual(parts.variant, .info)
        XCTAssertEqual(parts.link?.title, "Allow…")
        parts.link?.action()
        XCTAssertEqual(connected, [gmail.id])

        model.reconnecting = gmail.id
        XCTAssertEqual(model.sendersContent(for: gmail).notice, .waitingForBrowser("Waiting for your browser to allow Gmail filters."))
        let waiting = try XCTUnwrap(SendersSheet(model: model, account: gmail, onDone: {}).sheetBody.noticeParts)
        XCTAssertEqual(waiting.link?.title, "Cancel")
        waiting.link?.action()
        XCTAssertEqual(cancelled, 1)
    }

    /// A failure shows its words in a danger banner, and the foot keeps the last count.
    func testAFailureShowsItsWordsInDanger() throws {
        let model = model()
        model.statuses = [gmail.id: status(gmail, .failed(.limitReached, otherCount: 12)),
                          outlook.id: status(outlook, .failed(.unreachable, otherCount: nil))]
        XCTAssertEqual(model.sendersContent(for: gmail).notice, .failed("Gmail has too many filters to save this one."))
        XCTAssertEqual(model.sendersContent(for: gmail).foot, .others("12 other filters in Gmail", link: "Open Gmail Settings"))
        XCTAssertEqual(model.sendersContent(for: outlook).notice, .failed("Couldn’t reach Outlook. Trying again soon."))
        let parts = try XCTUnwrap(SendersSheet(model: model, account: gmail, onDone: {}).sheetBody.noticeParts)
        XCTAssertEqual(parts.variant, .danger)
        XCTAssertNil(parts.link)
    }

    /// Opening the sheet asks the engine to read the account's rules from the server, then and only then.
    func testOpeningTheSheetReadsTheServer() throws {
        _ = NSApplication.shared
        let model = model()
        var read: [AccountID] = []
        model.refreshServerRules = { read.append($0.id) }
        let sheet = SendersSheet(model: model, account: outlook, onDone: {})
        XCTAssertTrue(read.isEmpty, "building it reads nothing")
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 480, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.contentView = NSHostingView(rootView: sheet)
        window.orderBack(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { !read.isEmpty }, timeout: 3))
        XCTAssertEqual(read, [outlook.id])
    }

    /// The Settings window points the read at the engine.
    func testTheSettingsWindowAsksTheEngineToRead() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ServerSenderRulesTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try environment.store.upsertAccount(gmail)
        let controller = SettingsWindowController(environment: environment, settings: ListTestSupport.settings(), mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        // The engine never started: asking is all there is to see, and it must not throw or wait.
        controller.model.refreshServerRules(gmail)
        XCTAssertTrue(controller.model.senderRules.isEmpty)
    }

    // MARK: Settings › Accounts

    /// Mail is current, but a rule waits for the permission: the row asks with Reconnect, which runs the rules' sign-in.
    func testARuleWaitingForPermissionAsksToReconnect() throws {
        let model = model()
        model.setSenderRules([rule(gmail, "news@letter.example", .archive, .creating)])
        model.statuses = [gmail.id: status(gmail, .notConnected)]
        let line = model.status(for: gmail)
        XCTAssertEqual(line, .senderRulesPermission(rules: "Gmail filters"))
        XCTAssertEqual(line.words, "Sender rules need permission")
        XCTAssertEqual(line.actionTitle, "Reconnect")
        XCTAssertEqual(line.tooltip, "Sender rules: SuperSparrow needs permission to save them as Gmail filters.")
        XCTAssertNil(line.addressReplacement, "the account still syncs: its address stays")

        var connected: [AccountID] = []
        var reconnected: [AccountID] = []
        model.connectRules = { connected.append($0.id) }
        model.reconnect = { reconnected.append($0.id) }
        model.performRowAction(try XCTUnwrap(model.rows.first { $0.id == gmail.id.rawValue }))
        XCTAssertEqual(connected, [gmail.id])
        XCTAssertTrue(reconnected.isEmpty)

        // Nothing waiting: up to date, whatever the permission.
        model.setSenderRules([rule(gmail, "news@letter.example", .archive, .saved)])
        XCTAssertEqual(model.status(for: gmail).words, "Up to date")
        // An answered invitation waiting too: the calendar's line, whose reconnect asks for both.
        model.setSenderRules([rule(gmail, "news@letter.example", .archive, .creating)])
        model.statuses = [gmail.id: AccountSyncStatus(accountID: gmail.id, phase: .idle, lastSuccessfulSyncAt: Date(),
                                                      permissionsNeeded: [.calendar], rules: .notConnected)]
        XCTAssertEqual(model.status(for: gmail), .calendarPermission)
        model.performRowAction(try XCTUnwrap(model.rows.first { $0.id == gmail.id.rawValue }))
        XCTAssertEqual(reconnected, [gmail.id])
        // Signing in again comes first.
        model.statuses = [gmail.id: status(gmail, .notConnected, phase: .needsReauth)]
        XCTAssertEqual(model.status(for: gmail), .signInRequired)
        XCTAssertEqual(QuireAccountStatus.senderRulesPermission(rules: "Outlook rules").tooltip,
                       "Sender rules: SuperSparrow needs permission to save them as Outlook rules.")
    }

    // MARK: Demo

    /// The demo's made-up servers block a made-up sender and keep two other rules: the sheet shows the saved rule and
    /// “2 other filters in Gmail”, with no link to a real Gmail.
    func testTheDemoShowsItsSeededRuleAndTheServersOtherFilters() throws {
        let harness = try MainWindowHarness(accounts: false, demo: true)
        defer { harness.close() }
        harness.environment.start()
        let controller = SettingsWindowController(environment: harness.environment, settings: harness.settings,
                                                  mailtoHandler: FakeMailtoHandler(), loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        let model = controller.model
        func demoGmail() -> Account? {
            controller.refreshAccounts()
            return model.accounts.first { $0.kind == .gmail }
        }
        ListTestSupport.spin(until: {
            guard let account = demoGmail(), case .upToDate? = model.statuses[account.id]?.rules else { return false }
            return model.senderRules(for: account).contains { $0.sync == .saved }
        }, timeout: 30)
        let account = try XCTUnwrap(demoGmail())
        let content = model.sendersContent(for: account)
        XCTAssertEqual(content.rows, [.init(address: DemoSeeder.blockedSender, detail: "Blocked", state: nil, isRemovable: true)])
        XCTAssertEqual(content.foot, .others("2 other filters in Gmail", link: nil), "the mailboxes are made up: no link")
        XCTAssertNil(content.webSettingsURL)
        XCTAssertNil(content.notice)
    }
}
