import Foundation

/// Builds what Help Me Write sends about a conversation, only when the user presses Write: the whole thread, newest
/// message first, weighed by how recent it is. The message replied to goes in full up to a large share of the budget,
/// the next two newest in full up to a smaller one, every older message as a short digest of its own first sentences
/// (a cap that shrinks with age), and when even the digests do not fit, the oldest fold into one line naming how many,
/// who wrote them and the words they used most. A summary of the thread (who, how many, how long, what the message
/// replied to asks) is built first. Each message is its author's name, date and own words (quoted history stripped);
/// attachments are a count. Addresses, links, codes and card numbers are redacted (`AIRedactor`); drafts are left out.
///
/// Everything is extractive and local: no model call, no network, a few milliseconds for a long thread.
///
/// Pure and Sendable: it reads nothing itself. The app passes the visible messages (`RenderPayloadBuilder
/// .visibleMessages`) and a body reader, and runs it off the main thread after `MailClient.keepBodies(of:)`.
public struct ReplyContextBuilder: Sendable {
    public struct Limits: Sendable, Hashable {
        /// The most characters of message text, each message counted with a small allowance for its header line.
        public var maxCharacters: Int
        /// The share of `maxCharacters` the message replied to may take, whole; past it, it is cut.
        public var targetShare: Double
        /// The share each of the next two newest messages may take, whole; past it, each is cut.
        public var recentShare: Double
        /// How many messages after the one replied to are sent whole (or cut to `recentShare`); older ones are digests.
        public var recentCount: Int
        /// The newest digest's cap in characters; each older one gets `digestDecay` of the one before, down to
        /// `digestFloor`.
        public var digestCap: Int
        public var digestDecay: Double
        public var digestFloor: Int
        /// How far the digests' caps may grow, all in proportion, when the budget has room left after the messages sent
        /// whole: a short thread's older messages then say more than their first sentence.
        public var digestMaxScale: Double
        /// The most characters of the user's notes, selection or instruction: a paste of a whole document is not an ask.
        public var maxAskCharacters: Int

        public init(maxCharacters: Int = 24_000, targetShare: Double = 0.45, recentShare: Double = 0.15, recentCount: Int = 2,
                    digestCap: Int = 400, digestDecay: Double = 0.85, digestFloor: Int = 80, digestMaxScale: Double = 3,
                    maxAskCharacters: Int = 8_000) {
            self.maxCharacters = maxCharacters
            self.targetShare = targetShare
            self.recentShare = recentShare
            self.recentCount = recentCount
            self.digestCap = digestCap
            self.digestDecay = digestDecay
            self.digestFloor = digestFloor
            self.digestMaxScale = digestMaxScale
            self.maxAskCharacters = maxAskCharacters
        }

        public static let standard = Limits()

        /// The characters the message replied to may take.
        public var targetBudget: Int { Int(Double(maxCharacters) * targetShare) }
        /// The characters each of the next newest messages may take.
        public var recentBudget: Int { Int(Double(maxCharacters) * recentShare) }

        /// The cap of the digest `age` places after the newest digest, its cap and floor grown by `scale` (1 to
        /// `digestMaxScale`) when the budget has room for it.
        public func digestCap(age: Int, scale: Double = 1) -> Int {
            let scale = min(max(1, scale), max(1, digestMaxScale))
            let decayed = Double(digestCap) * scale * pow(digestDecay, Double(max(0, age)))
            return max(Int((Double(digestFloor) * scale).rounded()), Int(decayed.rounded()))
        }

        /// How much the caps of `count` digests grow when `room` characters are left for them, headers included: as
        /// much as fills the room, between 1 and `digestMaxScale`.
        public func digestScale(count: Int, room: Int) -> Double {
            guard count > 0 else { return 1 }
            let base = (0..<count).reduce(0) { $0 + digestCap(age: $1) }
            let words = room - count * ReplyContextBuilder.headerAllowance
            guard base > 0, words > base else { return 1 }
            // The floor grows with the caps, so the scale that fills the room is found by trying, from the largest down.
            var scale = max(1, digestMaxScale)
            while scale > 1 {
                if (0..<count).reduce(0, { $0 + digestCap(age: $1, scale: scale) }) <= words { return scale }
                scale = max(1, scale - 0.25)
            }
            return 1
        }
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

