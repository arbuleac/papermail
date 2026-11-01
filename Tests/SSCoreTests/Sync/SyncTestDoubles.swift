import Foundation
import XCTest
@testable import SSCore

/// Foundation exports an `Operation` too; in these tests the name always means the outbox row.
typealias Operation = SSCore.Operation

final class SyncTestTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AccountID: OAuthTokens] = [:]

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    func tokens(for accountID: AccountID) throws -> OAuthTokens? {
        lock.lock(); defer { lock.unlock() }
        return storage[accountID]
    }

    func save(_ tokens: OAuthTokens, for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountID] = tokens
    }

    func delete(for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountID] = nil
    }
}

final class StubAccessTokenProvider: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated: [AccountID] = []

    var invalidations: [AccountID] {
        lock.lock(); defer { lock.unlock() }
        return invalidated
    }

    func accessToken(for accountID: AccountID) async throws -> String {
        "token"
    }

    func invalidateAccessToken(for accountID: AccountID) async {
        record(accountID)
    }

    // Locking happens in a synchronous helper because NSLock may not be held across a suspension point.
    private func record(_ accountID: AccountID) {
        lock.lock(); defer { lock.unlock() }
        invalidated.append(accountID)
    }
}

final class StubAuthenticator: AccountAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [ProviderKind] = []
    var result: Result<OAuthTokens, Error> = .success(
        OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600), scope: nil)
    )

    var signIns: [ProviderKind] {
        lock.lock(); defer { lock.unlock() }
        return kinds
    }

    func signIn(kind: ProviderKind) async throws -> OAuthTokens {
        try recordSignIn(kind).get()
    }

    private func recordSignIn(_ kind: ProviderKind) -> Result<OAuthTokens, Error> {
        lock.lock(); defer { lock.unlock() }
        kinds.append(kind)
        return result
    }
}

/// Passes the body through untouched and counts calls, so tests can show sanitizing happens exactly once.
final class RecordingSanitizer: BodySanitizing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func sanitize(_ body: MessageBody, messageID: MessageID) -> SanitizedBody {
        lock.lock()
        count += 1
        lock.unlock()
        return SanitizedBody(html: body.html ?? "", plainText: body.text ?? "", blockedRemoteImageCount: 0, hasQuotedContent: false)
    }
}

/// Collects every status delivery so tests can assert phases, ordering and the delivering thread.
final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latestStatuses: [AccountSyncStatus] = []
    private var phases: Set<AccountSyncPhase> = []
    private var count = 0
    private var onMain = true

    var latest: [AccountSyncStatus] {
        lock.lock(); defer { lock.unlock() }
        return latestStatuses
    }

    var seen: Set<AccountSyncPhase> {
        lock.lock(); defer { lock.unlock() }
        return phases
    }

    var deliveries: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    var allOnMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return onMain
    }

    func record(_ statuses: [AccountSyncStatus]) {
        lock.lock(); defer { lock.unlock() }
        latestStatuses = statuses
        count += 1
        for status in statuses { phases.insert(status.phase) }
        if !Thread.isMainThread { onMain = false }
    }
}

enum Fixtures {
    static let accountID = AccountID("11111111-1111-1111-1111-111111111111")
    static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func account(id: AccountID = accountID) -> Account {
        Account(id: id, kind: .gmail, email: "me@example.com", displayName: "Me", colorHex: "#4A90E2", addedAt: baseDate)
    }

    static func message(
        _ number: Int,
        account: AccountID = accountID,
        conversation: String = "t1",
        roles: Set<MailboxRole> = [.inbox],
        isRead: Bool = false,
        isStarred: Bool = false
    ) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account, providerID: "\(number)"),
            conversationID: ConversationID(accountID: account, providerID: conversation),
            subject: "Subject \(number)",
            snippet: "Snippet \(number)",
            from: EmailAddress(name: "Sender \(number)", address: "sender\(number)@example.com"),
            to: [EmailAddress(address: "me@example.com")],
            date: baseDate.addingTimeInterval(Double(number) * 60),
            roles: roles,
            isRead: isRead,
            isStarred: isStarred,
            hasAttachments: false
        )
    }

    static func page(_ numbers: ClosedRange<Int>, next: String?, cursor: String? = nil, account: AccountID = accountID) -> BootstrapPage {
        BootstrapPage(messages: numbers.map { message($0, account: account) }, nextPage: next, changeCursor: cursor)
    }

    static func changes(upserts: [MessageMetadata] = [], deleted: [String] = [], cursor: String, hasMore: Bool = false) -> ChangesPage {
        ChangesPage(upserts: upserts, deletedIDs: deleted, cursor: cursor, hasMore: hasMore)
    }

    static func outgoing(account: AccountID = accountID) -> OutgoingMessage {
        OutgoingMessage(
            accountID: account,
            to: [EmailAddress(address: "you@example.com")],
            subject: "Hello",
            html: "<p>Hi</p>",
            text: "Hi"
        )
    }
}

struct WaitTimeout: Error {}

/// Polls `condition` until it holds or the timeout passes; fails the test and throws on timeout.
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
    throw WaitTimeout()
}

/// Every message the store holds for the test account, through the public query API.
func allMessages(_ store: MailStoring, account: AccountID = Fixtures.accountID) throws -> [MessageMetadata] {
    let summaries = try store.conversations(ConversationQuery(accountIDs: [account], view: .all, limit: .max))
    return try summaries.flatMap { try store.messages(in: $0.id) }
}

/// Builds an engine over in-memory doubles with short delays. By default one scripted provider serves every
/// account; a `factory` makes one per account instead.
final class EngineHarness {
    let store: InMemoryMailStore
    let tokenStore = SyncTestTokenStore()
    let tokenProvider = StubAccessTokenProvider()
    let authenticator = StubAuthenticator()
    let sanitizer = RecordingSanitizer()
    let provider: ScriptedProvider
    let cacheDirectory: URL
    let engine: MailEngine

    init(
        store: InMemoryMailStore = InMemoryMailStore(),
        provider: ScriptedProvider = ScriptedProvider(accountID: Fixtures.accountID),
        seedAccount: Bool = true,
        tune: (inout SyncTuning) -> Void = { _ in },
        factory: (@Sendable (Account) -> ScriptedProvider)? = nil
    ) throws {
        self.store = store
        self.provider = provider
        var tuning = SyncTuning()
        tuning.pollInterval = 0.15
        tuning.backoffBase = 0.1
        tuning.backoffCap = 1
        tune(&tuning)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperSparrowSyncTests-\(UUID().uuidString)", isDirectory: true)
        if seedAccount {
            try store.upsertAccount(Fixtures.account(id: provider.accountID))
        }
        engine = MailEngine(
            store: store,
            tokenStore: tokenStore,
            tokenProvider: tokenProvider,
            authenticator: authenticator,
            sanitizer: sanitizer,
            providerFactory: { account in factory?(account) ?? provider },
            tuning: tuning,
            attachmentCacheDirectory: cacheDirectory
        )
    }

    func shutdown() async {
        await engine.stopAndWait()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}
