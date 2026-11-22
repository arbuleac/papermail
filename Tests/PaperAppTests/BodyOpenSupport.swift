import AppKit
import Foundation
import PaperCore
import XCTest
@testable import PaperApp

/// A provider whose bodies take `latency` to come back from a server that serves `serverConcurrency` requests at once
/// and queues the rest in order, as a mailbox's concurrency limit does. Every body call is recorded with when it reached
/// the provider (left the engine), when the server took it, and when it answered. Nothing reaches the network.
final class QueuedServerProvider: MailProvider, @unchecked Sendable {
    struct Call {
        let id: String
        let requested: TimeInterval
        var served: TimeInterval?
        var answered: TimeInterval?
        /// The transport priority the engine set around the call.
        let priority: ProviderRequestPriority
    }

    let accountID: AccountID
    let kind: ProviderKind
    let latency: TimeInterval
    let serverConcurrency: Int
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var busy = 0
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var heldIDs: Set<String> = []
    private let html: String

    /// Bodies whose answer waits, once the server has taken them, until `release` lets them go.
    func hold(_ ids: Set<String>) { lock.withLock { heldIDs.formUnion(ids) } }
    func release(_ id: String) { lock.withLock { _ = heldIDs.remove(id) } }
    /// The most body requests the server held at once, by the ids `matching` picks.
    func maxConcurrent(matching: (String) -> Bool) -> Int {
        var events: [(time: TimeInterval, delta: Int)] = []
        for call in calls where matching(call.id) {
            events.append((call.requested, 1))
            events.append((call.answered ?? .infinity, -1))
        }
        var current = 0
        var most = 0
        for event in events.sorted(by: { $0.time == $1.time ? $0.delta < $1.delta : $0.time < $1.time }) {
            current += event.delta
            most = max(most, current)
        }
        return most
    }

    init(accountID: AccountID, kind: ProviderKind, latency: TimeInterval, serverConcurrency: Int, bodyKilobytes: Int = 40) {
        self.accountID = accountID
        self.kind = kind
        self.latency = latency
        self.serverConcurrency = serverConcurrency
        let paragraph = "<p>Quarterly figures, the plan for the offsite, and the notes from Tuesday's review follow below.</p>\n"
        html = "<div>" + String(repeating: paragraph, count: max(1, bodyKilobytes * 1024 / paragraph.utf8.count)) + "</div>"
    }

    var calls: [Call] { lock.withLock { recorded } }

    func call(for id: String) -> Call? { calls.first { $0.id == id } }

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func body(for providerID: String) async throws -> MessageBody {
        let index: Int = lock.withLock {
            recorded.append(Call(id: providerID, requested: Self.now(), priority: ProviderRequestPriority.current))
            return recorded.count - 1
        }
        await takeServerPlace()
        lock.withLock { recorded[index].served = Self.now() }
        defer { leaveServer() }
        while lock.withLock({ heldIDs.contains(providerID) }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .seconds(latency))
        lock.withLock { recorded[index].answered = Self.now() }
        return MessageBody(html: html + "<p>\(providerID)</p>", text: nil)
    }

    private func takeServerPlace() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                guard busy < serverConcurrency else {
                    queue.append(continuation)
                    return false
                }
                busy += 1
                return true
            }
            if now { continuation.resume() }
        }
    }

    private func leaveServer() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !queue.isEmpty else {
                busy -= 1
                return nil
            }
            return queue.removeFirst()
        }
        next?.resume()
    }

    func profile() async throws -> AccountProfile { AccountProfile(email: "alex@contoso.test", displayName: "Alex") }
    func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        BootstrapPage(messages: [], nextPage: nil, changeCursor: "c")
    }
    func changes(since cursor: String, limit: Int) async throws -> ChangesPage {
        ChangesPage(upserts: [], deletedIDs: [], cursor: cursor, hasMore: false)
    }
    func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] { [] }
    func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {}
    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data { throw ProviderError.notFound }
    func send(_ message: OutgoingMessage) async throws -> SendReceipt { throw ProviderError.notFound }
    func search(_ text: String, limit: Int) async throws -> [String] { [] }
}

