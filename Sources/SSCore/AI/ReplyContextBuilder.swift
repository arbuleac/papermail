import Foundation

/// Builds what Help Me Write sends about a conversation, only when the user presses Write: the last few messages, each
/// as its author's name, date and own words (quoted history stripped), the subject once, attachments as a count, the
/// user's first name, and their ask. Addresses, links, codes and card numbers are redacted (`AIRedactor`); drafts are
/// left out.
///
/// Pure and Sendable: it reads nothing itself. The app passes the visible messages (`RenderPayloadBuilder
/// .visibleMessages`) and a body reader, and runs it off the main thread after `MailClient.keepBodies(of:)`.
public struct ReplyContextBuilder: Sendable {
    public struct Limits: Sendable, Hashable {
        /// The most messages sent, the target always among them.
        public var maxMessages: Int
        /// The most characters of message text (with a small allowance per message for its header line). Oldest
        /// messages go first; the target is cut, never dropped.
        public var maxCharacters: Int
        /// The most characters of the user's notes, selection or instruction: a paste of a whole document is not an ask.
        public var maxAskCharacters: Int

        public init(maxMessages: Int = 8, maxCharacters: Int = 24_000, maxAskCharacters: Int = 8_000) {
            self.maxMessages = maxMessages
            self.maxCharacters = maxCharacters
            self.maxAskCharacters = maxAskCharacters
        }

        public static let standard = Limits()
    }

    /// One message's stored text, as the app read it (`StoredBody.plainText`, or `body.text` when that is empty).
    public struct Body: Sendable, Hashable {
        /// The plain text as stored: quoted history included, the builder strips it.
        public var plainText: String
        /// Attachments that are not inline images.
        public var attachmentCount: Int

        public init(plainText: String, attachmentCount: Int = 0) {
            self.plainText = plainText
            self.attachmentCount = attachmentCount
        }
    }

    /// The characters a message's header line (author, date, attachments) is counted as.
    static let headerAllowance = 60
    /// What replaces the end of a target message too long to send whole.
    static let cutMarker = " […]"

    public var accounts: [Account]
    public var limits: Limits
    /// The user's name when the app knows it from elsewhere (their Sent mail); the thread's own wins.
    public var knownUserName: String?

    public init(accounts: [Account], limits: Limits = .standard, knownUserName: String? = nil) {
        self.accounts = accounts
        self.limits = limits
        self.knownUserName = knownUserName
    }

    /// - Parameters:
    ///   - messages: the conversation's visible messages, any order (sorted here by date).
    ///   - target: the message the reply answers; nil (or not found) means the latest.
    ///   - ask: the user's instruction and notes or selection.
    ///   - body: the stored text of a message, nil when there is none (only its snippet is sent then).
    public func build(messages: [MessageMetadata], replyingTo target: MessageID?, ask: WriteAsk,
                      body: (MessageMetadata) -> Body?) -> ReplyContext {
        let ownAddresses = Set(accounts.map { $0.email.lowercased() })
        let visible = Self.ordered(messages.filter { !$0.roles.contains(.drafts) })
        let cleanAsk = Self.cleaned(ask, limit: limits.maxAskCharacters)
        guard !visible.isEmpty else {
            return ReplyContext(subject: "", messages: [], userFirstName: firstName(in: [], target: nil, own: ownAddresses), ask: cleanAsk)
        }
        let targetIndex = target.flatMap { id in visible.lastIndex { $0.id == id } } ?? visible.count - 1
        let redactor = AIRedactor(names: Self.directory(of: visible))

        var kept = selection(count: visible.count, target: targetIndex)
        var built: [Int: ReplyContext.Message] = [:]
        for index in kept {
            built[index] = message(visible[index], isTarget: index == targetIndex, own: ownAddresses, redactor: redactor, body: body)
        }
        // Oldest first, never the target, until the text fits; then the target itself is cut.
        func size() -> Int { kept.reduce(0) { $0 + (built[$1]?.text.count ?? 0) + Self.headerAllowance } }
        while size() > limits.maxCharacters, let oldest = kept.first(where: { $0 != targetIndex }) {
            kept.removeAll { $0 == oldest }
        }
        if size() > limits.maxCharacters, var only = built[targetIndex] {
            let room = max(0, limits.maxCharacters - Self.headerAllowance - Self.cutMarker.count)
            only.text = String(only.text.prefix(room)) + Self.cutMarker
            built[targetIndex] = only
        }

        let subject = redactor.redact(RenderPayloadBuilder.subject(of: visible))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ReplyContext(
            subject: String(subject.prefix(300)),
            messages: kept.compactMap { built[$0] },
            omittedCount: visible.count - kept.count,
            userFirstName: firstName(in: visible, target: visible[targetIndex], own: ownAddresses),
            ask: cleanAsk
        )
    }

    // MARK: Choosing messages

    /// The last `maxMessages` indices, oldest first; when the target is older than those, it takes the oldest place.
    private func selection(count: Int, target: Int) -> [Int] {
        let limit = max(1, limits.maxMessages)
        var kept = Array(max(0, count - limit)..<count)
        if !kept.contains(target) {
            kept.removeFirst()
            kept.insert(target, at: 0)
        }
        return kept
    }

    private static func ordered(_ messages: [MessageMetadata]) -> [MessageMetadata] {
        messages.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
    }

    // MARK: One message

