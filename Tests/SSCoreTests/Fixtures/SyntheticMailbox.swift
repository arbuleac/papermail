import Foundation
import SSCore

/// A deterministic mailbox for store, engine and performance tests: the same seed always yields the same
/// accounts, threads, senders, dates and flags, so assertions and timings are reproducible.
///
/// Threads have 2 to 8 messages spread over the two years before `Options.now`, senders come from a fixed
/// pool of contacts, about 30 percent of received mail is unread, 5 percent starred, and a few threads sit
/// in trash or spam. With `graphFolderCount` set, a Microsoft account's archived mail is filed in that many folders of
/// its own, a thread to a folder, as a Graph mailbox sorted by client and year is.
public struct SyntheticMailbox: Sendable {
    public struct Options: Sendable {
        public var seed: UInt64 = 42
        public var accountCount: Int = 2
        public var messageCount: Int = 1_000
        /// Every date is generated relative to this instant so a run on another day produces the same rows.
        public var now = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        public var unreadFraction = 0.30
        public var starredFraction = 0.05
        public var trashFraction = 0.03
        public var spamFraction = 0.02
        public var draftFraction = 0.02
        public var attachmentFraction = 0.10
        public var focusedFraction = 0.60
        /// Folders a Microsoft account files its archived mail in (`MessageMetadata.folderID` "folder-000" onwards);
        /// 0 leaves it in no folder, as before. Chosen from the thread's index, so the rest of the mailbox is the same.
        public var graphFolderCount = 0
        public init() {}
    }

    public let options: Options
    public let accounts: [Account]
    /// Every message, grouped by thread and ordered oldest first within a thread.
    public let messages: [MessageMetadata]
    /// The contact pool senders and recipients are drawn from.
    public let contacts: [EmailAddress]

    public init(seed: UInt64 = 42, accountCount: Int = 2, messageCount: Int = 1_000, graphFolderCount: Int = 0) {
        var options = Options()
        options.seed = seed
        options.accountCount = accountCount
        options.messageCount = messageCount
        options.graphFolderCount = graphFolderCount
        self.init(options: options)
    }

    /// The custom folders the Microsoft accounts file archived mail in, as `graphFolderCount` names them.
    public var graphFolderIDs: [String] {
        (0..<options.graphFolderCount).map(Self.graphFolderID)
    }

    private static func graphFolderID(_ index: Int) -> String {
        String(format: "folder-%03d", index)
    }

    public init(options: Options) {
        self.options = options
        var generator = SeededGenerator(seed: options.seed)
        let contacts = Self.makeContacts(count: 240, using: &generator)
        let accounts = Self.makeAccounts(count: options.accountCount, now: options.now)
        var messages: [MessageMetadata] = []
        messages.reserveCapacity(options.messageCount)
        var threadIndex = 0
        while messages.count < options.messageCount {
            let remaining = options.messageCount - messages.count
            let size = min(remaining, Int.random(in: 2...8, using: &generator))
            let account = accounts[threadIndex % accounts.count]
            messages += Self.makeThread(
                index: threadIndex,
                size: size,
                account: account,
                contacts: contacts,
                options: options,
                firstMessageIndex: messages.count,
                using: &generator
            )
            threadIndex += 1
        }
        self.contacts = contacts
        self.accounts = accounts
        self.messages = messages
    }

    public func messages(for accountID: AccountID) -> [MessageMetadata] {
        messages.filter { $0.id.accountID == accountID }
    }

    /// Splits the messages into upsert batches of `size`, the way the sync engine stores pages.
    public func batches(of size: Int) -> [[MessageMetadata]] {
        stride(from: 0, to: messages.count, by: size).map { Array(messages[$0..<min($0 + size, messages.count)]) }
    }

