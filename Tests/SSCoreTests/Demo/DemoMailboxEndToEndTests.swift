import Foundation
import XCTest
@testable import SSCore

/// MailEngine + InMemoryMailStore + DemoMailProvider, wired the way demo mode wires them.
final class DemoMailboxEndToEndTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperSparrowDemoTests-\(UUID().uuidString)", isDirectory: true)
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
        return MailEngine(
            store: store,
            tokenStore: InMemoryTokenStore(),
            tokenProvider: DemoTokenProvider(),
            authenticator: DemoAuthenticator(),
            sanitizer: HTMLSanitizer(),
            providerFactory: { service.provider(for: $0) },
            tuning: tuning,
            attachmentCacheDirectory: cacheDirectory
        )
    }

    private func messages(_ store: MailStoring, account: AccountID) throws -> [MessageMetadata] {
        let summaries = try store.conversations(ConversationQuery(accountIDs: [account], view: .all, limit: .max))
        return try summaries.flatMap { try store.messages(in: $0.id) }
    }

    private func seededEngine(service: DemoMailService = DemoMailService(liveInterval: 3_600)) async throws
        -> (MailEngine, InMemoryMailStore, [Account]) {
        let store = InMemoryMailStore()
        let engine = makeEngine(store: store, service: service)
        engine.start()
        let accounts = try await DemoSeeder.seedIfNeeded(engine)
        for account in accounts {
            let expected = DemoProfile.profile(for: account.kind).messageCount
            try await waitUntil("bootstrap of \(account.email)", timeout: 15) {
                try store.syncCursor(for: account.id) != nil && self.messages(store, account: account.id).count == expected
            }
        }
        return (engine, store, accounts)
    }

    // MARK: Tests

    func testSeederAddsBothDemoAccountsAndBootstrapLandsEveryMessage() async throws {
        let (engine, store, accounts) = try await seededEngine()
        XCTAssertEqual(Set(accounts.map(\.email)), ["alex@demo-gmail.test", "alex@demo-outlook.test"])
        XCTAssertEqual(Set(accounts.map(\.kind)), [.gmail, .microsoft])
        XCTAssertEqual(Set(accounts.map(\.inkSlot)), [0, 1])

        let inbox = try store.conversations(ConversationQuery(view: .inbox, limit: .max))
        XCTAssertGreaterThan(inbox.count, 40)
        XCTAssertTrue(inbox.contains { $0.unreadCount > 0 })
        XCTAssertTrue(inbox.contains { $0.inboxSection == .focused })
        XCTAssertTrue(inbox.contains { $0.inboxSection == .other })
        XCTAssertFalse(try store.conversations(ConversationQuery(view: .starred, limit: .max)).isEmpty)
        XCTAssertFalse(try store.conversations(ConversationQuery(view: .sent, limit: .max)).isEmpty)
        XCTAssertGreaterThan(try store.unreadInboxCount(accountIDs: nil), 0)
        let counts = try Dictionary(grouping: store.conversations(ConversationQuery(view: .all, limit: .max)), by: \.messageCount)
        XCTAssertNotNil(counts[1])
        XCTAssertTrue(counts.keys.contains { $0 >= 4 }, "expected some long threads, got \(counts.keys.sorted())")

        // Seeding again is a no-op.
        let again = try await DemoSeeder.seedIfNeeded(engine)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(try engine.accounts().count, 2)
        await engine.stopAndWait()
    }

    func testBodiesHydrateWithInlineImageAndAttachmentsServeBytes() async throws {
        let (engine, store, accounts) = try await seededEngine()
        let gmail = try XCTUnwrap(accounts.first { $0.kind == .gmail })
        let outlook = try XCTUnwrap(accounts.first { $0.kind == .microsoft })

        let photo = try XCTUnwrap(try messages(store, account: gmail.id).first { $0.subject == "Photos from the offsite" })
        let body = try await engine.ensureBody(for: photo.id)
        XCTAssertTrue(body.renderedHTML.contains(RenderURLScheme.inlineImage + "://"), "cid image should be rewritten")
        let png = try await engine.attachmentData(for: photo.id, attachmentID: DemoMailboxBuilder.photoAttachmentID)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let invoice = try XCTUnwrap(try messages(store, account: outlook.id).first { $0.subject == "Invoice INV-2041" && $0.hasAttachments })
        let pdf = try await engine.attachmentData(for: invoice.id, attachmentID: DemoMailboxBuilder.invoiceAttachmentID)
        XCTAssertEqual(String(decoding: pdf.prefix(8), as: UTF8.self), "%PDF-1.4")
        XCTAssertTrue(String(decoding: pdf, as: UTF8.self).hasSuffix("%%EOF\n"))

        let reply = try XCTUnwrap(try messages(store, account: gmail.id).first { $0.subject == "Re: Lisbon in March?" })
        let replyBody = try await engine.ensureBody(for: reply.id)
        XCTAssertTrue(replyBody.body.html?.contains("gmail_quote") ?? false)
        let roadmap = try XCTUnwrap(try messages(store, account: outlook.id).first { $0.subject == "Re: Q4 roadmap review" })
        let roadmapBody = try await engine.ensureBody(for: roadmap.id)
        XCTAssertTrue(roadmapBody.body.html?.contains("divRplyFwdMsg") ?? false)
        await engine.stopAndWait()
    }

    func testArchiveRoundTripReachesTheProviderAndBack() async throws {
        let service = DemoMailService(liveInterval: 3_600)
        let (engine, store, accounts) = try await seededEngine(service: service)
        let gmail = try XCTUnwrap(accounts.first { $0.kind == .gmail })
        let provider = service.provider(for: gmail)
        let target = try XCTUnwrap(try store.conversations(ConversationQuery(accountIDs: [gmail.id], view: .inbox, limit: 1)).first)
        let inboxIDs = try store.messages(in: target.id).filter(\.isInInbox).map(\.id)
        XCTAssertFalse(inboxIDs.isEmpty)

        try engine.perform(.archive, on: target.id)
        // Local first: gone from the inbox before any network round trip.
        XCTAssertFalse(try store.conversations(ConversationQuery(view: .inbox, limit: .max)).contains { $0.id == target.id })
        try await waitUntil("archive replayed to the provider") {
            try store.pendingOperations(accountID: gmail.id, limit: 10).isEmpty
        }
        var remote = try await provider.metadata(for: inboxIDs.map(\.providerID))
        XCTAssertTrue(remote.allSatisfy { !$0.roles.contains(.inbox) })

        try engine.perform(.moveToInbox, on: inboxIDs)
        XCTAssertTrue(try store.conversations(ConversationQuery(view: .inbox, limit: .max)).contains { $0.id == target.id })
        try await waitUntil("restore replayed to the provider") {
            try store.pendingOperations(accountID: gmail.id, limit: 10).isEmpty
        }
        remote = try await provider.metadata(for: inboxIDs.map(\.providerID))
        XCTAssertTrue(remote.allSatisfy { $0.roles.contains(.inbox) })

        // A later bootstrap reflects the applied state too.
        try engine.perform(.setStarred(true), on: inboxIDs)
        try await waitUntil("star replayed") { try store.pendingOperations(accountID: gmail.id, limit: 10).isEmpty }
        let page = try await provider.bootstrap(page: nil, limit: 500)
        XCTAssertTrue(page.messages.filter { inboxIDs.contains($0.id) }.allSatisfy(\.isStarred))
        await engine.stopAndWait()
    }

    /// ! in demo mode: the made-up Outlook server files the mail in Junk Email, as Graph would, the next download leaves
    /// it out, and the undo's step brings it back to the Inbox folder.
    func testMarkAsSpamRoundTripFilesTheMailInJunkEmail() async throws {
        let service = DemoMailService(liveInterval: 3_600)
        let (engine, store, accounts) = try await seededEngine(service: service)
        let outlook = try XCTUnwrap(accounts.first { $0.kind == .microsoft })
        let provider = service.provider(for: outlook)
        let target = try XCTUnwrap(try store.conversations(ConversationQuery(accountIDs: [outlook.id], view: .inbox, limit: 1)).first)
        let ids = MailActionRecord.targets(for: .markSpam, in: try store.messages(in: target.id), kind: .microsoft).map(\.id)
        XCTAssertFalse(ids.isEmpty)

        try engine.perform(.markSpam, on: ids)
        XCTAssertFalse(try store.conversations(ConversationQuery(view: .all, limit: .max)).contains { $0.id == target.id })
        try await waitUntil("spam replayed to the provider") { try store.pendingOperations(accountID: outlook.id, limit: 10).isEmpty }
        let remote = try await provider.metadata(for: ids.map(\.providerID))
        XCTAssertTrue(remote.allSatisfy { $0.roles.contains(.spam) && $0.folderID == "junkemail" })
        let page = try await provider.bootstrap(page: nil, limit: 500)
        XCTAssertFalse(page.messages.contains { ids.contains($0.id) }, "a download leaves spam out")

        try engine.perform(.markNotSpam, on: ids)
        try await waitUntil("undo replayed") { try store.pendingOperations(accountID: outlook.id, limit: 10).isEmpty }
        let back = try await provider.metadata(for: ids.map(\.providerID))
        XCTAssertTrue(back.allSatisfy { $0.isInInbox && $0.folderID == "inbox" })
        XCTAssertTrue(try store.conversations(ConversationQuery(view: .inbox, limit: .max)).contains { $0.id == target.id })
        await engine.stopAndWait()
    }

    /// A relaunch builds a fresh mailbox over the same store. Acting on a conversation archived in an earlier
    /// run must not bring it back: the regenerated server state would otherwise overwrite the store.
    func testRelaunchKeepsEarlierRunsStateOnTheServer() async throws {
        let store = InMemoryMailStore()
        let firstReference = Date().addingTimeInterval(-3 * 86_400)
        let first = makeEngine(store: store, service: DemoMailService(
            reference: firstReference, liveInterval: 3_600, restore: { try? store.message($0) }
        ))
        first.start()
        let accounts = try await DemoSeeder.seedIfNeeded(first)
        for account in accounts {
            let expected = DemoProfile.profile(for: account.kind).messageCount
            try await waitUntil("bootstrap of \(account.email)", timeout: 15) {
                try store.syncCursor(for: account.id) != nil && self.messages(store, account: account.id).count == expected
            }
        }
        let outlook = try XCTUnwrap(accounts.first { $0.kind == .microsoft })
        let target = try XCTUnwrap(try store.conversations(ConversationQuery(accountIDs: [outlook.id], view: .inbox, limit: 1)).first)
        let dates = try store.messages(in: target.id).map(\.date)
        try first.perform(.archive, on: target.id)
        try await waitUntil("archive replayed") { try store.pendingOperations(accountID: outlook.id, limit: 10).isEmpty }
        await first.stopAndWait()

        // The relaunch: same store, new service laid out before a later "today".
        let second = makeEngine(store: store, service: DemoMailService(
            liveInterval: 3_600, restore: { try? store.message($0) }
        ))
        second.start()
        try second.perform(.setStarred(true), on: target.id)
        try await waitUntil("star replayed") { try store.pendingOperations(accountID: outlook.id, limit: 10).isEmpty }
        second.syncNow(accountID: outlook.id)
        // Give the poll that follows the replay time to land whatever the server now reports.
        try await Task.sleep(for: .milliseconds(600))

        let after = try store.messages(in: target.id)
        XCTAssertTrue(after.allSatisfy { !$0.isInInbox }, "archived conversation came back to the inbox after starring")
        XCTAssertTrue(after.allSatisfy(\.isStarred))
        XCTAssertEqual(after.map(\.date), dates)
        XCTAssertFalse(try store.conversations(ConversationQuery(view: .inbox, limit: .max)).contains { $0.id == target.id })
        await second.stopAndWait()
    }

    func testSentReplyAppearsInTheThread() async throws {
        let (engine, store, accounts) = try await seededEngine()
        let outlook = try XCTUnwrap(accounts.first { $0.kind == .microsoft })
        let conversation = try XCTUnwrap(try store.conversations(ConversationQuery(accountIDs: [outlook.id], view: .inbox, limit: 1)).first)
        let latest = try XCTUnwrap(try store.messages(in: conversation.id).last)
        let before = try store.messages(in: conversation.id).count

        let reply = OutgoingMessage(
            accountID: outlook.id,
            to: [try XCTUnwrap(latest.from)],
            subject: "Re: " + latest.subject,
            html: "<p>Sounds great, thank you!</p>",
            text: "Sounds great, thank you!",
            inReplyTo: latest.id,
            inReplyToInternetMessageID: latest.internetMessageID,
            references: latest.references + [latest.internetMessageID].compactMap { $0 }
        )
        _ = try engine.send(reply, undoWindow: 0)
        try await waitUntil("sent reply lands in the conversation", timeout: 10) {
            try store.messages(in: conversation.id).count == before + 1
        }
        let sent = try XCTUnwrap(try store.messages(in: conversation.id).last)
        XCTAssertTrue(sent.roles.contains(.sent))
        XCTAssertEqual(sent.from?.address, "alex@demo-outlook.test")
        XCTAssertEqual(sent.inReplyTo, latest.internetMessageID)
        XCTAssertTrue(try store.pendingSends().isEmpty)
        await engine.stopAndWait()
    }

    func testNewMailArrivesWhileRunning() async throws {
        let (engine, store, accounts) = try await seededEngine(service: DemoMailService(liveInterval: 0.3))
        let gmail = try XCTUnwrap(accounts.first { $0.kind == .gmail })
        try await waitUntil("a live message arrives", timeout: 10) {
            try store.conversations(ConversationQuery(accountIDs: [gmail.id], view: .inbox, limit: 5))
                .contains { $0.id.providerID.hasPrefix("live-thread-") && $0.unreadCount == 1 }
        }
        let live = try XCTUnwrap(try store.conversations(ConversationQuery(accountIDs: [gmail.id], view: .inbox, limit: 5))
            .first { $0.id.providerID.hasPrefix("live-thread-") })
        let body = try await engine.ensureBody(for: live.latestMessageID)
        XCTAssertFalse(body.plainText.isEmpty)
        await engine.stopAndWait()
    }

    /// Demo mode shows what a search of the server brings (spec §5.10): its archive is older mail the download never
    /// lists, and searching the server for it lands it in the store, searchable, with its body fetched on open.
    func testSearchingTheServerFindsTheArchiveTheDownloadNeverListed() async throws {
        let (engine, store, accounts) = try await seededEngine()
        let gmail = try XCTUnwrap(accounts.first { $0.kind == .gmail })
        let query = ConversationQuery(view: .all, searchText: "porto")
        XCTAssertTrue(try store.conversations(query).isEmpty, "nothing on this Mac mentions it")

        let result = try await engine.searchServer(for: "porto", accountIDs: nil)

        XCTAssertEqual(result.failedAccounts, [])
        XCTAssertGreaterThanOrEqual(result.downloaded, 1)
        let found = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(found.accountID, gmail.id)
        let messages = try store.messages(in: found)
        XCTAssertTrue(messages.allSatisfy { $0.subject.hasSuffix("Lisbon photos, finally") })
        XCTAssertTrue(messages.allSatisfy { !$0.isInInbox }, "archived mail, a year and more back")
        XCTAssertNil(try store.body(for: try XCTUnwrap(messages.last).id))
        let body = try await engine.ensureBody(for: try XCTUnwrap(messages.last).id)
        XCTAssertTrue(body.plainText.contains("Porto"))
        XCTAssertEqual(try store.conversations(query).map(\.id), [found], "the body's words are searchable once it is in")

        let again = try await engine.searchServer(for: "porto", accountIDs: nil)
        XCTAssertEqual(again.downloaded, 0, "found once, stored for good")
        await engine.stopAndWait()
    }

    // MARK: Provider contract without the engine

    func testMailboxIsDeterministicAndPagesWithoutGapsOrDuplicates() async throws {
        let reference = Date(timeIntervalSince1970: 1_790_000_000)
        let account = Account(id: AccountID("demo-a"), kind: .gmail, email: "", displayName: "", addedAt: reference)
        let first = DemoMailService(reference: reference, liveInterval: 3_600, now: { reference }).provider(for: account)
        let second = DemoMailService(reference: reference, liveInterval: 3_600, now: { reference }).provider(for: account)

        var collected: [MessageMetadata] = []
        var page: String?
        var cursor: String?
        repeat {
            let result = try await first.bootstrap(page: page, limit: 64)
            if page == nil { cursor = result.changeCursor }
            collected += result.messages
            page = result.nextPage
        } while page != nil
        XCTAssertNotNil(cursor)
        XCTAssertEqual(collected.count, DemoProfile.gmail.messageCount)
        XCTAssertEqual(Set(collected.map(\.id)).count, collected.count)
        XCTAssertEqual(collected.map(\.date), collected.map(\.date).sorted(by: >))
        XCTAssertTrue(collected.allSatisfy { $0.date <= reference })
        XCTAssertGreaterThan(reference.timeIntervalSince(collected.last!.date), 40 * 86_400)

        let again = try await second.bootstrap(page: nil, limit: 500)
        XCTAssertEqual(again.messages.map(\.id), collected.map(\.id))
        XCTAssertEqual(again.messages.map(\.subject), collected.map(\.subject))

        let empty = try await first.changes(since: try XCTUnwrap(cursor), limit: 100)
        XCTAssertTrue(empty.upserts.isEmpty)
        // A cursor from an earlier process is answered with nothing new rather than a reset.
        let stale = try await first.changes(since: "deadbeef:12", limit: 100)
        XCTAssertTrue(stale.upserts.isEmpty)
        XCTAssertFalse(stale.hasMore)

        let hits = try await first.search("Lisbon", limit: 10)
        XCTAssertFalse(hits.isEmpty)
        // The archive is searched like the rest and served by id, but no bootstrap page lists it.
        let archive = try await first.search("porto", limit: 10)
        XCTAssertEqual(archive.count, 1)
        XCTAssertFalse(collected.contains { archive.contains($0.id.providerID) })
        let archivedMetadata = try await first.metadata(for: archive)
        XCTAssertEqual(archivedMetadata.map(\.subject), ["Re: Lisbon photos, finally"])
        let archived = try await first.body(for: archive[0])
        XCTAssertTrue(archived.text?.contains("Porto") == true)
    }
}
