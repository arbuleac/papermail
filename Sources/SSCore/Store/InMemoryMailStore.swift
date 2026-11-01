import Foundation

/// Reference implementation of `MailStoring` kept entirely in memory.
///
/// It defines the semantics the SQLite store must match (conversation summaries, pending operations win,
/// view predicates) and backs engine and UI tests. Not optimized; do not use for real mailboxes.
public final class InMemoryMailStore: MailStoring, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var accountRows: [AccountID: Account] = [:]
    private var cursors: [AccountID: String] = [:]
    private var bootstraps: [AccountID: BootstrapState] = [:]
    private var messagesByID: [MessageID: MessageMetadata] = [:]
    private var bodies: [MessageID: StoredBody] = [:]
    private var operations: [String: Operation] = [:]
    private var sends: [String: PendingSend] = [:]
    private var contactCounts: [AccountID: [String: (name: String?, count: Int, lastSeen: Date)]] = [:]
    private var conversationObservers: [UUID: (ConversationQuery, ([ConversationSummary]) -> Void)] = [:]
    private var messageObservers: [UUID: (ConversationID, ([MessageMetadata]) -> Void)] = [:]

    public init() {}

    // MARK: Accounts

    public func accounts() throws -> [Account] {
        lock.lock(); defer { lock.unlock() }
        return accountRows.values.sorted { $0.addedAt < $1.addedAt }
    }

    public func upsertAccount(_ account: Account) throws {
        lock.lock(); defer { lock.unlock() }
        accountRows[account.id] = account
        notifyAll()
    }

    public func deleteAccount(_ id: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        accountRows[id] = nil
        wipeLocked(id)
        notifyAll()
    }

    // MARK: Sync state

    public func syncCursor(for accountID: AccountID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return cursors[accountID]
    }

    public func setSyncCursor(_ cursor: String?, for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        cursors[accountID] = cursor
    }

    public func bootstrapState(for accountID: AccountID) throws -> BootstrapState? {
        lock.lock(); defer { lock.unlock() }
        return bootstraps[accountID]
    }

    public func setBootstrapState(_ state: BootstrapState?, for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        bootstraps[accountID] = state
    }

    public func wipeMailData(for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        wipeLocked(accountID)
        notifyAll()
    }

    private func wipeLocked(_ accountID: AccountID) {
        messagesByID = messagesByID.filter { $0.key.accountID != accountID }
        bodies = bodies.filter { $0.key.accountID != accountID }
        operations = operations.filter { $0.value.accountID != accountID }
        sends = sends.filter { $0.value.message.accountID != accountID }
        cursors[accountID] = nil
        bootstraps[accountID] = nil
        contactCounts[accountID] = nil
    }

    // MARK: Messages

    public func upsertMessages(_ messages: [MessageMetadata]) throws {
        lock.lock(); defer { lock.unlock() }
        for incoming in messages {
            var metadata = incoming
            // Pending operations win: provider state older than a queued intent must not undo it.
            let pending = operations.values
                .filter { $0.targets.contains(incoming.id) && $0.status != .confirmed && $0.status != .failed }
                .sorted { $0.createdAt < $1.createdAt }
            for op in pending { metadata = applying(op.change, to: metadata) }
            messagesByID[incoming.id] = metadata
            recordContacts(of: metadata)
        }
        notifyAll()
    }

    public func deleteMessages(_ ids: [MessageID]) throws {
        lock.lock(); defer { lock.unlock() }
        for id in ids {
            messagesByID[id] = nil
            bodies[id] = nil
        }
        notifyAll()
    }

    public func message(_ id: MessageID) throws -> MessageMetadata? {
        lock.lock(); defer { lock.unlock() }
        return messagesByID[id]
    }

    public func messages(in conversation: ConversationID) throws -> [MessageMetadata] {
        lock.lock(); defer { lock.unlock() }
        return messagesLocked(in: conversation)
    }

    private func messagesLocked(in conversation: ConversationID) -> [MessageMetadata] {
        messagesByID.values
            .filter { $0.conversationID == conversation }
            .sorted { ($0.date, $0.id.providerID) < ($1.date, $1.id.providerID) }
    }

    public func saveBody(_ body: StoredBody, for id: MessageID) throws {
        lock.lock(); defer { lock.unlock() }
        bodies[id] = body
        notifyAll()
    }

    public func body(for id: MessageID) throws -> StoredBody? {
        lock.lock(); defer { lock.unlock() }
        return bodies[id]
    }

    public func messageIDsMissingBodies(accountID: AccountID, limit: Int) throws -> [MessageID] {
        lock.lock(); defer { lock.unlock() }
        return messagesByID.values
            .filter { $0.id.accountID == accountID && bodies[$0.id] == nil && !$0.roles.contains(.spam) }
            .sorted { lhs, rhs in
                if lhs.isInInbox != rhs.isInInbox { return lhs.isInInbox }
                return lhs.date > rhs.date
            }
            .prefix(limit)
            .map(\.id)
    }

    // MARK: Conversations

    public func conversations(_ query: ConversationQuery) throws -> [ConversationSummary] {
        lock.lock(); defer { lock.unlock() }
        return conversationsLocked(query)
    }

    private func conversationsLocked(_ query: ConversationQuery) -> [ConversationSummary] {
        var grouped: [ConversationID: [MessageMetadata]] = [:]
        for message in messagesByID.values {
            if let ids = query.accountIDs, !ids.contains(message.id.accountID) { continue }
            grouped[message.conversationID, default: []].append(message)
        }
        let search = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var result: [ConversationSummary] = []
        for (id, messages) in grouped {
            guard let summary = summarize(id: id, messages: messages) else { continue }
            guard matches(summary, view: query.view) else { continue }
            if let section = query.section, summary.inboxSection != section { continue }
            if query.unreadOnly, summary.unreadCount == 0 { continue }
            if let before = query.before, summary.latestDate >= before { continue }
            if !search.isEmpty {
                let haystack = ([summary.subject] + summary.participants.map { ($0.name ?? "") + " " + $0.address }
                    + messages.compactMap { bodies[$0.id]?.plainText }).joined(separator: " ").lowercased()
                guard haystack.contains(search) else { continue }
            }
            result.append(summary)
        }
        result.sort { ($0.latestDate, $0.id.providerID) > ($1.latestDate, $1.id.providerID) }
        return Array(result.prefix(query.limit))
    }

    private func matches(_ summary: ConversationSummary, view: MailboxView) -> Bool {
        switch view {
        case .inbox: return summary.inInbox
        case .starred: return summary.isStarred && !summaryIsTrash(summary)
        case .sent: return summaryFlags[summary.id]?.inSent == true && !summaryIsTrash(summary)
        case .drafts: return summaryFlags[summary.id]?.inDrafts == true && !summaryIsTrash(summary)
        case .trash: return summaryIsTrash(summary)
        case .all: return summary.messageCount > 0 && !summaryIsTrash(summary)
        }
    }

    private struct Flags { var inSent: Bool; var inDrafts: Bool; var inTrash: Bool }
    private var summaryFlags: [ConversationID: Flags] = [:]
    private func summaryIsTrash(_ summary: ConversationSummary) -> Bool { summaryFlags[summary.id]?.inTrash == true }

    /// The summary rules the SQLite store must reproduce. Returns nil for conversations with no messages.
    private func summarize(id: ConversationID, messages: [MessageMetadata]) -> ConversationSummary? {
        let nonSpam = messages.filter { !$0.roles.contains(.spam) }
        guard !nonSpam.isEmpty else { return nil }
        let sorted = nonSpam.sorted { ($0.date, $0.id.providerID) < ($1.date, $1.id.providerID) }
        let visible = sorted.filter { !$0.roles.contains(.trash) }
        let inTrash = visible.isEmpty
        let basis = visible.isEmpty ? sorted : visible
        let latest = basis.last!
        var participants: [EmailAddress] = []
        var seen: Set<String> = []
        for message in sorted {
            guard let from = message.from else { continue }
            let key = from.address.lowercased()
            if seen.insert(key).inserted { participants.append(from) }
        }
        let subject = sorted.first { !$0.subject.trimmingCharacters(in: .whitespaces).isEmpty }?.subject ?? ""
        let inboxMessages = basis.filter(\.isInInbox)
        let section: InboxSection = inboxMessages.contains { $0.inboxSection == .focused } ? .focused
            : inboxMessages.contains { $0.inboxSection == .other } ? .other : .unknown
        let pending = operations.values.contains { op in
            op.status != .confirmed && op.status != .failed && op.targets.contains { messagesByID[$0]?.conversationID == id }
        }
        summaryFlags[id] = Flags(
            inSent: basis.contains { $0.roles.contains(.sent) },
            inDrafts: basis.contains { $0.roles.contains(.drafts) },
            inTrash: inTrash
        )
        return ConversationSummary(
            id: id,
            subject: subject,
            snippet: latest.snippet,
            participants: participants,
            latestDate: latest.date,
            messageCount: visible.count,
            unreadCount: visible.filter { !$0.isRead }.count,
            isStarred: basis.contains(where: \.isStarred),
            hasAttachments: basis.contains(where: \.hasAttachments),
            inInbox: !inboxMessages.isEmpty,
            inboxSection: section,
            latestMessageID: latest.id,
            hasPendingOperations: pending
        )
    }

    public func observeConversations(_ query: ConversationQuery, onChange: @escaping @Sendable ([ConversationSummary]) -> Void) -> StoreObservation {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        conversationObservers[token] = (query, onChange)
        let current = conversationsLocked(query)
        deliver { onChange(current) }
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.conversationObservers[token] = nil
        }
    }

    public func observeConversation(_ id: ConversationID, onChange: @escaping @Sendable ([MessageMetadata]) -> Void) -> StoreObservation {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        messageObservers[token] = (id, onChange)
        let current = messagesLocked(in: id)
        deliver { onChange(current) }
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.messageObservers[token] = nil
        }
    }

    public func unreadInboxCount(accountIDs: [AccountID]?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return conversationsLocked(ConversationQuery(accountIDs: accountIDs, view: .inbox, limit: .max))
            .reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: Operations

    public func enqueue(_ operation: Operation) throws {
        lock.lock(); defer { lock.unlock() }
        for target in operation.targets {
            if let current = messagesByID[target] {
                messagesByID[target] = applying(operation.change, to: current)
            }
        }
        operations[operation.id] = operation
        notifyAll()
    }

    public func pendingOperations(accountID: AccountID, limit: Int) throws -> [Operation] {
        lock.lock(); defer { lock.unlock() }
        return operations.values
            .filter { $0.accountID == accountID && ($0.status == .pending || $0.status == .uncertain) }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    public func updateOperation(_ operation: Operation) throws {
        lock.lock(); defer { lock.unlock() }
        operations[operation.id] = operation
        notifyAll()
    }

    public func deleteOperation(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        operations[id] = nil
        notifyAll()
    }

    public func enqueueSend(_ send: PendingSend) throws {
        lock.lock(); defer { lock.unlock() }
        sends[send.id] = send
    }

    public func pendingSends() throws -> [PendingSend] {
        lock.lock(); defer { lock.unlock() }
        return sends.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func updateSend(_ send: PendingSend) throws {
        lock.lock(); defer { lock.unlock() }
        sends[send.id] = send
    }

    public func deleteSend(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        sends[id] = nil
    }

    // MARK: Contacts

    public func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress] {
        lock.lock(); defer { lock.unlock() }
        let needle = prefix.lowercased()
        var merged: [String: (name: String?, score: Double)] = [:]
        for (_, table) in contactCounts {
            for (address, entry) in table {
                let name = entry.name ?? ""
                guard needle.isEmpty || address.hasPrefix(needle) || name.lowercased().hasPrefix(needle)
                    || name.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(needle) }) else { continue }
                let ageDays = max(0, Date().timeIntervalSince(entry.lastSeen) / 86_400)
                let score = Double(entry.count) / (1 + ageDays / 30)
                if let existing = merged[address], existing.score >= score { continue }
                merged[address] = (entry.name, score)
            }
        }
        return merged.sorted { $0.value.score > $1.value.score }
            .prefix(limit)
            .map { EmailAddress(name: $0.value.name, address: $0.key) }
    }

    private func recordContacts(of message: MessageMetadata) {
        var table = contactCounts[message.id.accountID] ?? [:]
        for address in [message.from].compactMap({ $0 }) + message.to + message.cc {
            let key = address.address.lowercased()
            let current = table[key]
            table[key] = (
                name: address.name ?? current?.name,
                count: (current?.count ?? 0) + 1,
                lastSeen: max(current?.lastSeen ?? .distantPast, message.date)
            )
        }
        contactCounts[message.id.accountID] = table
    }

    // MARK: Observation delivery

    private func notifyAll() {
        let conversationSnapshot = conversationObservers.values.map { (query, callback) in
            (callback, conversationsLocked(query))
        }
        let messageSnapshot = messageObservers.values.map { (id, callback) in
            (callback, messagesLocked(in: id))
        }
        deliver {
            for (callback, value) in conversationSnapshot { callback(value) }
            for (callback, value) in messageSnapshot { callback(value) }
        }
    }

    private func deliver(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
