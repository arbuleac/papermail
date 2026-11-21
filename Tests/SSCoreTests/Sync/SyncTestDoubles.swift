import Foundation
import XCTest
@testable import SSCore

/// Foundation exports an `Operation` too; in these tests the name always means the outbox row.
typealias Operation = SSCore.Operation

final class SyncTestTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AccountID: OAuthTokens] = [:]
    private var refused: Set<AccountID> = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    /// Reads of these accounts' tokens fail as a keychain the user refused does.
    func refuseReads(of accountID: AccountID) {
        lock.lock(); defer { lock.unlock() }
        refused.insert(accountID)
    }

    func tokens(for accountID: AccountID) throws -> OAuthTokens? {
        lock.lock(); defer { lock.unlock() }
        if refused.contains(accountID) { throw AuthError.keychain(status: -25293) }
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

    private var replaced: [AccountID] = []
    private var removed: [AccountID] = []

    /// The accounts a sign-in stored new tokens for, in order.
    var replacements: [AccountID] {
        lock.lock(); defer { lock.unlock() }
        return replaced
    }

    /// The accounts whose tokens were removed with them, in order.
    var removals: [AccountID] {
        lock.lock(); defer { lock.unlock() }
        return removed
    }

    func removeTokens(for accountID: AccountID) async throws {
        recordRemoval(accountID)
    }

    private func recordRemoval(_ accountID: AccountID) {
        lock.lock(); defer { lock.unlock() }
        removed.append(accountID)
    }

    func replaceTokens(for accountID: AccountID, saving save: @Sendable () throws -> Void) async throws {
        try save()
        recordReplacement(accountID)
    }

    // Locking happens in a synchronous helper because NSLock may not be held across a suspension point.
    private func record(_ accountID: AccountID) {
        lock.lock(); defer { lock.unlock() }
        invalidated.append(accountID)
    }

    private func recordReplacement(_ accountID: AccountID) {
        lock.lock(); defer { lock.unlock() }
        replaced.append(accountID)
    }
}

final class StubAuthenticator: AccountAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [ProviderKind] = []
    var result: Result<OAuthTokens, Error> = .success(
        OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600), scope: nil)
    )

    private var hints: [String?] = []
    private var asked: [Set<AccountPermission>] = []

    /// The permissions each sign-in asked for beyond mail.
    var permissions: [Set<AccountPermission>] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    var signIns: [ProviderKind] {
        lock.lock(); defer { lock.unlock() }
        return kinds
    }

    var loginHints: [String?] {
        lock.lock(); defer { lock.unlock() }
        return hints
    }

    func signIn(kind: ProviderKind, loginHint: String?) async throws -> OAuthTokens {
        try recordSignIn(kind, loginHint: loginHint, permissions: []).get()
    }

    func signIn(kind: ProviderKind, loginHint: String?, permissions: Set<AccountPermission>) async throws -> OAuthTokens {
        try recordSignIn(kind, loginHint: loginHint, permissions: permissions).get()
    }

    private var askedTenants: [String?] = []

    /// The tenant each sign-in went through (nil: the configured one).
    var tenants: [String?] {
        lock.lock(); defer { lock.unlock() }
        return askedTenants
    }

    func signIn(kind: ProviderKind, loginHint: String?, permissions: Set<AccountPermission>, tenant: String?) async throws -> OAuthTokens {
        var tokens = try recordSignIn(kind, loginHint: loginHint, permissions: permissions).get()
        recordTenant(tenant)
        tokens.tenant = tenant
        return tokens
    }

    private func recordTenant(_ tenant: String?) {
        lock.lock(); defer { lock.unlock() }
        askedTenants.append(tenant)
    }

    private func recordSignIn(_ kind: ProviderKind, loginHint: String?, permissions: Set<AccountPermission>) -> Result<OAuthTokens, Error> {
        lock.lock(); defer { lock.unlock() }
        kinds.append(kind)
        hints.append(loginHint)
        asked.append(permissions)
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
        // Design facts that differ from SanitizedBody's "unknown" defaults, so a test can see them stored.
        return SanitizedBody(
            html: body.html ?? "", plainText: body.text ?? "", blockedRemoteImageCount: 0, hasQuotedContent: false,
            typesetting: body.html == nil ? .plain : .unstyled, declaresColors: false, coveredByNewYork: true
        )
    }
}

