import AppKit
import PaperCore
import PaperDesign
import SwiftUI
import XCTest
@testable import PaperApp

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

    // MARK: Setting a rule: never one of this Mac alone

    /// With the permission (read from the account's grant, no request) the rule is set at once, with no alert.
    func testWithThePermissionTheRuleIsSetAtOnce() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: gmail)
        let address = SenderRule.normalizedAddress(try XCTUnwrap(target.from?.address))
        var asked: [AccountID] = []
        harness.controller.hasRulesPermission = { id in
            asked.append(id)
            return true
        }
        var alerts: [String] = []
        harness.controller.presentAlert = { alert, _, _ in alerts.append(alert.title) }
        harness.controller.blockSender(nil)
        harness.spin { (try? self.store(harness).senderRules().isEmpty) == false }
        XCTAssertEqual(asked, [gmail.id], "the grant is asked first")
        XCTAssertTrue(alerts.isEmpty)
        XCTAssertEqual(try store(harness).senderRules().map(\.sync), [.creating], "on its way to the server")
        XCTAssertEqual(try store(harness).message(target.id)?.roles.contains(.trash), true)
        XCTAssertEqual(harness.toastMessage, "Gmail will block \(address)")
    }

    /// Without it the alert asks; Continue runs the sign-in that asks for the permission first, and only once that went
    /// through and the grant holds it is the rule set, with its steps, toast and undo.
    func testWithoutThePermissionContinueSignsInFirstThenSetsTheRule() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: gmail)
        let address = SenderRule.normalizedAddress(try XCTUnwrap(target.from?.address))
        var granted = false
        harness.controller.hasRulesPermission = { _ in granted }
        var alerts: [AppAlert] = []
        harness.controller.presentAlert = { alert, _, done in
            alerts.append(alert)
            done(0)
        }
        var connected: [AccountID] = []
        var storedWhenAsked: [SenderRule] = []
        var finish: ((Bool) -> Void)?
        harness.controller.onConnectRules = { account, done in
            connected.append(account.id)
            storedWhenAsked = (try? self.store(harness).senderRules()) ?? []
            finish = done
        }

        harness.controller.alwaysArchiveSender(nil)
        harness.spin { finish != nil }
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alert.title, "Save sender rules in Gmail?")
        XCTAssertEqual(alert.body, "Paper saves this as a Gmail filter, so mail from this sender is archived on every device, even "
                           + "when this Mac is off. Gmail asks you to allow it once.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Continue", "Cancel"], "Continue first: the default")
        XCTAssertEqual(connected, [gmail.id], "the sign-in asking for the rules permission")
        XCTAssertTrue(storedWhenAsked.isEmpty, "nothing stored while the browser asks")
        XCTAssertEqual(try store(harness).message(target.id)?.roles.contains(.inbox), true, "no mail moved yet")

        granted = true
        finish?(true)
        harness.spin { (try? self.store(harness).senderRules().isEmpty) == false }
        XCTAssertEqual(try store(harness).senderRules().map(\.action), [.archive])
        XCTAssertEqual(try store(harness).message(target.id)?.roles.contains(.inbox), false, "their mail here archived with it")
        XCTAssertEqual(harness.toastMessage, "Gmail will archive mail from \(address)")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Always Archive Mail from This Sender")
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertTrue(try store(harness).senderRules().isEmpty, "a rule not on the server yet just goes")
        XCTAssertEqual(try store(harness).message(target.id)?.roles, [.inbox])
    }

    func testCancelSetsNothing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: outlook)
        harness.controller.hasRulesPermission = { _ in false }
        var connected: [AccountID] = []
        harness.controller.onConnectRules = { account, _ in connected.append(account.id) }
        var titles: [String] = []
        harness.controller.presentAlert = { alert, _, done in
            titles.append(alert.title)
            done(1)
        }
        let toastBefore = harness.toastMessage
        harness.controller.blockSender(nil)
        harness.spin { !titles.isEmpty }
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(titles, ["Save sender rules in Outlook?"])
        XCTAssertTrue(try store(harness).senderRules().isEmpty)
        XCTAssertEqual(try store(harness).message(target.id)?.roles, [.inbox], "the mail stays")
        XCTAssertTrue(connected.isEmpty, "no sign-in")
        XCTAssertEqual(harness.toastMessage, toastBefore, "no toast")
        XCTAssertEqual(AppAlert.saveSenderRules(.microsoft, action: .trash).body,
                       "Paper saves this as an Outlook rule, so mail from this sender goes to the Trash on every device, even "
                           + "when this Mac is off. Outlook asks you to allow it once.")
    }

    /// A sign-in abandoned in the browser, or one that failed, sets nothing and moves no mail: no rule ever waits on this Mac.
    func testAnAbandonedSignInSetsNothing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: gmail)
        harness.controller.hasRulesPermission = { _ in false }
        harness.controller.presentAlert = { _, _, done in done(0) }
        var answered = 0
        harness.controller.onConnectRules = { _, done in
            answered += 1
            done(false)
        }
        let toastBefore = harness.toastMessage
        harness.controller.blockSender(nil)
        harness.spin { answered == 1 }
        ListTestSupport.spin(for: 0.1)
        XCTAssertTrue(try store(harness).senderRules().isEmpty)
        XCTAssertEqual(try store(harness).message(target.id)?.roles, [.inbox], "no steps applied")
        XCTAssertTrue(try store(harness).pendingOperations(accountID: gmail.id, limit: 10).isEmpty, "nothing queued")
        XCTAssertEqual(harness.toastMessage, toastBefore, "no toast, no undo")
    }

    /// A sign-in that went through without the permission (left unticked on the consent screen) sets nothing either: the
    /// alert says so, and Try Again asks again.
    func testASignInWithoutThePermissionSetsNothingAndOffersToTryAgain() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let target = try target(in: harness, of: gmail)
        harness.controller.hasRulesPermission = { _ in false }
        var titles: [String] = []
        harness.controller.presentAlert = { alert, _, done in
            titles.append(alert.title)
            done(titles.count == 1 ? 0 : 1)
        }
        harness.controller.onConnectRules = { _, done in done(true) }
        harness.controller.blockSender(nil)
        harness.spin { titles.count == 2 }
        XCTAssertEqual(titles, ["Save sender rules in Gmail?", "Gmail didn't allow sender rules"])
        XCTAssertEqual(AppAlert.senderRulesNotAllowed(.gmail).buttons.map(\.title), ["Try Again", "Cancel"])
        XCTAssertTrue(try store(harness).senderRules().isEmpty)
        XCTAssertEqual(try store(harness).message(target.id)?.roles, [.inbox])
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
        harness.spin { (try? self.store(harness).senderRules().isEmpty) == false }
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
        harness.spin { (try? self.store(harness).senderRules().map(\.sync)) == [.replacing] }
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
        harness.controller.onConnectRules = { account, _ in connected.append(account.id) }
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

    /// With the permission, the account's rules by address: the server's, and the changes the engine is sending there, each
    /// with what it does and, on its way, where it stands; another account's are not listed.
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
        XCTAssertTrue(content.showsList)
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

    /// Until this run's first read answers, the foot says it reads and the list holds the last read's rules (those with
    /// server ids, the changes to them included), never a rule set since that the engine has not been able to send; an
    /// account waiting for sign-in reads nothing.
    func testUntilTheFirstReadAnswersOnlyTheLastReadsRulesShow() {
        let model = model()
        model.setSenderRules([
            rule(gmail, "deals@shop.example", .trash, .saved), rule(gmail, "news@letter.example", .archive, .creating),
            rule(gmail, "offers@deals.example", .trash, .deleting), rule(gmail, "updates@service.example", .archive, .replacing),
        ])
        let before = model.sendersContent(for: gmail)
        XCTAssertEqual(before.foot, .reading("Reading Gmail filters…"), "no status yet")
        XCTAssertTrue(before.showsList)
        XCTAssertEqual(before.rows.map(\.address), ["deals@shop.example", "offers@deals.example", "updates@service.example"],
                       "the rule never saved on the server is not listed yet")
        XCTAssertEqual(before.rows.map(\.state), [nil, "Removing…", "Saving to Gmail…"])
        model.statuses = [gmail.id: status(gmail, .upToDate(otherCount: 0, readAt: Date()))]
        XCTAssertEqual(model.sendersContent(for: gmail).rows.map(\.address),
                       ["deals@shop.example", "news@letter.example", "offers@deals.example", "updates@service.example"],
                       "once the engine can send it, it shows, saving")
        model.statuses = [gmail.id: status(gmail, .failed(.unreachable, otherCount: 0))]
        XCTAssertEqual(model.sendersContent(for: gmail).rows.count, 4, "a failure's backoff still sends it")
        model.setSenderRules([])
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

    /// Without the permission the server's rules cannot be read: no list at all (not even “No sender rules”), only the
    /// banner, whose Allow… asks for it and which counts, never lists, the rules kept on this Mac from before 1.14 that go
    /// to the server then; while that sign-in waits for the browser, the banner says so and its Cancel ends it.
    func testWithoutThePermissionOnlyTheBannerShows() throws {
        let model = model()
        model.setSenderRules([
            rule(gmail, "a@one.example", .trash, .creating), rule(gmail, "b@two.example", .archive, .creating),
            rule(gmail, "c@three.example", .trash, .creating), rule(gmail, "deals@shop.example", .trash, .saved),
            rule(outlook, "news@letter.example", .archive, .creating),
        ])
        model.statuses = [gmail.id: status(gmail, .notConnected), outlook.id: status(outlook, .notConnected)]
        var connected: [AccountID] = []
        var cancelled = 0
        model.connectRules = { connected.append($0.id) }
        model.cancelSignIn = { cancelled += 1 }
        let content = model.sendersContent(for: gmail)
        XCTAssertFalse(content.showsList, "no list, so no “No sender rules” either")
        XCTAssertTrue(content.rows.isEmpty, "no row of this Mac's, nor the last read's")
        XCTAssertEqual(content.notice, .needsPermission("Allow Paper to read and save Gmail filters. Your 3 sender rules from this "
                                                            + "Mac move to Gmail then."))
        XCTAssertFalse(String(describing: content).contains("one.example"), "counted, never named")
        XCTAssertEqual(content.foot, .others(nil, link: "Open Gmail Settings"))
        XCTAssertEqual(model.sendersContent(for: outlook).notice,
                       .needsPermission("Allow Paper to read and save Outlook rules. Your sender rule from this Mac moves to Outlook then."))
        model.setSenderRules([])
        XCTAssertEqual(model.sendersContent(for: gmail).notice, .needsPermission("Allow Paper to read and save Gmail filters."))
        XCTAssertFalse(model.sendersContent(for: gmail).showsList)
        model.setSenderRules([rule(gmail, "a@one.example", .trash, .creating)])

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

    /// A create the server refused for good leaves the list: the rules lane gives the row up, and the sheet shows the
    /// failure's banner, never the rule.
    func testARefusedCreateLeavesTheList() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ServerSenderRulesTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try environment.store.upsertAccount(gmail)
        let controller = SettingsWindowController(environment: environment, settings: ListTestSupport.settings(), mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        let model = controller.model
        model.statuses = [gmail.id: status(gmail, .upToDate(otherCount: 0, readAt: Date()))]
        try environment.engine.setSenderRule(.trash, for: "-everyone@shop.example", accountID: gmail.id, performing: [])
        XCTAssertTrue(ListTestSupport.spin(until: { model.sendersContent(for: self.gmail).rows.count == 1 }, timeout: 3))
        XCTAssertEqual(model.sendersContent(for: gmail).rows.first?.state, "Saving to Gmail…")

        // As the lane settles a create refused for good: the row goes, and the status says why through the reads after.
        XCTAssertTrue(try environment.store.settleSenderRule(for: "-everyone@shop.example", accountID: gmail.id,
                                                             .refused(attempted: .creating, serverHas: nil)))
        model.statuses = [gmail.id: status(gmail, .failed(.refused, otherCount: 0))]
        XCTAssertTrue(ListTestSupport.spin(until: { model.senderRules.isEmpty }, timeout: 3))
        let content = model.sendersContent(for: gmail)
        XCTAssertTrue(content.rows.isEmpty, "never shown once refused")
        XCTAssertTrue(content.showsList, "the empty list says there is no rule")
        XCTAssertEqual(content.notice, .failed("Gmail didn’t accept this filter."))
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
        XCTAssertEqual(line.tooltip, "Sender rules: Paper needs permission to save them as Gmail filters.")
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
                       "Sender rules: Paper needs permission to save them as Outlook rules.")
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
