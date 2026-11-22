import Foundation
import XCTest
@testable import PaperCore

/// The demo's server rules: each made-up account's server keeps rules in memory as a real one would (the blocked sender
/// from the start, two other rules to count), the seeder shows the block as the server's rule from the first launch, the
/// engine's rules lane reads and writes them like any server's, and a later launch's server starts from the rules the
/// store mirrors.
final class DemoRulesTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperDemoRulesTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func makeEngine(store: InMemoryMailStore, service: DemoMailService) -> MailEngine {
        var tuning = SyncTuning()
        tuning.pollInterval = 0.1
        tuning.backoffBase = 0.05
        tuning.backoffCap = 0.5
        return MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                          authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(),
                          providerFactory: { service.provider(for: $0) }, tuning: tuning, attachmentCacheDirectory: cacheDirectory)
    }

    private func rows(_ store: MailStoring, _ account: Account) throws -> [String] {
        try store.senderRules().filter { $0.accountID == account.id }
            .map { "\($0.address) \($0.action.rawValue) \($0.sync.rawValue) \($0.serverIDs.joined(separator: ","))" }
    }

    func testTheDemoServerKeepsRulesInMemory() async throws {
        let account = Account(id: AccountID("demo-g"), kind: .gmail, email: "alex@demo-gmail.test", displayName: "Alex",
                              addedAt: Date())
        let provider = try XCTUnwrap(DemoMailService(liveInterval: 3_600).provider(for: account) as? RuleProvider)
        let granted = await provider.hasRulesPermission()
        XCTAssertTrue(granted, "the made-up server needs no reconnect")
        var listing = try await provider.serverRules()
        XCTAssertEqual(listing.senderRules, [ServerSenderRule(serverID: DemoMailbox.blockedRuleID, address: DemoSeeder.blockedSender,
                                                              action: .trash)])
        XCTAssertEqual(listing.otherCount, 2, "other rules to count in Senders")

        let id = try await provider.createSenderRule(address: "news@letter.example", action: .archive)
        let again = try await provider.createSenderRule(address: "news@letter.example", action: .archive)
        XCTAssertEqual(again, id, "an identical rule is the one already there")
        try await provider.deleteRule(serverID: DemoMailbox.blockedRuleID)
        try await provider.deleteRule(serverID: "gone")
        listing = try await provider.serverRules()
        XCTAssertEqual(listing.senderRules, [ServerSenderRule(serverID: id, address: "news@letter.example", action: .archive)])
    }

    /// Seeded, the block is the server's rule (`saved`) from the first launch; the lane's first read agrees and the status
    /// counts the server's other rules. A rule set in the demo goes to its server like any other.
    func testTheSeededBlockIsTheServersRuleAndTheLaneReadsAndWritesTheDemoServer() async throws {
        let store = InMemoryMailStore()
        let service = DemoMailService(liveInterval: 3_600)
        let engine = makeEngine(store: store, service: service)
        let recorder = PhaseRecorder()
        let observation = engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        engine.start()
        let accounts = try await DemoSeeder.seedIfNeeded(engine)
        XCTAssertEqual(accounts.count, 2)
        for account in accounts {
            XCTAssertEqual(try rows(store, account), ["\(DemoSeeder.blockedSender) trash saved \(DemoMailbox.blockedRuleID)"])
        }
        for account in accounts {
            try await waitUntil("read \(account.email)", timeout: 15) {
                if case .upToDate(2, _)? = recorder.latest.first(where: { $0.accountID == account.id })?.rules { return true }
                return false
            }
            XCTAssertEqual(try rows(store, account), ["\(DemoSeeder.blockedSender) trash saved \(DemoMailbox.blockedRuleID)"])
        }

        let gmail = try XCTUnwrap(accounts.first { $0.kind == .gmail })
        try engine.setSenderRule(.archive, for: "news@letter.example", accountID: gmail.id, performing: [])
        try engine.setSenderRule(nil, for: DemoSeeder.blockedSender, accountID: gmail.id, performing: [])
        try await waitUntil("on the demo server", timeout: 15) {
            try self.rows(store, gmail).count == 1 && self.rows(store, gmail).first?.hasPrefix("news@letter.example archive saved ") == true
        }
        let listing = try await XCTUnwrap(service.provider(for: gmail) as? RuleProvider).serverRules()
        XCTAssertEqual(listing.senderRules.map(\.address), ["news@letter.example"])
        await engine.stopAndWait()
    }

    /// The demo mailbox is generated anew every launch; its server's rules start from what the store mirrors, so a rule set
    /// or removed in the demo survives a relaunch rather than being undone by the first read.
    func testALaterLaunchsServerStartsFromTheMirroredRules() throws {
        let store = InMemoryMailStore()
        let account = Account(id: AccountID("demo-o"), kind: .microsoft, email: "alex@demo-outlook.test", displayName: "Alex",
                              addedAt: Date())
        XCTAssertNil(DemoMailService.serverRules(mirroredIn: store, accountID: account.id), "an account the store lacks: the first state")
        try store.upsertAccount(account)
        try store.replaceServerSenderRules(accountID: account.id, with: [
            ServerSenderRule(serverID: "r1", address: "a@x.example", action: .archive),
            ServerSenderRule(serverID: "r2", address: "b@x.example", action: .trash),
            ServerSenderRule(serverID: "r3", address: "c@x.example", action: .trash),
        ], readAt: Date())
        try store.setSenderRule(nil, for: "b@x.example", accountID: account.id, enqueueing: [], at: Date())
        try store.setSenderRule(.archive, for: "c@x.example", accountID: account.id, enqueueing: [], at: Date())
        try store.setSenderRule(.trash, for: "d@x.example", accountID: account.id, enqueueing: [], at: Date())
        XCTAssertEqual(DemoMailService.serverRules(mirroredIn: store, accountID: account.id), [
            ServerSenderRule(serverID: "r1", address: "a@x.example", action: .archive),
            ServerSenderRule(serverID: "r2", address: "b@x.example", action: .trash),
            ServerSenderRule(serverID: "r3", address: "c@x.example", action: .archive),
        ], "on the server: saved, being deleted, being replaced; not what is still being created")
        try store.setSenderRule(nil, for: "a@x.example", accountID: account.id, enqueueing: [], at: Date())
        try store.replaceServerSenderRules(accountID: account.id, with: [], readAt: Date())
        XCTAssertEqual(DemoMailService.serverRules(mirroredIn: store, accountID: account.id)?.map(\.serverID), ["r3"],
                       "every rule removed and read away: the server has none left but the replacement's")
    }

    func testTheDemoServiceHandsTheRestoredRulesToANewServer() async throws {
        let account = Account(id: AccountID("demo-g"), kind: .gmail, email: "alex@demo-gmail.test", displayName: "Alex",
                              addedAt: Date())
        let kept = [ServerSenderRule(serverID: "r9", address: "news@letter.example", action: .archive)]
        let service = DemoMailService(liveInterval: 3_600, restoreRules: { $0 == account.id ? kept : nil })
        let listing = try await XCTUnwrap(service.provider(for: account) as? RuleProvider).serverRules()
        XCTAssertEqual(listing.senderRules, kept, "the blocked sender was removed in an earlier run: it stays removed")
        XCTAssertEqual(listing.otherCount, 2)
    }
}
