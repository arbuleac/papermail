import Foundation

/// Everything Help Me Write sends besides SuperSparrow's fixed instructions, already cut and redacted by
/// `ReplyContextBuilder`: the consent sheet's “the latest messages in this conversation, your notes and your first
/// name”, as data. `WritePrompt` turns it into text.
public struct ReplyContext: Sendable, Hashable {
    public struct Message: Sendable, Hashable {
        /// “you” for the user's own messages, the sender's name, or “someone at contoso.com”. Never an address.
        public var author: String
        public var isFromUser: Bool
        public var date: Date
        /// The message's own words (quoted history stripped), redacted.
        public var text: String
        /// Attachments as a count only; never their names.
        public var attachmentCount: Int
        /// Only the provider's snippet was available (the body was never downloaded).
        public var isPreview: Bool
        /// The message the reply answers (the reader's target, else the latest).
        public var isReplyTarget: Bool

        public init(author: String, isFromUser: Bool, date: Date, text: String, attachmentCount: Int = 0,
                    isPreview: Bool = false, isReplyTarget: Bool = false) {
            self.author = author
            self.isFromUser = isFromUser
            self.date = date
            self.text = text
            self.attachmentCount = attachmentCount
            self.isPreview = isPreview
            self.isReplyTarget = isReplyTarget
        }
    }

    /// The thread's subject, once, redacted.
    public var subject: String
    /// Oldest first, newest last, at most `ReplyContextBuilder.Limits.maxMessages`.
    public var messages: [Message]
    /// How many earlier messages the caps left out, so the model knows the thread is longer.
    public var omittedCount: Int
    /// The user's first name, to sign or greet with; nil when the thread does not say it.
    public var userFirstName: String?
    public var ask: WriteAsk

    public init(subject: String, messages: [Message], omittedCount: Int = 0, userFirstName: String? = nil, ask: WriteAsk = WriteAsk()) {
        self.subject = subject
        self.messages = messages
        self.omittedCount = omittedCount
        self.userFirstName = userFirstName
        self.ask = ask
    }
}
