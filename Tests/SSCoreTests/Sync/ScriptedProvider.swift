import Foundation
@testable import SSCore

/// A `MailProvider` driven by scripts: bootstrap runs keyed by page token, a queue of change pages or errors,
/// bodies by id, and queues of apply/send results. Every call is recorded for assertions.
final class ScriptedProvider: MailProvider, @unchecked Sendable {
    let accountID: AccountID
    let kind: ProviderKind
    private let lock = NSRecursiveLock()

    // MARK: Scripts

    var profileResult: Result<AccountProfile, Error> = .success(AccountProfile(email: "me@example.com", displayName: "Me"))
    /// One dictionary per enumeration; "" keys the first page. A new run begins each time page nil is asked
    /// for after a run has already started, which is what happens after a reset.
    var bootstrapRuns: [[String: Result<BootstrapPage, Error>]] = []
    var changesQueue: [Result<ChangesPage, Error>] = []
    var bodies: [String: Result<MessageBody, Error>] = [:]
    var bodyDelay: TimeInterval = 0
    /// Consumed in order; once empty every apply succeeds.
    var applyResults: [Result<Void, Error>] = []
    /// Consumed in order; once empty every send succeeds.
    var sendResults: [Result<SendReceipt, Error>] = []
    /// Keyed "<messageID>/<attachmentID>".
    var attachments: [String: Data] = [:]
    /// Bootstrap page tokens ("" for the first page) that block until `openGate` removes them.
    var gatedBootstrapPages: Set<String> = []
    /// While set, `apply` records the call and then never returns, not even on cancellation: the request a
    /// process that died mid-apply would never see answered. `releaseHeldApplies` lets the callers go.
    var holdApplies = false
    private var heldApplies: [CheckedContinuation<Void, Never>] = []

    // MARK: Recordings

    private(set) var bootstrapCalls: [String?] = []
    private(set) var changesCalls: [(cursor: String, at: Date)] = []
    private(set) var applyCalls: [(change: MetadataChange, ids: [String], at: Date)] = []
    private(set) var sendCalls: [OutgoingMessage] = []
    private(set) var sendTimes: [Date] = []
    private(set) var bodyCalls: [String] = []
    private(set) var attachmentCalls: [(message: String, attachment: String)] = []
    private(set) var maxConcurrentBodyCalls = 0
    private var currentBodyCalls = 0
    private var bootstrapRunIndex = 0
    private var bootstrapRunStarted = false

    init(accountID: AccountID, kind: ProviderKind = .gmail) {
        self.accountID = accountID
        self.kind = kind
    }

    func openGate(_ page: String) {
        locked { _ = gatedBootstrapPages.remove(page) }
    }

    func enqueueChanges(_ result: Result<ChangesPage, Error>) {
        locked { changesQueue.append(result) }
    }

    func releaseHeldApplies() {
        let waiting: [CheckedContinuation<Void, Never>] = locked {
            holdApplies = false
            defer { heldApplies = [] }
            return heldApplies
        }
        for continuation in waiting { continuation.resume() }
    }

    // MARK: MailProvider

    func profile() async throws -> AccountProfile {
        try locked { profileResult }.get()
    }

    func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        let key = page ?? ""
        let result: Result<BootstrapPage, Error>? = locked {
            bootstrapCalls.append(page)
            if page == nil {
                if bootstrapRunStarted { bootstrapRunIndex += 1 }
                bootstrapRunStarted = true
            }
            guard bootstrapRunIndex < bootstrapRuns.count else { return nil }
            return bootstrapRuns[bootstrapRunIndex][key]
        }
        while locked({ gatedBootstrapPages.contains(key) }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let result else { throw ProviderError.notFound }
        return try result.get()
    }

    func changes(since cursor: String, limit: Int) async throws -> ChangesPage {
        let result: Result<ChangesPage, Error> = locked {
            changesCalls.append((cursor, Date()))
            if changesQueue.isEmpty {
                return .success(ChangesPage(upserts: [], deletedIDs: [], cursor: cursor, hasMore: false))
            }
            return changesQueue.removeFirst()
        }
        return try result.get()
    }

    func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] {
        []
    }

    func body(for providerID: String) async throws -> MessageBody {
        let delay: TimeInterval = locked {
            bodyCalls.append(providerID)
            currentBodyCalls += 1
            maxConcurrentBodyCalls = max(maxConcurrentBodyCalls, currentBodyCalls)
            return bodyDelay
        }
        defer { locked { currentBodyCalls -= 1 } }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        guard let result = locked({ bodies[providerID] }) else { throw ProviderError.notFound }
        return try result.get()
    }

    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        let data: Data? = locked {
            attachmentCalls.append((providerID, attachmentID))
            return attachments["\(providerID)/\(attachmentID)"]
        }
        guard let data else { throw ProviderError.notFound }
        return data
    }

    func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {
        let result: Result<Void, Error> = locked {
            applyCalls.append((change, providerIDs, Date()))
            return applyResults.isEmpty ? .success(()) : applyResults.removeFirst()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            locked {
                if holdApplies {
                    heldApplies.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
        try result.get()
    }

    func send(_ message: OutgoingMessage) async throws -> SendReceipt {
        let result: Result<SendReceipt, Error> = locked {
            sendCalls.append(message)
            sendTimes.append(Date())
            if sendResults.isEmpty {
                return .success(SendReceipt(providerMessageID: "sent-\(sendCalls.count)", providerConversationID: nil))
            }
            return sendResults.removeFirst()
        }
        return try result.get()
    }

    func search(_ text: String, limit: Int) async throws -> [String] {
        []
    }

    // MARK: Locking

    @discardableResult
    func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