    /// The characters a message's header line (position, author, date, attachments) is counted as.
    public static let headerAllowance = 60
    /// What replaces the end of a message too long for its share.
    public static let cutMarker = " […]"
    /// What ends a digest that stopped inside its first sentence.
    static let digestEllipsis = "\u{2026}"
    /// The most question sentences the summary quotes, and the most characters of each.
    static let maxAsks = 3
    static let maxAskSentence = 200

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
        // Newest first: the order the model reads it in, and the order the budget is spent in.
        let newest = Array(Self.ordered(messages.filter { !$0.roles.contains(.drafts) }).reversed())
        let cleanAsk = Self.cleaned(ask, limit: limits.maxAskCharacters)
        guard !newest.isEmpty else {
            return ReplyContext(subject: "", messages: [], userFirstName: firstName(in: [], target: nil, own: ownAddresses), ask: cleanAsk)
        }
        let targetIndex = target.flatMap { id in newest.firstIndex { $0.id == id } } ?? 0
        let redactor = AIRedactor(names: Self.directory(of: newest))
        let recent = Set(newest.indices.filter { $0 != targetIndex }.prefix(max(0, limits.recentCount)))

        var sent: [ReplyContext.Message] = []
        var digestAge = 0
        var spent = 0
        var folded: [Int] = []
        let digestCount = newest.indices.filter { $0 != targetIndex && !recent.contains($0) }.count
        /// Set at the first digest, once the messages sent whole have taken theirs: what is left grows the digests.
        var digestScale: Double?
        // The message replied to first, then the newest to the oldest: whatever is left when the oldest come is theirs.
        for index in [targetIndex] + newest.indices.filter({ $0 != targetIndex }) {
            let metadata = newest[index]
            let isTarget = index == targetIndex
            let isDigest = !isTarget && !recent.contains(index)
            if isDigest, digestScale == nil {
                digestScale = limits.digestScale(count: digestCount, room: limits.maxCharacters - spent)
            }
            let cap = isTarget ? limits.targetBudget : recent.contains(index) ? limits.recentBudget
                : limits.digestCap(age: digestAge, scale: digestScale ?? 1)
            if isDigest {
                digestAge += 1
                // Past the budget, this one and every older one fold into one line.
                guard folded.isEmpty else {
                    folded.append(index)
                    continue
                }
            }
            var message = self.message(metadata, position: index, isTarget: isTarget, digest: isDigest, cap: cap,
                                       own: ownAddresses, redactor: redactor, body: body)
            let size = message.text.count + Self.headerAllowance
            if isDigest, spent + size > limits.maxCharacters {
                folded.append(index)
                continue
            }
            if !isTarget, !isDigest, spent + size > limits.maxCharacters {
                // A recent message still goes, cut to what is left, so the newest are never folded under older digests.
                let room = limits.maxCharacters - spent - Self.headerAllowance - Self.cutMarker.count
                guard room > limits.digestFloor else {
                    folded.append(index)
                    continue
                }
                message.text = Self.cut(message.text, to: room)
                message.form = .cut
            }
            spent += message.text.count + Self.headerAllowance
            sent.append(message)
        }
        sent.sort { $0.position < $1.position }

        let subject = redactor.redact(RenderPayloadBuilder.subject(of: Array(newest.reversed())))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetMessage = newest[targetIndex]
        // The summary reads the message replied to as it is sent, rather than reading and redacting it again.
        let targetText = sent.first { $0.isReplyTarget }?.text ?? ""
        return ReplyContext(
            subject: String(subject.prefix(300)),
            summary: summary(of: newest, target: targetIndex, targetText: targetText, own: ownAddresses, redactor: redactor),
            messages: sent,
            fold: fold(of: folded.sorted().map { newest[$0] }, own: ownAddresses, redactor: redactor, body: body),
            userFirstName: firstName(in: Array(newest.reversed()), target: targetMessage, own: ownAddresses),
            ask: cleanAsk
        )
    }

    private static func ordered(_ messages: [MessageMetadata]) -> [MessageMetadata] {
        messages.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
    }

    // MARK: One message

    /// The message's own words, redacted, at most `cap` characters: whole or cut for a message sent in full, its first
    /// sentences for a digest.
    private func message(_ metadata: MessageMetadata, position: Int, isTarget: Bool, digest: Bool, cap: Int, own: Set<String>,
                         redactor: AIRedactor, body: (MessageMetadata) -> Body?) -> ReplyContext.Message {
        let isFromUser = Self.isFromUser(metadata, own: own)
        // A digest needs only its first sentences: reading less keeps a 30 KB message's digest to its first lines.
        // A digest reads past its cap for the boilerplate it drops (a banner, a greeting), then keeps a little more than the
        // cap for its sentences to end in.
        let (text, attachments, isPreview) = ownText(metadata, reading: digest ? cap * 2 + 512 : cap + 256,
                                                     keeping: digest ? cap + 128 : cap + 256, digest: digest,
                                                     redactor: redactor, body: body)
        var form = ReplyContext.Form.full
        var shown = text
        if digest {
            shown = Self.digest(text, cap: cap)
            form = .digest
        } else if text.count > cap {
            shown = Self.cut(text, to: max(0, cap - Self.headerAllowance - Self.cutMarker.count))
            form = .cut
        }
        return ReplyContext.Message(
            author: isFromUser ? "you" : Self.author(metadata.from, redactor: redactor),
            isFromUser: isFromUser,
            date: metadata.date,
            text: shown,
            attachmentCount: attachments,
            isPreview: isPreview,
            isReplyTarget: isTarget,
            position: position,
            form: form
        )
    }

