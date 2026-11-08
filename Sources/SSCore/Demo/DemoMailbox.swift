import Foundation

/// The server side of one demo account: the generated messages, every change applied to them, and an
/// append-only change log that `changes(since:)` pages through, the way Gmail history or Graph delta would.
///
/// Cursors are `<generation>:<log index>`. The generation is new for every process, so a cursor stored by an
/// earlier run is recognized and answered with "nothing new" from the current position instead of a reset,
/// which would wipe the user's demo mailbox on every launch.
final class DemoMailbox: @unchecked Sendable {
    let profile: DemoProfile
    let accountID: AccountID

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let liveInterval: TimeInterval
    private let generation = String(UUID().uuidString.prefix(8))
    private var records: [String: DemoRecord] = [:]
    /// Older mail only a search of the server finds (`DemoMailboxBuilder.buildArchive`): never in a bootstrap page,
    /// served by search, metadata and body like the rest, and changed by `apply` like the rest once found.
    private var archive: [String: DemoRecord] = [:]
    private var log: [String] = []
    private var lastLiveAt: Date
    private var liveCount = 0

    init(
        profile: DemoProfile,
        accountID: AccountID,
        reference: Date,
        liveInterval: TimeInterval,
        now: @escaping @Sendable () -> Date,
        restore: (@Sendable (MessageID) -> MessageMetadata?)? = nil
    ) {
        self.profile = profile
        self.accountID = accountID
        self.now = now
        self.liveInterval = liveInterval
        self.lastLiveAt = now()
        var builder = DemoMailboxBuilder(profile: profile, accountID: accountID, reference: reference)
        for var record in builder.build() {
            // A message an earlier run already delivered keeps the state the user left it in.
            if let stored = restore?(record.metadata.id), stored.id == record.metadata.id {
                record.metadata = stored
            }
            records[record.metadata.id.providerID] = record
        }
        for var record in builder.buildArchive() {
            // Found by an earlier run's search, it keeps the state the user left it in too.
            if let stored = restore?(record.metadata.id), stored.id == record.metadata.id {
                record.metadata = stored
            }
            archive[record.metadata.id.providerID] = record
        }
    }

    /// A message the server holds, whether the download lists it or only a search finds it.
    private func recordLocked(_ providerID: String) -> DemoRecord? {
        records[providerID] ?? archive[providerID]
    }

    private func storeLocked(_ record: DemoRecord) {
        let providerID = record.metadata.id.providerID
        if archive[providerID] != nil {
            archive[providerID] = record
        } else {
            records[providerID] = record
        }
    }

    // MARK: Reads