    private func message(_ metadata: MessageMetadata, isTarget: Bool, own: Set<String>, redactor: AIRedactor,
                         body: (MessageMetadata) -> Body?) -> ReplyContext.Message {
        let isFromUser = metadata.from.map { own.contains($0.address.lowercased()) } ?? false
        let text: String
        let attachments: Int
        let isPreview: Bool
        if let stored = body(metadata) {
            // Bytes, not characters, bound the scan: four per character keeps a CJK thread from being cut early.
            text = QuotedHistory.ownWords(of: Self.normalizedNewlines(stored.plainText), limit: limits.maxCharacters * 4)
            attachments = stored.attachmentCount
            isPreview = false
        } else {
            text = metadata.snippet
            attachments = metadata.hasAttachments ? 1 : 0
            isPreview = true
        }
        return ReplyContext.Message(
            author: isFromUser ? "you" : Self.author(metadata.from, redactor: redactor),
            isFromUser: isFromUser,
            date: metadata.date,
            text: Self.tidied(redactor.redact(text)),
            attachmentCount: attachments,
            isPreview: isPreview,
            isReplyTarget: isTarget
        )
    }

    private static func author(_ from: EmailAddress?, redactor: AIRedactor) -> String {
        guard let from else { return "someone" }
        if let name = usableName(from.name) { return redactor.redact(name) }
        let domain = from.address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        return domain.isEmpty || !from.address.contains("@") ? "someone" : "someone at \(domain)"
    }

    /// Lower-cased address → name, from every header in the thread, the newest naming winning, so an address written in
    /// a body becomes the person's name.
    private static func directory(of messages: [MessageMetadata]) -> [String: String] {
        var names: [String: String] = [:]
        for message in messages {
            for address in [message.from].compactMap({ $0 }) + message.to + message.cc + message.replyTo {
                if let name = usableName(address.name) { names[address.address.lowercased()] = name }
            }
        }
        return names
    }

    /// A display name worth writing: not empty, not an address dressed as a name.
    private static func usableName(_ name: String?) -> String? {
        let trimmed = AIRedactor.removingInvisibleCharacters(name ?? "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard !trimmed.isEmpty, !trimmed.contains("@") else { return nil }
        return trimmed
    }

    // MARK: The user's first name

    /// From the user's own messages in the thread (the replying account's first, then any of theirs), then the name
    /// the app knows, then a Microsoft account's display name. Never how others address the user in To or Cc: a sender
    /// writes that header, and the name goes outside the fences, where the instructions do not call it data. Never
    /// Gmail's display name: it is the address's local part.
    private func firstName(in messages: [MessageMetadata], target: MessageMetadata?, own: Set<String>) -> String? {
        let replying = target.flatMap { target in accounts.first { $0.id == target.id.accountID } }
        let replyingAddress = replying?.email.lowercased()
        let newestFirst = Array(messages.reversed())
        var candidates: [String?] = []
        if let replyingAddress {
            candidates += newestFirst.map { $0.from?.address.lowercased() == replyingAddress ? $0.from?.name : nil }
        }
        candidates += newestFirst.map { message in message.from.flatMap { own.contains($0.address.lowercased()) ? $0.name : nil } }
        candidates.append(knownUserName)
        if let replying, replying.kind == .microsoft { candidates.append(replying.displayName) }
        for candidate in candidates {
            if let first = Self.firstWord(of: candidate) { return first }
        }
        return nil
    }

    /// The name's first word when it is a name: letters, with an apostrophe or a hyphen inside (“O'Neil”, “Jean-Luc”),
    /// at most 40 of them. Anything else (digits, punctuation, a word that could carry an instruction) gives none.
    static func firstWord(of name: String?) -> String? {
        guard let name = usableName(name) else { return nil }
        // “Morgan, Alex” is the directory form: the first name follows the comma.
        let given = name.contains(",") ? String(name.split(separator: ",", maxSplits: 1).last ?? "") : name
        guard let word = given.split(whereSeparator: \.isWhitespace).first.map(String.init), word.count <= 40,
              word.first?.isLetter == true, word.last?.isLetter == true,
              word.allSatisfy({ $0.isLetter || "'\u{2019}-".contains($0) }) else {
            return nil
        }
        return word
    }

    // MARK: Text

    private static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Trims the ends and folds runs of blank lines, which carry nothing a model needs and cost characters.
    private static func tidied(_ text: String) -> String {
        var lines: [Substring] = []
        var blank = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }.isEmpty
            blank = trimmed ? blank + 1 : 0
            if blank <= 1 { lines.append(trimmed ? "" : line) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `text`, as the ask would send it (invisible characters gone, trimmed), is longer than `limits` lets go:
    /// the app refuses such a selection or notes rather than send a cut part that the reply would replace whole.
    public static func exceedsAskLimit(_ text: String, limits: Limits = .standard) -> Bool {
        askText(text).count > limits.maxAskCharacters
    }

    private static func askText(_ text: String) -> String {
        AIRedactor.removingInvisibleCharacters(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ ask: WriteAsk, limit: Int) -> WriteAsk {
        func clean(_ text: String) -> String {
            String(askText(text).prefix(limit))
        }
        var cleaned = ask
        cleaned.instruction = clean(ask.instruction)
        switch ask.draft {
        case .empty:
            break
        case .notes(let notes):
            let text = clean(notes)
            cleaned.draft = text.isEmpty ? .empty : .notes(text)
        case .selection(let selection):
            let text = clean(selection)
            cleaned.draft = text.isEmpty ? .empty : .selection(text)
        }
        return cleaned
    }
}