    /// The message's own words (quoted history stripped, the mail's boilerplate dropped: `MailBoilerplate`, more of it
    /// for a digest), read up to about `reading` characters, then redacted and tidied, at most `keeping` of them.
    private func ownText(_ metadata: MessageMetadata, reading: Int, keeping: Int, digest: Bool, redactor: AIRedactor,
                         body: (MessageMetadata) -> Body?) -> (text: String, attachments: Int, isPreview: Bool) {
        if let stored = body(metadata) {
            // Bytes bound the read (four per character keeps a CJK thread from being cut early); characters bound what is
            // redacted, so ASCII mail is not redacted at four times what is shown.
            let limit = max(1, reading) * 4
            // Only the head is ever read: a long message, or a thread of hundreds, is not copied whole to be cut. A little
            // past the limit, so a quote's Outlook header (From:, then Sent: below it) is still seen as one.
            let head = QuotedHistory.limited(stored.plainText, to: limit + 512)
            let read = QuotedHistory.ownWords(of: Self.normalizedNewlines(head), limit: limit)
            let wasCut = read.utf8.count >= limit - 4
            var words = digest ? MailBoilerplate.trimmedForDigest(read, sawTheEnd: !wasCut)
                : MailBoilerplate.trimmedForFullText(read, sawTheEnd: !wasCut)
            words = Self.prefix(words, characters: keeping, wasCut: wasCut)
            return (Self.tidied(redactor.redact(words)), stored.attachmentCount, false)
        }
        return (Self.tidied(redactor.redact(metadata.snippet)), metadata.hasAttachments ? 1 : 0, true)
    }

    /// `text` up to `characters`, ending at a word: a word cut in two (an address, a link) never reaches the redactor,
    /// which could not tell it is one. `wasCut`: the text was already cut short, its last word perhaps with it.
    static func prefix(_ text: String, characters: Int, wasCut: Bool = false) -> String {
        guard wasCut || text.count > characters else { return text }
        var head = text.count > characters ? String(text.prefix(characters)) : text
        if let space = head.lastIndex(where: \.isWhitespace) {
            head = String(head[..<space])
        } else if text.count > characters || wasCut {
            head = ""
        }
        return head
    }

    private static func isFromUser(_ metadata: MessageMetadata, own: Set<String>) -> Bool {
        metadata.from.map { own.contains($0.address.lowercased()) } ?? false
    }

    private static func author(_ from: EmailAddress?, redactor: AIRedactor) -> String {
        guard let from else { return "someone" }
        if let name = usableName(from.name) { return redactor.redact(name) }
        let domain = from.address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        return domain.isEmpty || !from.address.contains("@") ? "someone" : "someone at \(domain)"
    }

