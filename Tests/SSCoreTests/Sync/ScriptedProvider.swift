import Foundation
@testable import SSCore

/// A `MailProvider` driven by scripts: bootstrap runs keyed by page token, a queue of change pages or errors,
/// bodies by id, and queues of apply/send results. Every call is recorded for assertions.
///
/// Backfill listings read the same bootstrap runs. By default they go through `bootstrap` and carry metadata
/// inline, as Graph's do; with `backfillIDsOnly` they return ids only, as Gmail's do, and the engine asks
/// `metadata(for:)`, which serves the scripted pages' messages (or `metadataByID`).
///
/// Not final: `ScriptedCalendarProvider` gives it a calendar.
class ScriptedProvider: MailProvider, @unchecked Sendable {
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
    /// While set, `send` records the call and then waits until it is cleared (or the task is cancelled), as an
    /// upload of a large attachment does.
    var holdSends = false
    /// Keyed "<messageID>/<attachmentID>".
    var attachments: [String: Data] = [:]
    /// Downloads that fail with this error instead, keyed like `attachments`.
    var attachmentErrors: [String: Error] = [:]
    /// Fractions `downloadAttachment` reports before it writes the file, as a provider that streams does; it then
    /// reports 1 once the file is written. Empty: it reports nothing, as for a file of unknown size.
    var attachmentProgressSteps: [Double] = []
    /// While set, downloads report their steps, write the file (a streaming provider's bytes are on disk while it
    /// waits for the rest) and then wait until it is cleared (or the task is cancelled).
    var holdAttachmentDownloads = false
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
    /// Ids the provider refuses on their own (Graph's 403 for one message): left out of `metadata(for:)` like unknown
    /// ones, and reported as refused by `lookUpMetadata(for:)`.
    var refusedIDs: Set<String> {
        get { locked { scriptedRefused } }
        set { locked { scriptedRefused = newValue } }
    }
    private var scriptedRefused: Set<String> = []
    /// Ids whose metadata the service fails for now (a Gmail 500 for one message): left out of `metadata(for:)`, and
    /// reported as failing by `lookUpMetadata(for:)`. A test clears it to let them through.
    var failingIDs: Set<String> {
        get { locked { scriptedFailing } }
        set { locked { scriptedFailing = newValue } }
    }
    private var scriptedFailing: Set<String> = []
    /// The pages `mailOutsideEnumeration` lists (Gmail's Trash and Spam), chained by their index as the page token; nil
    /// for an enumeration that leaves nothing the store holds out.
    var outsideEnumerationPages: [[String]]? {
        get { locked { scriptedOutsidePages } }
        set { locked { scriptedOutsidePages = newValue } }
    }
    private var scriptedOutsidePages: [[String]]?
    /// The page tokens `mailOutsideEnumeration` was asked for.
    var outsideEnumerationCalls: [String?] { locked { recordedOutsideCalls } }
    private var recordedOutsideCalls: [String?] = []
    /// Called (outside the lock) at the start of every backfill listing, with its page token.
    var onBackfillListing: (@Sendable (String) -> Void)?
    /// How long each `changes` call takes.
    var changesDelay: TimeInterval = 0
    /// While set, `changes` records the call and then waits until it is cleared (or the task is cancelled).
    var holdChanges = false
    /// What `search` answers, consumed in order; once empty it finds nothing.
    var searchResults: [Result<[String], Error>] = []
    /// While set, `search` records the call and then waits until it is cleared (or the task is cancelled).
    var holdSearch = false
    /// The permission an invitation answer waits for, as a provider whose token lacks the scope reports it.
    var permissionNeeded: AccountPermission? {
        get { locked { scriptedPermission } }
        set { locked { scriptedPermission = newValue } }
    }
    private var scriptedPermission: AccountPermission?
    /// When set, the permission is granted once this many checks have been answered: a reconnect landing mid-drain.
    var permissionGrantedAfterChecks: Int? {
        get { locked { scriptedGrantAfter } }
        set { locked { scriptedGrantAfter = newValue } }
    }
    private var scriptedGrantAfter: Int?
    /// How often the runner asked whether a change may go out.
    var permissionChecks: Int { locked { recordedPermissionChecks } }
    private var recordedPermissionChecks = 0
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
    /// Every body call's start ("start:<id>") and answer ("end:<id>", success or not), in the order they happened, so a
    /// test can see what went out while another body was on its way.
    var bodyEvents: [String] { locked { recordedBodyEvents } }
    /// The transport priority the engine set around each body call, by id (`ProviderRequestPriority.current`).
    var bodyPriorities: [String: ProviderRequestPriority] { locked { recordedBodyPriorities } }
    var attachmentCalls: [(message: String, attachment: String)] { locked { recordedAttachmentCalls } }
    /// The `expectedSize` each download was given.
    var attachmentExpectedSizes: [Int] { locked { recordedAttachmentExpectedSizes } }
    var maxConcurrentBodyCalls: Int { locked { recordedMaxConcurrentBodyCalls } }
    var searchCalls: [(text: String, limit: Int)] { locked { recordedSearchCalls } }

