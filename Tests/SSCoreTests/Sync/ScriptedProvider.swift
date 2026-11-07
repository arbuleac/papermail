import Foundation
@testable import SSCore

/// A `MailProvider` driven by scripts: bootstrap runs keyed by page token, a queue of change pages or errors,
/// bodies by id, and queues of apply/send results. Every call is recorded for assertions.
///
/// Backfill listings read the same bootstrap runs. By default they go through `bootstrap` and carry metadata
/// inline, as Graph's do; with `backfillIDsOnly` they return ids only, as Gmail's do, and the engine asks
/// `metadata(for:)`, which serves the scripted pages' messages (or `metadataByID`).
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
    /// Body fetches for these ids record the call and then wait until `releaseBody` removes them.
    var heldBodies: Set<String> = []
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
    /// Backfill listings return ids without metadata, like Gmail's `users.messages.list`.
    var backfillIDsOnly = false
    /// Metadata served by id ahead of the scripted pages' messages.
    var metadataByID: [String: MessageMetadata] = [:]
    /// Consumed in order, one per `metadata(for:)` call; once empty every call succeeds.
    var metadataResults: [Result<Void, Error>] = []
    /// Called (outside the lock) at the start of every backfill listing, with its page token.
    var onBackfillListing: (@Sendable (String) -> Void)?
    /// How long each `changes` call takes.
    var changesDelay: TimeInterval = 0
    /// While set, `changes` records the call and then waits until it is cleared (or the task is cancelled).
    var holdChanges = false
    private var heldApplies: [CheckedContinuation<Void, Never>] = []

    // MARK: Recordings

    // Read under the lock: tests poll these from their own task while the engine's lanes append to them, and an
    // unlocked read of an array being appended to is a data race (Thread Sanitizer reports it).
    var bootstrapCalls: [String?] { locked { recordedBootstrapCalls } }
    var backfillListingCalls: [(page: String, at: Date)] { locked { recordedBackfillListingCalls } }
    var metadataCalls: [[String]] { locked { recordedMetadataCalls } }
    var changesCalls: [(cursor: String, at: Date)] { locked { recordedChangesCalls } }
    var applyCalls: [(change: MetadataChange, ids: [String], at: Date)] { locked { recordedApplyCalls } }
    var sendCalls: [OutgoingMessage] { locked { recordedSendCalls } }
    var sendTimes: [Date] { locked { recordedSendTimes } }
    var bodyCalls: [String] { locked { recordedBodyCalls } }
    var attachmentCalls: [(message: String, attachment: String)] { locked { recordedAttachmentCalls } }
    var maxConcurrentBodyCalls: Int { locked { recordedMaxConcurrentBodyCalls } }

    private var recordedBootstrapCalls: [String?] = []
    private var recordedBackfillListingCalls: [(page: String, at: Date)] = []
    private var recordedMetadataCalls: [[String]] = []
    private var recordedChangesCalls: [(cursor: String, at: Date)] = []
    private var recordedApplyCalls: [(change: MetadataChange, ids: [String], at: Date)] = []
    private var recordedSendCalls: [OutgoingMessage] = []
    private var recordedSendTimes: [Date] = []
    private var recordedBodyCalls: [String] = []
    private var recordedAttachmentCalls: [(message: String, attachment: String)] = []
    private var recordedMaxConcurrentBodyCalls = 0
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

    func releaseChanges() {
        locked { holdChanges = false }
    }

    func releaseBody(_ providerID: String) {
        locked { _ = heldBodies.remove(providerID) }
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
            recordedBootstrapCalls.append(page)
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

    func backfillListing(page: String, limit: Int) async throws -> BackfillListing {
        let (hook, idsOnly) = locked {
            recordedBackfillListingCalls.append((page, Date()))
            return (onBackfillListing, backfillIDsOnly)
        }
        hook?(page)
        guard idsOnly else {
            let listed = try await bootstrap(page: page, limit: limit)
            return BackfillListing(ids: listed.messages.map(\.id.providerID), messages: listed.messages, nextPage: listed.nextPage)
        }
        let result: Result<BootstrapPage, Error>? = locked {
            guard bootstrapRunIndex < bootstrapRuns.count else { return nil }
            return bootstrapRuns[bootstrapRunIndex][page]
        }
        while locked({ gatedBootstrapPages.contains(page) }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let result else { throw ProviderError.notFound }
        let listed = try result.get()
        return BackfillListing(ids: listed.messages.map(\.id.providerID), messages: nil, nextPage: listed.nextPage)
    }

    func changes(since cursor: String, limit: Int) async throws -> ChangesPage {
        let delay: TimeInterval = locked {
            recordedChangesCalls.append((cursor, Date()))
            return changesDelay
        }
        while locked({ holdChanges }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        let result: Result<ChangesPage, Error> = locked {
            if changesQueue.isEmpty {
                return .success(ChangesPage(upserts: [], deletedIDs: [], cursor: cursor, hasMore: false))
            }
            return changesQueue.removeFirst()
        }
        return try result.get()
    }

    func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] {
        let result: Result<Void, Error> = locked {
            recordedMetadataCalls.append(providerIDs)
            return metadataResults.isEmpty ? .success(()) : metadataResults.removeFirst()
        }
        try result.get()
        return locked {
            providerIDs.compactMap { id in
                if let known = metadataByID[id] { return known }
                for run in bootstrapRuns {
                    for case .success(let page) in run.values {
                        if let message = page.messages.first(where: { $0.id.providerID == id }) { return message }
                    }
                }
                // Unknown ids are left out, not thrown, as the protocol says.
                return nil
            }
        }
    }

    func body(for providerID: String) async throws -> MessageBody {
        let delay: TimeInterval = locked {
            recordedBodyCalls.append(providerID)
            currentBodyCalls += 1
            recordedMaxConcurrentBodyCalls = max(recordedMaxConcurrentBodyCalls, currentBodyCalls)
            return bodyDelay
        }
        defer { locked { currentBodyCalls -= 1 } }
        while locked({ heldBodies.contains(providerID) }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        guard let result = locked({ bodies[providerID] }) else { throw ProviderError.notFound }
        return try result.get()
    }

    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        let data: Data? = locked {
            recordedAttachmentCalls.append((providerID, attachmentID))
            return attachments["\(providerID)/\(attachmentID)"]
        }
        guard let data else { throw ProviderError.notFound }
        return data
    }

    func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {
        let result: Result<Void, Error> = locked {
            recordedApplyCalls.append((change, providerIDs, Date()))
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
            recordedSendCalls.append(message)
            recordedSendTimes.append(Date())
            if sendResults.isEmpty {
                return .success(SendReceipt(providerMessageID: "sent-\(recordedSendCalls.count)", providerConversationID: nil))
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