/// Collects every status delivery so tests can assert phases, ordering and the delivering thread.
final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latestStatuses: [AccountSyncStatus] = []
    private var phases: Set<AccountSyncPhase> = []
    private var calendars: Set<CalendarSyncState> = []
    private var rulesStates: Set<RulesSyncState> = []
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

    /// Every calendar state any delivery carried, for any account.
    var calendarsSeen: Set<CalendarSyncState> {
        lock.lock(); defer { lock.unlock() }
        return calendars
    }

    /// Every rules state any delivery carried, for any account.
    var rulesSeen: Set<RulesSyncState> {
        lock.lock(); defer { lock.unlock() }
        return rulesStates
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
        for status in statuses {
            phases.insert(status.phase)
            calendars.insert(status.calendar)
            rulesStates.insert(status.rules)
        }
        if !Thread.isMainThread { onMain = false }
    }
}

enum Fixtures {
    static let accountID = AccountID("11111111-1111-1111-1111-111111111111")
    static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func account(id: AccountID = accountID) -> Account {
        Account(id: id, kind: .gmail, email: "me@example.com", displayName: "Me", addedAt: baseDate)
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

    static func changes(upserts: [MessageMetadata] = [], deleted: [String] = [], cursor: String, hasMore: Bool = false,
                        requestCount: Int? = nil) -> ChangesPage {
        ChangesPage(upserts: upserts, deletedIDs: deleted, cursor: cursor, hasMore: hasMore, requestCount: requestCount)
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
///
/// The timeout is generous because a condition that holds returns at once, while a loaded machine can stall the
/// whole process for several seconds; the condition is asked once more after the deadline, since a stall that
/// outlasts it says nothing about whether the condition holds.
func waitUntil(
    _ description: String,
    timeout: TimeInterval = 30,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if try condition() { return }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
    throw WaitTimeout()
}

/// The gaps between consecutive times, in seconds.
func intervals(between times: [Date]) -> [TimeInterval] {
    zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
}

/// Every message the store holds for the test account, through the public query API.
func allMessages(_ store: MailStoring, account: AccountID = Fixtures.accountID) throws -> [MessageMetadata] {
    let summaries = try store.conversations(ConversationQuery(accountIDs: [account], view: .all, limit: .max))
    return try summaries.flatMap { try store.messages(in: $0.id) }
}

/// Builds an engine over in-memory doubles with short delays. By default one scripted provider serves every
/// account; a `factory` makes one per account instead. `engineStore` puts a wrapper (a `FaultyStore`) between the
/// engine and `store`, which tests still read directly. `maintenance` stands in for the SQLite store's housekeeping,
/// which the in-memory store has none of.
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
        engineStore: MailStoring? = nil,
        maintenance: MailStoreMaintenance? = nil,
        cacheDirectory: URL? = nil,
        cacheCapacity: Int64 = AttachmentCache.capacityBytes,
        tune: (inout SyncTuning) -> Void = { _ in },
        factory: (@Sendable (Account) -> ScriptedProvider)? = nil
    ) throws {
        self.store = store
        self.provider = provider
        var tuning = SyncTuning()
        // `activePollInterval` follows `pollInterval` down, so polls run every 0.15 s whether or not the engine
        // thinks the app is frontmost, unless a test sets it apart.
        tuning.pollInterval = 0.15
        tuning.backoffBase = 0.1
        tuning.backoffCap = 1
        // Nothing paced, so a test waits only for its own delays; tests about pacing set a metered quota.
        tuning.quota = { _ in .unlimited }
        tune(&tuning)
        self.cacheDirectory = cacheDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperSparrowSyncTests-\(UUID().uuidString)", isDirectory: true)
        if seedAccount {
            try store.upsertAccount(Fixtures.account(id: provider.accountID))
        }
        engine = MailEngine(
            store: engineStore ?? store,
            tokenStore: tokenStore,
            tokenProvider: tokenProvider,
            authenticator: authenticator,
            sanitizer: sanitizer,
            providerFactory: { account in factory?(account) ?? provider },
            tuning: tuning,
            attachmentCacheDirectory: self.cacheDirectory,
            attachmentCacheCapacity: cacheCapacity,
            maintenance: maintenance
        )
    }

    func shutdown() async {
        await engine.stopAndWait()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}