    var messageCount: Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }

    var currentCursor: String {
        lock.lock(); defer { lock.unlock() }
        return "\(generation):\(log.count)"
    }

    /// Newest first, excluding trash and spam, like the real providers' bootstrap.
    func bootstrapPage(offset: Int, limit: Int) -> (messages: [MessageMetadata], next: Int?) {
        lock.lock(); defer { lock.unlock() }
        let listed = records.values.map(\.metadata)
            .filter { !$0.roles.contains(.trash) && !$0.roles.contains(.spam) }
            .sorted { ($0.date, $0.id.providerID) > ($1.date, $1.id.providerID) }
        let start = min(max(0, offset), listed.count)
        let end = min(listed.count, start + max(1, limit))
        return (Array(listed[start..<end]), end < listed.count ? end : nil)
    }

    func changes(since cursor: String, limit: Int) -> ChangesPage {
        lock.lock(); defer { lock.unlock() }
        deliverDueLiveMessageLocked()
        let parts = cursor.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == generation, let start = Int(parts[1]), start <= log.count else {
            return ChangesPage(upserts: [], deletedIDs: [], cursor: "\(generation):\(log.count)", hasMore: false)
        }
        let end = min(log.count, start + max(1, limit))
        var seen = Set<String>()
        var upserts: [MessageMetadata] = []
        for providerID in log[start..<end] where seen.insert(providerID).inserted {
            if let record = recordLocked(providerID) { upserts.append(record.metadata) }
        }
        return ChangesPage(upserts: upserts, deletedIDs: [], cursor: "\(generation):\(end)", hasMore: end < log.count)
    }

    func metadata(for providerIDs: [String]) -> [MessageMetadata] {
        lock.lock(); defer { lock.unlock() }
        return providerIDs.compactMap { recordLocked($0)?.metadata }
    }

    func body(for providerID: String) -> MessageBody? {
        lock.lock(); defer { lock.unlock() }
        if let record = recordLocked(providerID) { return record.body }
        return Self.liveIndex(of: providerID).map {
            DemoMailboxBuilder.liveRecord(profile: profile, accountID: accountID, n: $0, providerID: providerID, date: now()).body
        }
    }

    func attachment(messageID providerID: String, attachmentID: String) -> Data? {
        lock.lock()
        let known = recordLocked(providerID)?.body.attachments.contains { $0.id == attachmentID } ?? false
        lock.unlock()
        guard known else { return nil }
        switch attachmentID {
        case DemoMailboxBuilder.photoAttachmentID: return DemoAssets.offsitePhotoPNG
        case DemoMailboxBuilder.invoiceAttachmentID: return DemoAssets.invoicePDF
        default: return nil
        }
    }

    func search(_ text: String, limit: Int) -> [String] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        // Like the real providers' search: everything but Trash and Spam, the archive the download never lists included.
        return (Array(records.values) + Array(archive.values))
            .filter { !$0.metadata.roles.contains(.trash) && !$0.metadata.roles.contains(.spam) }
            .filter { record in
                let m = record.metadata
                let haystack = [m.subject, m.snippet, m.from?.name ?? "", m.from?.address ?? "", record.body.text ?? ""]
                    .joined(separator: " ").lowercased()
                return haystack.contains(needle)
            }
            .map(\.metadata)
            .sorted { $0.date > $1.date }
            .prefix(max(0, limit))
            .map(\.id.providerID)
    }

    // MARK: Writes

    func apply(_ change: MetadataChange, to providerIDs: [String]) {
        lock.lock(); defer { lock.unlock() }
        for providerID in providerIDs {
            guard var record = recordLocked(providerID) else { continue }
            let updated = applying(change, to: record.metadata)
            guard updated != record.metadata else { continue }
            record.metadata = updated
            record.metadata.providerVersion = String((Int(record.metadata.providerVersion ?? "1") ?? 1) + 1)
            if profile.kind == .microsoft {
                record.metadata.folderID = updated.roles.contains(.trash) ? "deleteditems"
                    : updated.roles.contains(.inbox) ? "inbox" : (updated.roles.contains(.sent) ? "sentitems" : "archive")
            }
            storeLocked(record)
            log.append(providerID)
        }
    }

    func send(_ message: OutgoingMessage) -> SendReceipt {
        lock.lock(); defer { lock.unlock() }
        let providerID = "sent-" + UUID().uuidString.lowercased()
        var conversation = ConversationID(accountID: accountID, providerID: "thread-" + providerID)
        var references = message.references
        var inReplyTo = message.inReplyToInternetMessageID
        if let original = message.inReplyTo.flatMap({ recordLocked($0.providerID) }) {
            conversation = original.metadata.conversationID
            inReplyTo = inReplyTo ?? original.metadata.internetMessageID
            if references.isEmpty {
                references = original.metadata.references + [original.metadata.internetMessageID].compactMap { $0 }
            }
        }
        let snippet = message.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let metadata = MessageMetadata(
            id: MessageID(accountID: accountID, providerID: providerID),
            conversationID: conversation,
            internetMessageID: "<\(providerID)@mail.demo.test>",
            inReplyTo: inReplyTo,
            references: references,
            subject: message.subject,
            snippet: String(snippet.prefix(160)),
            from: profile.me,
            to: message.to,
            cc: message.cc,
            bcc: message.bcc,
            date: now(),
            roles: [.sent],
            isRead: true,
            isStarred: false,
            inboxSection: .unknown,
            hasAttachments: !message.attachments.isEmpty,
            labelIDs: profile.kind == .gmail ? ["SENT"] : [],
            folderID: profile.kind == .gmail ? nil : "sentitems",
            providerVersion: "1",
            sizeBytes: message.html.utf8.count + message.attachments.reduce(0) { $0 + $1.data.count }
        )
        let attachments = message.attachments.enumerated().map { index, attachment in
            AttachmentInfo(
                id: "sent-att-\(index)", filename: attachment.filename, mimeType: attachment.mimeType,
                sizeBytes: attachment.data.count, contentID: attachment.contentID, isInline: attachment.contentID != nil
            )
        }
        records[providerID] = DemoRecord(metadata: metadata, body: MessageBody(html: message.html, text: message.text, attachments: attachments))
        log.append(providerID)
        return SendReceipt(providerMessageID: providerID, providerConversationID: conversation.providerID)
    }

    // MARK: Live arrivals

    /// At most one new message per poll, so a long sleep does not flood the inbox on wake.
    private func deliverDueLiveMessageLocked() {
        let current = now()
        guard current.timeIntervalSince(lastLiveAt) >= liveInterval else { return }
        lastLiveAt = current
        let n = liveCount
        liveCount += 1
        let providerID = "live-\(Int(current.timeIntervalSince1970))-\(n)"
        records[providerID] = DemoMailboxBuilder.liveRecord(profile: profile, accountID: accountID, n: n, providerID: providerID, date: current)
        log.append(providerID)
    }

    private static func liveIndex(of providerID: String) -> Int? {
        guard providerID.hasPrefix("live-"), let last = providerID.split(separator: "-").last else { return nil }
        return Int(last)
    }
}