    /// Lower-cased address → name, from every header in the thread, the newest naming winning, so an address written in
    /// a body becomes the person's name.
    private static func directory(of newestFirst: [MessageMetadata]) -> [String: String] {
        var names: [String: String] = [:]
        for message in newestFirst.reversed() {
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

    // MARK: Condensing

    /// `text` cut to `limit` characters at the last word boundary that fits, then the cut marker.
    static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var head = String(text.prefix(max(0, limit)))
        if let space = head.lastIndex(where: { $0.isWhitespace }), head.distance(from: head.startIndex, to: space) > limit / 2 {
            head = String(head[..<space])
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + cutMarker
    }

    /// The first sentences of `text` on one line, as many as fit in `cap` characters; a first sentence longer than that
    /// is cut at a word, with an ellipsis.
    static func digest(_ text: String, cap: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > cap else { return line }
        var kept = ""
        for sentence in sentences(of: line) {
            let next = kept.isEmpty ? sentence : kept + " " + sentence
            if next.count > cap { break }
            kept = next
        }
        if !kept.isEmpty { return kept }
        var head = String(line.prefix(max(1, cap - digestEllipsis.count)))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > cap / 2 {
            head = String(head[..<space])
        }
        return head + digestEllipsis
    }

    /// Sentences: runs ending in “.”, “!”, “?” or their full-width forms, then a space or the end.
    static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let enders: Set<Character> = [".", "!", "?", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
        var previousEnds = false
        for character in text {
            if previousEnds, character.isWhitespace {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
                previousEnds = false
                continue
            }
            current.append(character)
            previousEnds = enders.contains(character)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { result.append(last) }
        return result
    }

    // MARK: The summary

    private func summary(of newest: [MessageMetadata], target: Int, targetText: String, own: Set<String>,
                         redactor: AIRedactor) -> ReplyContext.Summary {
        var participants: [String] = []
        for message in newest {
            let name = Self.isFromUser(message, own: own) ? "you" : Self.author(message.from, redactor: redactor)
            if !participants.contains(name) { participants.append(name) }
        }
        // “Hi Alex,” is not part of what it asks.
        let asked = MailBoilerplate.withoutGreeting(targetText)
        return ReplyContext.Summary(
            participants: participants,
            messageCount: newest.count,
            firstDate: newest.last?.date,
            lastDate: newest.first?.date,
            asks: Self.questions(in: asked),
            targetIsLatest: target == 0
        )
    }

    /// The question sentences of `text`, at most three, each cut to 200 characters.
    static func questions(in text: String) -> [String] {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return sentences(of: line)
            .filter { $0.hasSuffix("?") || $0.hasSuffix("\u{FF1F}") }
            .prefix(maxAsks)
            .map { $0.count > maxAskSentence ? String($0.prefix(maxAskSentence - 1)) + digestEllipsis : $0 }
    }

    // MARK: The fold

    private func fold(of messages: [MessageMetadata], own: Set<String>, redactor: AIRedactor,
                      body: (MessageMetadata) -> Body?) -> ReplyContext.Fold? {
        guard !messages.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        var order: [String] = []
        var text = ""
        for message in messages {
            let name = Self.isFromUser(message, own: own) ? "you" : Self.author(message.from, redactor: redactor)
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
            // A few words each are enough to find what they were about: a long thread's fold reads little.
            text += " " + ownText(message, reading: limits.digestFloor * 2 + 256, keeping: limits.digestFloor * 2, digest: true,
                                  redactor: redactor, body: body).text
        }
        let authors = order.enumerated()
            .sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }
            .prefix(3).map(\.element)
        return ReplyContext.Fold(count: messages.count, authors: authors, keywords: Self.keywords(in: text, limit: 4))
    }

    /// The words `text` uses most: letters only, four or more of them, not a common word, never a redaction's own words
    /// (“link”, “address”), ties going to the word seen first.
    static func keywords(in text: String, limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        var first: [String: Int] = [:]
        var position = 0
        // Bracketed placeholders (“[link: contoso.test]”, “[code]”) and a redacted address's domain carry no topic.
        let unbracketed = text.replacingOccurrences(of: #"\[[^\]]*\]|\ban address at \S+"#, with: " ", options: .regularExpression)
        for raw in unbracketed.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }) {
            let word = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}"))
            guard word.count >= 4, word.count <= 30, !stopWords.contains(word) else { continue }
            counts[word, default: 0] += 1
            if first[word] == nil {
                first[word] = position
                position += 1
            }
        }
        return counts.keys
            .sorted { (counts[$0] ?? 0, -(first[$0] ?? 0)) > (counts[$1] ?? 0, -(first[$1] ?? 0)) }
            .prefix(limit).map { $0 }
    }

    /// Words that say nothing about what a thread is about, and the redactor's own words.
    static let stopWords: Set<String> = [
        "about", "above", "after", "again", "also", "always", "another", "anything", "around", "back", "been", "before", "being",
        "best", "both", "could", "dear", "does", "doing", "done", "down", "each", "even", "every", "from", "further", "going",
        "good", "great", "have", "having", "hello", "here", "hers", "himself", "into", "it's", "just", "know", "let's", "like",
        "look", "looking", "made", "make", "many", "maybe", "more", "most", "much", "must", "need", "next", "only", "other",
        "ours", "over", "please", "really", "regards", "same", "seems", "should", "some", "soon", "still", "such", "sure",
        "take", "than", "thank", "thanks", "that", "that's", "their", "them", "then", "there", "these", "they", "thing",
        "things", "think", "this", "those", "through", "time", "today", "tomorrow", "very", "want", "week", "well", "were",
        "what", "when", "where", "which", "while", "will", "with", "would", "yeah", "your", "yours", "you're", "we're", "i'll",
        "i'm", "don't", "can't", "didn't", "isn't", "won't", "wouldn't", "couldn't", "shouldn't", "cheers", "best", "kind",
        "someone", "address", "link", "card", "number", "code", "email", "e-mail", "caution", "originated", "organization",
        "organisation", "outlook", "iphone", "confidential", "intended", "recipient", "sender", "message", "sent",
    ]

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