    /// A deterministic body whose text mentions the subject and sender, so full-text tests can find it.
    public func body(for message: MessageMetadata) -> StoredBody {
        let ordinal = UInt64(message.id.providerID.dropFirst()) ?? 0
        var generator = SeededGenerator(seed: options.seed ^ (ordinal &* 0x9E37_79B9))
        let wordCount = Int.random(in: 40...160, using: &generator)
        var words: [String] = []
        words.reserveCapacity(wordCount)
        for _ in 0..<wordCount {
            words.append(Self.bodyWords[Int.random(in: 0..<Self.bodyWords.count, using: &generator)])
        }
        let sender = message.from?.shortDisplay ?? "someone"
        let text = "\(message.subject)\n\n\(words.joined(separator: " ")).\n\nRegards,\n\(sender)"
        let paragraphs = text.split(separator: "\n\n").map { "<p>\($0)</p>" }.joined()
        let html = "<html><body>\(paragraphs)</body></html>"
        return StoredBody(
            body: MessageBody(html: html, text: text, attachments: []),
            renderedHTML: "<div class=\"ss-body\">\(paragraphs)</div>",
            plainText: text
        )
    }

    // MARK: Generation

    private static func makeAccounts(count: Int, now: Date) -> [Account] {
        (0..<count).map { index in
            let kind: ProviderKind = index.isMultiple(of: 2) ? .gmail : .microsoft
            let domain = kind == .gmail ? "gmail.com" : "outlook.com"
            return Account(
                id: AccountID("account-\(index)"),
                kind: kind,
                email: "owner\(index)@\(domain)",
                displayName: "Owner \(index)",
                addedAt: now.addingTimeInterval(-Double(index + 1) * 86_400),
                inkSlot: index % AccountInkSlot.count
            )
        }
    }

    private static func makeContacts(count: Int, using generator: inout SeededGenerator) -> [EmailAddress] {
        var contacts: [EmailAddress] = []
        var seen: Set<String> = []
        while contacts.count < count {
            let first = firstNames[Int.random(in: 0..<firstNames.count, using: &generator)]
            let last = lastNames[Int.random(in: 0..<lastNames.count, using: &generator)]
            let domain = domains[Int.random(in: 0..<domains.count, using: &generator)]
            let address = "\(first).\(last)@\(domain)".lowercased()
            guard seen.insert(address).inserted else { continue }
            // One in ten contacts has no display name, like real headers.
            let name = Int.random(in: 0..<10, using: &generator) == 0 ? nil : "\(first) \(last)"
            contacts.append(EmailAddress(name: name, address: address))
        }
        return contacts
    }

    private static func makeThread(
        index: Int,
        size: Int,
        account: Account,
        contacts: [EmailAddress],
        options: Options,
        firstMessageIndex: Int,
        using generator: inout SeededGenerator
    ) -> [MessageMetadata] {
        let owner = EmailAddress(name: account.displayName, address: account.email)
        let participantCount = Int.random(in: 1...3, using: &generator)
        let others = (0..<participantCount).map { _ in contacts[Int.random(in: 0..<contacts.count, using: &generator)] }
        let subject = subjects[Int.random(in: 0..<subjects.count, using: &generator)]
        let kind = Double.random(in: 0..<1, using: &generator)
        let trashed = kind < options.trashFraction
        let spam = !trashed && kind < options.trashFraction + options.spamFraction
        let endsWithDraft = !trashed && !spam && Double.random(in: 0..<1, using: &generator) < options.draftFraction
        let threadID = "t\(index)"
        let twoYears: Int64 = 2 * 365 * 86_400_000
        var dateMs = MailboxClock.milliseconds(options.now) - Int64.random(in: 0..<twoYears, using: &generator)
        var references: [String] = []
        var previousInternetID: String?
        var thread: [MessageMetadata] = []
        for position in 0..<size {
            let ordinal = firstMessageIndex + position
            let isDraft = endsWithDraft && position == size - 1
            let fromOwner = position > 0 && (isDraft || Int.random(in: 0..<3, using: &generator) == 0)
            let sender = fromOwner ? owner : others[position % others.count]
            let recipients = fromOwner ? others : [owner] + others.filter { $0.address != sender.address }
            var roles: Set<MailboxRole>
            if spam {
                roles = [.spam]
            } else if trashed {
                roles = [.trash]
            } else if isDraft {
                roles = [.drafts]
            } else if fromOwner {
                roles = [.sent]
            } else {
                roles = Double.random(in: 0..<1, using: &generator) < 0.75 ? [.inbox] : []
            }
            let inInbox = roles.contains(.inbox)
            let section: InboxSection = inInbox
                ? (Double.random(in: 0..<1, using: &generator) < options.focusedFraction ? .focused : .other)
                : .unknown
            let isRead = fromOwner || Double.random(in: 0..<1, using: &generator) >= options.unreadFraction
            let isStarred = Double.random(in: 0..<1, using: &generator) < options.starredFraction
            let hasAttachments = Double.random(in: 0..<1, using: &generator) < options.attachmentFraction
            let internetID = "<m\(ordinal)@synthetic.example>"
            let messageSubject = position == 0 ? subject : "Re: \(subject)"
            let snippet = "\(sender.shortDisplay) wrote about \(subject.lowercased()) in message \(ordinal)"
            let message = MessageMetadata(
                id: MessageID(accountID: account.id, providerID: "m\(ordinal)"),
                conversationID: ConversationID(accountID: account.id, providerID: threadID),
                internetMessageID: internetID,
                inReplyTo: previousInternetID,
                references: references,
                subject: messageSubject,
                snippet: snippet,
                from: sender,
                to: recipients,
                cc: [],
                bcc: [],
                replyTo: [],
                date: MailboxClock.date(dateMs),
                roles: roles,
                isRead: isRead,
                isStarred: isStarred,
                inboxSection: section,
                hasAttachments: hasAttachments,
                labelIDs: account.kind == .gmail ? roles.map { $0.rawValue.uppercased() }.sorted() : [],
                folderID: account.kind == .microsoft
                    ? roles.first.map { $0.rawValue }
                        ?? (options.graphFolderCount > 0 ? graphFolderID(index % options.graphFolderCount) : nil)
                    : nil,
                providerVersion: "v\(ordinal)",
                sizeBytes: Int.random(in: 2_000...90_000, using: &generator)
            )
            thread.append(message)
            references.append(internetID)
            previousInternetID = internetID
            // Replies arrive between a minute and three days later.
            dateMs += Int64.random(in: 60_000...259_200_000, using: &generator)
        }
        return thread
    }

