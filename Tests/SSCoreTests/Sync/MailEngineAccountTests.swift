import Foundation
import XCTest
@testable import SSCore

final class MailEngineAccountTests: XCTestCase {
    func testEnsureBodyFetchesSanitizesAndStoresOnce() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bodies["1"] = .success(MessageBody(html: "<b>hi</b>", text: "hi"))
        provider.bodyDelay = 0.05
        let harness = try EngineHarness(provider: provider)
        try harness.store.upsertMessages([Fixtures.message(1)])
        let id = MessageID(accountID: Fixtures.accountID, providerID: "1")

        // The engine is deliberately not started: on-demand fetches must not depend on the sync loop.
        async let first = harness.engine.ensureBody(for: id)
        async let second = harness.engine.ensureBody(for: id)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.renderedHTML, "<b>hi</b>")
        XCTAssertEqual(a.plainText, "hi")
        XCTAssertEqual(a.body.html, "<b>hi</b>")
        XCTAssertEqual(b, a)
        XCTAssertEqual(provider.bodyCalls, ["1"])
        XCTAssertEqual(harness.sanitizer.calls, 1)
        XCTAssertEqual(try harness.store.body(for: id), a)
        XCTAssertEqual(a.hasQuotedContent, false, "render facts are worked out once, at sync time")
        XCTAssertEqual(a.blockedRemoteImageCount, 0)
        XCTAssertEqual(a.typesetting, .unstyled, "and so are the design facts")
        XCTAssertEqual(a.declaresColors, false)
        XCTAssertEqual(a.coveredByNewYork, true)

        let third = try await harness.engine.ensureBody(for: id)
        XCTAssertEqual(third, a)
        XCTAssertEqual(provider.bodyCalls.count, 1)
        XCTAssertEqual(harness.sanitizer.calls, 1)
        await harness.shutdown()
    }

    func testEnsureBodyPropagatesProviderErrors() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        let harness = try EngineHarness(provider: provider)
        try harness.store.upsertMessages([Fixtures.message(1)])
        let id = MessageID(accountID: Fixtures.accountID, providerID: "1")
        do {
            _ = try await harness.engine.ensureBody(for: id)
            XCTFail("expected notFound")
        } catch ProviderError.notFound {
            // expected
        }
        XCTAssertNil(try harness.store.body(for: id))
        // A later call tries again rather than caching the failure.
        provider.bodies["1"] = .success(MessageBody(html: nil, text: "plain"))
        let stored = try await harness.engine.ensureBody(for: id)
        XCTAssertEqual(stored.plainText, "plain")
        await harness.shutdown()
    }

    func testAddAccountSignsInStoresTokensAndStartsSync() async throws {
        let harness = try EngineHarness(seedAccount: false, factory: { account in
            let provider = ScriptedProvider(accountID: account.id)
            provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0", account: account.id))]]
            return provider
        })
        harness.engine.start()

        let account = try await harness.engine.addAccount(kind: .gmail)
        XCTAssertEqual(account.email, "me@example.com")
        XCTAssertEqual(account.displayName, "Me")
        XCTAssertEqual(account.kind, .gmail)
        XCTAssertEqual(account.inkSlot, 0)
        XCTAssertNil(account.monogram)
        XCTAssertNotNil(UUID(uuidString: account.id.rawValue))
        XCTAssertEqual(harness.authenticator.signIns, [.gmail])
        XCTAssertEqual(try harness.tokenStore.tokens(for: account.id)?.accessToken, "access")
        XCTAssertEqual(try harness.engine.accounts(), [account])
        try await waitUntil("bootstrap after add") { try harness.store.syncCursor(for: account.id) == "c0" }
        XCTAssertEqual(try harness.store.message(MessageID(accountID: account.id, providerID: "1"))?.subject, "Subject 1")

        let second = try await harness.engine.addAccount(kind: .microsoft)
        XCTAssertNotEqual(second.id, account.id)
        XCTAssertEqual(second.inkSlot, 1)
        XCTAssertEqual(try harness.store.accounts().count, 2)

        try await harness.engine.removeAccount(account.id)
        XCTAssertNil(try harness.tokenStore.tokens(for: account.id))
        XCTAssertEqual(try harness.store.accounts().map(\.id), [second.id])
        XCTAssertNil(try harness.store.message(MessageID(accountID: account.id, providerID: "1")))

        // The next account takes the palette slot the removed one freed, not the one the remaining account wears.
        let third = try await harness.engine.addAccount(kind: .gmail)
        XCTAssertNotEqual(third.id, second.id)
        XCTAssertEqual(third.inkSlot, 0)
        XCTAssertEqual(try harness.store.accounts().map(\.inkSlot).sorted(), [0, 1])
        await harness.shutdown()
    }

    /// One address can be a personal Microsoft account and a work one: two mailboxes, so two accounts, each signing in
    /// again through its own tenant.
    func testAWorkAndAPersonalMicrosoftAccountWithOneAddressAreTwoAccounts() async throws {
        let harness = try EngineHarness(seedAccount: false, factory: { account in
            let provider = ScriptedProvider(accountID: account.id)
            provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0", account: account.id))]]
            return provider
        })
        let personal = try await harness.engine.addAccount(kind: .microsoft, tenant: "consumers")
        let work = try await harness.engine.addAccount(kind: .microsoft, tenant: "organizations")
        XCTAssertNotEqual(personal.id, work.id)
        XCTAssertEqual(personal.email, work.email)
        XCTAssertEqual(try harness.tokenStore.tokens(for: work.id)?.tenant, "organizations")
        XCTAssertEqual(try harness.tokenStore.tokens(for: personal.id)?.tenant, "consumers")

        // Adding the work account again is its reconnect, not a third account.
        let again = try await harness.engine.addAccount(kind: .microsoft, tenant: "organizations")
        XCTAssertEqual(again.id, work.id)
        XCTAssertEqual(try harness.store.accounts().count, 2)

        _ = try await harness.engine.reconnect(work)
        XCTAssertEqual(harness.authenticator.tenants.last ?? nil, "organizations", "a reconnect goes through the account's own tenant")
        await harness.shutdown()
    }

    func testAddingAnExistingAccountRefreshesItsTokensInstead() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider)
        harness.engine.start()
        let account = try await harness.engine.addAccount(kind: .gmail)
        XCTAssertEqual(account.id, Fixtures.accountID)
        XCTAssertEqual(try harness.store.accounts().count, 1)
        XCTAssertEqual(try harness.tokenStore.tokens(for: Fixtures.accountID)?.accessToken, "access")
        XCTAssertEqual(harness.tokenStore.count, 1)
        await harness.shutdown()
    }

    /// Reconnecting asks for the account's own mailbox, and a sign-in to another one is refused rather
    /// than silently added as a new account while the original stays signed out.
    func testReconnectSignsInWithHintAndRefusesAnotherMailbox() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider)
        let original = try XCTUnwrap(try harness.store.accounts().first)

        let reconnected = try await harness.engine.reconnect(original)
        XCTAssertEqual(reconnected.id, original.id)
        XCTAssertEqual(harness.authenticator.loginHints, [original.email])

        var stranger = original
        stranger.email = "someone-else@example.com"
        do {
            _ = try await harness.engine.reconnect(stranger)
            XCTFail("expected the mismatch to be refused")
        } catch AuthError.wrongAccount(let expected, let actual) {
            XCTAssertEqual(expected, "someone-else@example.com")
            XCTAssertEqual(actual, original.email)
        }
        XCTAssertEqual(try harness.store.accounts().count, 1)
        XCTAssertEqual(harness.tokenStore.count, 1, "the provisional tokens are dropped")
        await harness.shutdown()
    }

    /// Signing in again to an account that is already here, and Reconnect, read the provider's profile but leave the
    /// account row as the user set it: its signature (a local setting the provider never sees) and monogram stay.
    func testSigningInAgainKeepsTheSignatureAndMonogram() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider)
        let signature = "<div><p><b>Me</b></p></div>"
        try harness.store.setSignature(signature, for: Fixtures.accountID)
        try harness.store.setMonogram("Me", for: Fixtures.accountID)
        let original = try XCTUnwrap(try harness.store.accounts().first)

        let again = try await harness.engine.addAccount(kind: original.kind)
        XCTAssertEqual(again.id, original.id)
        XCTAssertEqual(again.signature, signature)
        _ = try await harness.engine.reconnect(original)

        let stored = try XCTUnwrap(try harness.store.accounts().first)
        XCTAssertEqual(try harness.store.accounts().count, 1)
        XCTAssertEqual(stored.signature, signature, "the signature is kept")
        XCTAssertEqual(stored.monogram, "Me", "as the monogram is")
        await harness.shutdown()
    }

    func testFailedSignInLeavesNothingBehind() async throws {
        let harness = try EngineHarness(seedAccount: false)
        harness.authenticator.result = .failure(AuthError.userCancelled)
        do {
            _ = try await harness.engine.addAccount(kind: .gmail)
            XCTFail("expected the sign-in error")
        } catch AuthError.userCancelled {
            // expected
        }
        XCTAssertEqual(harness.tokenStore.count, 0)
        XCTAssertTrue(try harness.store.accounts().isEmpty)
        await harness.shutdown()
    }

    func testObserveStatusDeliversOnMainThreadWithCurrentValueFirst() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider)
        let recorder = PhaseRecorder()
        let observation = harness.engine.observeStatus { recorder.record($0) }
        try await waitUntil("initial delivery") { recorder.deliveries >= 1 }
        XCTAssertEqual(recorder.latest, [])

        harness.engine.start()
        try await waitUntil("idle after a full cycle") {
            recorder.latest.first?.phase == .idle && recorder.latest.first?.lastSuccessfulSyncAt != nil
        }
        XCTAssertTrue(recorder.seen.isSuperset(of: [.bootstrapping, .syncing, .idle]), "saw \(recorder.seen)")
        XCTAssertTrue(recorder.allOnMain)
        XCTAssertEqual(recorder.latest.map(\.accountID), [Fixtures.accountID])

        await harness.shutdown()
        try await waitUntil("paused after stop") { recorder.latest.first?.phase == .paused }
        let deliveriesBeforeCancel = recorder.deliveries
        observation.cancel()
        harness.engine.syncNow(accountID: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.deliveries, deliveriesBeforeCancel)
    }

    func testAttachmentDataIsCachedOnDisk() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.attachments["1/att-1"] = Data("hello".utf8)
        let harness = try EngineHarness(provider: provider)
        let id = MessageID(accountID: Fixtures.accountID, providerID: "1")

        let first = try await harness.engine.attachmentData(for: id, attachmentID: "att-1")
        let second = try await harness.engine.attachmentData(for: id, attachmentID: "att-1")
        XCTAssertEqual(first, Data("hello".utf8))
        XCTAssertEqual(second, first)
        XCTAssertEqual(provider.attachmentCalls.count, 1)
        let path = harness.cacheDirectory
            .appendingPathComponent(Fixtures.accountID.rawValue)
            .appendingPathComponent("1")
            .appendingPathComponent("att-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        do {
            _ = try await harness.engine.attachmentData(for: id, attachmentID: "missing")
            XCTFail("expected notFound")
        } catch ProviderError.notFound {
            // expected
        }
        await harness.shutdown()
    }

    func testFetchesForUnknownAccountThrowNotFound() async throws {
        let harness = try EngineHarness(seedAccount: false)
        let id = MessageID(accountID: AccountID("missing"), providerID: "1")
        do {
            _ = try await harness.engine.ensureBody(for: id)
            XCTFail("expected StoreError.notFound")
        } catch StoreError.notFound {
            // expected
        }
        await harness.shutdown()
    }
}
