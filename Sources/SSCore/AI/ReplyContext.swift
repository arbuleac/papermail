import Foundation

/// Everything Help Me Write sends besides SuperSparrow's fixed instructions, already weighed, cut and redacted by
/// `ReplyContextBuilder`: the whole conversation, newest message first, the message replied to in full, the next two
/// newest in full up to a smaller share, every older one as a short digest of its own first sentences, and the oldest
/// folded into one line when even their digests do not fit; a short summary of the thread ahead of it; and the user's
/// ask. `WritePrompt` turns it into text.
public struct ReplyContext: Sendable, Hashable {
    /// How much of a message is sent.
    public enum Form: Sendable, Hashable {
        /// Its own words in full.
        case full
        /// Its own words up to its share of the budget, ending in `ReplyContextBuilder.cutMarker`.
        case cut
        /// Its first sentences only, up to a cap that shrinks with age: context, not something to answer.
        case digest
    }

    public struct Message: Sendable, Hashable {
        /// “you” for the user's own messages, the sender's name, or “someone at contoso.com”. Never an address.
        public var author: String
        public var isFromUser: Bool
        public var date: Date
        /// The message's own words (quoted history stripped), redacted, in full, cut or digested (`form`).
        public var text: String
        /// Attachments as a count only; never their names.
        public var attachmentCount: Int
        /// Only the provider's snippet was available (the body was never downloaded).
        public var isPreview: Bool
        /// The message the reply answers (the reader's target, else the latest).
        public var isReplyTarget: Bool
        /// Its place in the thread counted from the newest: 0 is the latest message.
        public var position: Int
        public var form: Form

        public init(author: String, isFromUser: Bool, date: Date, text: String, attachmentCount: Int = 0,
                    isPreview: Bool = false, isReplyTarget: Bool = false, position: Int = 0, form: Form = .full) {
            self.author = author
            self.isFromUser = isFromUser
            self.date = date
            self.text = text
            self.attachmentCount = attachmentCount
            self.isPreview = isPreview
            self.isReplyTarget = isReplyTarget
            self.position = position
            self.form = form
        }

        /// “Latest”, “2nd latest”, “3rd latest”, …: its real place, whether sent whole, cut or as a digest, so a digest of
        /// a message newer than the one replied to never reads as older (the transcript adds “shortened” to a digest).
        public var positionLabel: String {
            position == 0 ? "Latest" : ReplyContext.ordinal(position + 1) + " latest"
        }
    }

    /// The thread at a glance, built locally before anything else: what it is about, who is in it, how long it has
    /// run, and what the message replied to asks.
    public struct Summary: Sendable, Hashable {
        /// Every author's name in the thread, the user as “you”, newest first. Names only, never addresses.
        public var participants: [String]
        /// Every message in the thread, drafts left out, whether sent whole, digested or folded.
        public var messageCount: Int
        public var firstDate: Date?
        public var lastDate: Date?
        /// The question sentences of the message replied to, redacted; empty when it asks nothing.
        public var asks: [String]
        /// Whether the message replied to is the latest (the summary then says “the latest message asks”).
        public var targetIsLatest: Bool

        public init(participants: [String] = [], messageCount: Int = 0, firstDate: Date? = nil, lastDate: Date? = nil,
                    asks: [String] = [], targetIsLatest: Bool = true) {
            self.participants = participants
            self.messageCount = messageCount
            self.firstDate = firstDate
            self.lastDate = lastDate
            self.asks = asks
            self.targetIsLatest = targetIsLatest
        }
    }

    /// The oldest messages, when even their digests did not fit: how many, who wrote them and what they were about, as
    /// one line.
    public struct Fold: Sendable, Hashable {
        public var count: Int
        /// Their authors' names, the most frequent first, at most three.
        public var authors: [String]
        /// The words they used most, at most four (`ReplyContextBuilder.keywords`).
        public var keywords: [String]

        public init(count: Int, authors: [String] = [], keywords: [String] = []) {
            self.count = count
            self.authors = authors
            self.keywords = keywords
        }
    }

    /// The thread's subject, once, redacted.
    public var subject: String
    public var summary: Summary
    /// Newest first: the latest message is the first.
    public var messages: [Message]
    /// The oldest messages, folded into one line; nil when every message is in `messages`.
    public var fold: Fold?
    /// The user's first name, to sign or greet with; nil when the thread does not say it.
    public var userFirstName: String?
    public var ask: WriteAsk

    public init(subject: String, summary: Summary = Summary(), messages: [Message], fold: Fold? = nil, userFirstName: String? = nil,
                ask: WriteAsk = WriteAsk()) {
        self.subject = subject
        self.summary = summary
        self.messages = messages
        self.fold = fold
        self.userFirstName = userFirstName
        self.ask = ask
    }

    /// How many messages are only in the fold line.
    public var foldedCount: Int { fold?.count ?? 0 }

    /// “2nd”, “3rd”, “11th”, “22nd”.
    static func ordinal(_ number: Int) -> String {
        let tens = number % 100
        if (11...13).contains(tens) { return "\(number)th" }
        switch number % 10 {
        case 1: return "\(number)st"
        case 2: return "\(number)nd"
        case 3: return "\(number)rd"
        default: return "\(number)th"
        }
    }
}