    // MARK: Word lists

    private static let firstNames = [
        "Alice", "Bob", "Carol", "Dmitri", "Elena", "Farid", "Grace", "Hiro", "Ingrid", "Jamal", "Kavya", "Liam",
        "Mei", "Noor", "Olga", "Pedro", "Quinn", "Rosa", "Sven", "Tomás", "Uma", "Viktor", "Wen", "Ximena",
        "Yusuf", "Zoë",
    ]
    private static let lastNames = [
        "Andersen", "Baker", "Costa", "Dubois", "Eriksson", "Fischer", "García", "Haddad", "Ivanova", "Jensen",
        "Kowalski", "Larsen", "Müller", "Nakamura", "Okafor", "Petrov", "Quiroga", "Rossi", "Schmidt", "Tanaka",
        "Umar", "Varga", "Weber", "Xu", "Yamamoto", "Zhang",
    ]
    private static let domains = ["example.com", "mail.example.org", "corp.example.net", "studio.example.io"]
    private static let subjects = [
        "Quarterly budget review", "Lunch on Thursday?", "Invoice 4471 overdue", "Design review notes",
        "Trip itinerary", "Re-org announcement", "Weekly metrics", "Contract draft v3", "Photos from the hike",
        "Office move checklist", "Interview feedback", "Release 2.4 go/no-go", "Parking permit renewal",
        "Board deck comments", "Welcome aboard", "Server maintenance window", "Birthday plans",
        "Expense report rejected", "Podcast recommendation", "Conference talk proposal",
    ]
    private static let bodyWords = [
        "the", "and", "to", "of", "a", "in", "that", "is", "for", "we", "it", "on", "with", "this", "as", "be",
        "at", "by", "from", "or", "have", "an", "not", "are", "but", "what", "all", "were", "when", "your",
        "can", "there", "use", "each", "which", "she", "do", "how", "their", "if", "will", "up", "other",
        "about", "out", "many", "then", "them", "these", "so", "some", "would", "make", "like", "into", "time",
        "look", "two", "more", "write", "number", "could", "people", "than", "first", "been", "call",
        "budget", "meeting", "schedule", "deadline", "proposal", "feedback", "attached", "spreadsheet", "draft",
        "review", "release", "customer", "invoice", "payment", "quarter", "roadmap", "design", "launch",
        "metrics", "report", "thanks", "please", "update", "tomorrow", "morning", "afternoon", "agenda",
    ]
}