/// A Microsoft account on a store in a temporary folder (its quota lets the backfill keep two bodies on their way, and the
/// provider's server serves four at once, as Graph serves a mailbox), with a backlog of inbox mail without bodies (newest
/// first, ahead of everything else in the backfill's order) and some older conversations of several messages, none with
/// a body: what a reader meets while the first download is still fetching bodies.
@MainActor
final class BodyOpenFixture {
    static let account = Account(id: AccountID("acct-open"), kind: .microsoft, email: "alex@contoso.test", displayName: "Alex Morgan",
                                 addedAt: Date(timeIntervalSince1970: 0), inkSlot: 0)

    let folder: URL
    let store: SQLiteMailStore
    let provider: QueuedServerProvider
    let engine: MailEngine
    let reader: ConversationViewController
    let conversations: [ConversationID]

    init(backlog: Int = 300, conversations count: Int = 6, messagesEach: Int = 8,
         latency: TimeInterval = 0.12, serverConcurrency: Int = 4) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BodyOpen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try SQLiteMailStore(path: folder.appendingPathComponent("mail.sqlite").path)
        let account = Self.account
        try store.upsertAccount(account)
        try store.setSyncCursor("c", for: account.id)
        let now = Date()
        var messages: [MessageMetadata] = []
        for index in 0..<backlog {
            messages.append(Self.message("bg-\(index)", thread: "bg-\(index)", date: now.addingTimeInterval(-Double(index) * 60), read: true))
        }
        var threads: [ConversationID] = []
        for thread in 0..<count {
            let id = "open-\(thread)"
            threads.append(ConversationID(accountID: account.id, providerID: id))
            for part in 0..<messagesEach {
                // Older than the whole backlog, so the backfill would reach them last.
                let date = now.addingTimeInterval(-Double(backlog + thread * 100 + (messagesEach - part)) * 60)
                messages.append(Self.message("\(id)-\(part)", thread: id, date: date, read: true))
            }
        }
        try store.upsertMessages(messages)
        conversations = threads
        provider = QueuedServerProvider(accountID: account.id, kind: account.kind, latency: latency, serverConcurrency: serverConcurrency)
        let provider = provider
        engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                            authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                            attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        reader = ConversationViewController(client: engine)
        _ = reader.view
    }

    static func message(_ id: String, thread: String, date: Date, read: Bool) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account.id, providerID: id),
            conversationID: ConversationID(accountID: account.id, providerID: thread),
            subject: "Offsite plan", snippet: "Quarterly figures and the plan for the offsite",
            from: EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test"), to: [EmailAddress(address: account.email)],
            date: date, roles: [.inbox], isRead: read, isStarred: false, hasAttachments: false
        )
    }

    /// The conversation's newest message: the one the reader shows open.
    func newest(of conversation: ConversationID) -> MessageID {
        let messages = (try? store.messages(in: conversation)) ?? []
        return messages.max { $0.date < $1.date }!.id
    }

    /// Whether the slot on screen shows `conversation` rendered with `message`'s body.
    func shows(_ message: MessageID, of conversation: ConversationID) -> Bool {
        guard let slot = reader.pool.current else { return false }
        return slot.renderedID == conversation && !slot.renderInFlight && slot.pendingRender == nil
            && slot.renderedInputs?.hasBody(message) == true
    }

    /// Runs the main run loop in steps of a millisecond until `condition` holds; nil after `timeout`, else when it held.
    @discardableResult
    static func spin(until condition: () -> Bool, timeout: TimeInterval) -> TimeInterval? {
        let deadline = QueuedServerProvider.now() + timeout
        while !condition() {
            if QueuedServerProvider.now() > deadline { return nil }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        return QueuedServerProvider.now()
    }

    func close() {
        var finished = false
        let engine = engine
        Task { @MainActor in
            await engine.stopAndWait()
            finished = true
        }
        _ = Self.spin(until: { finished }, timeout: 10)
        try? store.close()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// One open, timed: from the show (the click) to the newest message's request reaching the provider, the server taking
/// it, its answer, and the reader showing its body.
struct BodyOpenTiming {
    let clicked: TimeInterval
    let requested: TimeInterval
    let served: TimeInterval
    let answered: TimeInterval
    let rendered: TimeInterval
    /// Background body requests that reached the provider after the click and before the newest message's answer.
    let backgroundSentMeanwhile: Int

    var clickToRequest: TimeInterval { requested - clicked }
    var waitAtServer: TimeInterval { served - requested }
    var answerToRendered: TimeInterval { rendered - answered }
    var clickToRendered: TimeInterval { rendered - clicked }

    static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func milliseconds(_ value: TimeInterval) -> String {
        String(format: "%.1f ms", value * 1000)
    }
}
