import Foundation

/// What a composer hands Help Me Write when the user asks it to write a new message or a forward: plain values the
/// window already holds, read on the main thread at that moment and never before. `request(for:configuration:)` turns
/// them into the finished request, off the main thread. Nothing here reads the store, the contacts or another message,
/// so what the window did not hand over cannot be sent; and of what it did, only what `NewMessageContext` and
/// `ForwardContext` keep is.
public struct ComposeWriteInputs: Sendable, Hashable {
    /// The message being forwarded as the composer itself holds it (its `quoted`), which is exactly what the recipients
    /// will get. Never the store's copy of it, never its snippet, never the rest of its conversation.
    public struct Forwarded: Sendable, Hashable {
        /// Its plain text, the history it quotes included (`QuotedReply.Rendering.originalText`).
        public var text: String
        /// Who wrote it, as the composer shows it (`QuotedReply.Rendering.author`): a display name, or the address that
        /// falls back to, which is never sent as one.
        public var author: String
        public var date: Date?
        /// The files on the composer's strip that are not inline pictures, counted as the user asks: what the
        /// recipients will get, whatever the original carried. Never their names.
        public var attachmentCount: Int

        public init(text: String, author: String, date: Date? = nil, attachmentCount: Int = 0) {
            self.text = text
            self.author = author
            self.date = date
            self.attachmentCount = attachmentCount
        }
    }

    /// The Subject field as it stands.
    public var subject: String
    /// The To recipients, in order. Never Cc, never Bcc: only the people the message greets are named, and a Bcc name
    /// in a greeting would give the Bcc away.
    public var to: [EmailAddress]
    /// The account the message is sent from; nil when the window has none.
    public var account: Account?
    /// The body ends in the account's signature, so the model leaves out a sign-off name.
    public var appendsSignature: Bool
    /// The composer would take a subject from this write: a new message it wrote itself, whose Subject is empty. Asked
    /// for only then, and never for a selection's rewrite or with a subject typed.
    public var wantsSubject: Bool
    /// The body is still exactly what a mail link or a Service filled in, so someone else may have written it: the
    /// notes, or a selection of them, go through the redactor as mail does. False once the user has edited the body.
    public var redactsOwnText: Bool
    /// The forwarded message; nil for a new message, and for a forward whose original is not there to read, which is
    /// written the way a new message is.
    public var forwarded: Forwarded?

    public init(subject: String = "", to: [EmailAddress] = [], account: Account? = nil, appendsSignature: Bool = false,
                wantsSubject: Bool = false, redactsOwnText: Bool = false, forwarded: Forwarded? = nil) {
        self.subject = subject
        self.to = to
        self.account = account
        self.appendsSignature = appendsSignature
        self.wantsSubject = wantsSubject
        self.redactsOwnText = redactsOwnText
        self.forwarded = forwarded
    }

    /// The most characters of the subject that are sent.
    public static let maxSubjectCharacters = 300
    /// The most To recipients whose first name is sent: enough for a greeting.
    public static let maxRecipients = 4

    /// What a write from these values is: a forward when its forwarded message is in hand, else a new message.
    public var kind: WriteKind { forwarded == nil ? .newMessage : .forward }

    /// The whole request for `ask`, with a fresh fence; nil when nothing may be sent (nothing to write from, or a part of
    /// the ask longer than is sent: `WriteKind.hasNothingToWriteFrom`, `WriteKind.lengthRefusal`, which the caller
    /// tests before it makes the user's action). Pure, and meant for a background thread: a long forwarded message is
    /// read and redacted here.
    public func request(for ask: WriteAsk, configuration: AIProviderConfiguration, fence: String = WritePrompt.newFence(),
                        timeZone: TimeZone = .current) -> AIWriteRequest? {
        if forwarded != nil {
            guard let context = ForwardContext(self, ask: ask) else { return nil }
            return WritePrompt.request(for: context, configuration: configuration, fence: fence, timeZone: timeZone)
        }
        guard let context = NewMessageContext(self, ask: ask) else { return nil }
        return WritePrompt.request(for: context, configuration: configuration, fence: fence)
    }

    // MARK: What is kept of each value

    /// The subject as it is sent: redacted, on one line, at most `maxSubjectCharacters`. A mail link can fill the
    /// Subject, so it is treated as mail is.
    var sentSubject: String {
        String(WriteSubjectLine.oneLine(AIRedactor().redact(subject)).prefix(Self.maxSubjectCharacters))
    }

    /// The first names of the first `maxRecipients` To recipients, for the greeting: a name's first word when it is
    /// one word of letters (`ReplyContextBuilder.firstWord`), nothing for a bare address or an address written as a
    /// name. Only what the window holds: no contact is looked up.
    var recipientFirstNames: [String] {
        to.prefix(Self.maxRecipients).compactMap { ReplyContextBuilder.firstWord(of: $0.name) }
    }

    /// The user's first name when Paper knows it: a Microsoft account's display name. Gmail's is the address's local
    /// part, never a name, and a new message has no thread of the user's own mail to read one from.
    var userFirstName: String? {
        guard let account, account.kind == .microsoft else { return nil }
        return ReplyContextBuilder.firstWord(of: account.displayName)
    }

    /// `ask` as it is sent: invisible characters out and the ends trimmed, blank notes or a blank selection becoming
    /// none; never cut (a part too long is refused before this). With `redactsOwnText`, the notes or the selection
    /// redacted too. The instruction is always the user's own typing.
    func cleaned(_ ask: WriteAsk) -> WriteAsk {
        var cleaned = ReplyContextBuilder.cleaned(ask, limit: .max)
        guard redactsOwnText else { return cleaned }
        func redacted(_ text: String) -> String {
            AIRedactor().redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch cleaned.draft {
        case .empty:
            break
        case .notes(let notes):
            let text = redacted(notes)
            cleaned.draft = text.isEmpty ? .empty : .notes(text)
        case .selection(let selection):
            let text = redacted(selection)
            cleaned.draft = text.isEmpty ? .empty : .selection(text)
        }
        return cleaned
    }
}