    private var recordedBootstrapCalls: [String?] = []
    private var recordedBackfillListingCalls: [(page: String, at: Date)] = []
    private var recordedMetadataCalls: [[String]] = []
    private var recordedChangesCalls: [(cursor: String, at: Date)] = []
    private var recordedApplyCalls: [(change: MetadataChange, ids: [String], at: Date)] = []
    private var recordedSendCalls: [OutgoingMessage] = []
    private var recordedSendTimes: [Date] = []
    private var recordedBodyCalls: [String] = []
    private var recordedBodyEvents: [String] = []
    private var recordedBodyPriorities: [String: ProviderRequestPriority] = [:]
    private var recordedAttachmentCalls: [(message: String, attachment: String)] = []
    private var recordedAttachmentExpectedSizes: [Int] = []
    private var recordedMaxConcurrentBodyCalls = 0
    private var recordedSearchCalls: [(text: String, limit: Int)] = []
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
                if scriptedRefused.contains(id) || scriptedFailing.contains(id) { return nil }
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

    var hasMailOutsideEnumeration: Bool { outsideEnumerationPages != nil }

    func mailOutsideEnumeration(page: String?, limit: Int) async throws -> BackfillListing {
        let pages: [[String]] = locked {
            recordedOutsideCalls.append(page)
            return scriptedOutsidePages ?? []
        }
        let index = page.flatMap { Int($0) } ?? 0
        guard pages.indices.contains(index) else { return BackfillListing(ids: [], messages: nil, nextPage: nil) }
        return BackfillListing(ids: pages[index], messages: nil, nextPage: index + 1 < pages.count ? String(index + 1) : nil)
    }

    func lookUpMetadata(for providerIDs: [String]) async throws -> MetadataLookup {
        let (refused, failing) = locked { (providerIDs.filter(scriptedRefused.contains), providerIDs.filter(scriptedFailing.contains)) }
        let messages = try await metadata(for: providerIDs)
        return MetadataLookup(messages: messages, refused: refused, failing: failing)
    }

    func body(for providerID: String) async throws -> MessageBody {
        let delay: TimeInterval = locked {
            recordedBodyCalls.append(providerID)
            recordedBodyEvents.append("start:\(providerID)")
            recordedBodyPriorities[providerID] = ProviderRequestPriority.current
            currentBodyCalls += 1
            recordedMaxConcurrentBodyCalls = max(recordedMaxConcurrentBodyCalls, currentBodyCalls)
            return bodyDelay
        }
        defer {
            locked {
                currentBodyCalls -= 1
                recordedBodyEvents.append("end:\(providerID)")
            }
        }
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

    func downloadAttachment(messageID providerID: String, attachmentID: String, expectedSize: Int, to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let (data, steps, failure): (Data?, [Double], Error?) = locked {
            recordedAttachmentCalls.append((providerID, attachmentID))
            recordedAttachmentExpectedSizes.append(expectedSize)
            let key = "\(providerID)/\(attachmentID)"
            return (attachments[key], attachmentProgressSteps, attachmentErrors[key])
        }
        if let failure { throw failure }
        for step in steps { progress(step) }
        guard let data else { throw ProviderError.notFound }
        try data.write(to: destination)
        do {
            while locked({ holdAttachmentDownloads }) {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        if !steps.isEmpty { progress(1) }
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

    func missingPermission(for change: MetadataChange) async -> AccountPermission? {
        locked {
            recordedPermissionChecks += 1
            guard case .answerInvitation = change else { return nil }
            if let after = scriptedGrantAfter, recordedPermissionChecks > after { return nil }
            return scriptedPermission
        }
    }

    func send(_ message: OutgoingMessage) async throws -> SendReceipt {
        locked {
            recordedSendCalls.append(message)
            recordedSendTimes.append(Date())
        }
        while locked({ holdSends }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        // As URLSession does, which refuses a request made from a cancelled task.
        try Task.checkCancellation()
        let result: Result<SendReceipt, Error> = locked {
            if sendResults.isEmpty {
                return .success(SendReceipt(providerMessageID: "sent-\(recordedSendCalls.count)", providerConversationID: nil))
            }
            return sendResults.removeFirst()
        }
        return try result.get()
    }

    func search(_ text: String, limit: Int) async throws -> [String] {
        locked { recordedSearchCalls.append((text, limit)) }
        while locked({ holdSearch }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        // As URLSession does, which refuses a request made from a cancelled task.
        try Task.checkCancellation()
        let result: Result<[String], Error> = locked { searchResults.isEmpty ? .success([]) : searchResults.removeFirst() }
        return try result.get()
    }

    func releaseSearch() {
        locked { holdSearch = false }
    }

    // MARK: Locking

    @discardableResult
    func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
