import Foundation

/// Everything Help Me Write sends about a forward besides Paper's fixed instructions: the one message being forwarded,
/// cleaned and redacted, the forward's own subject, the first names of the people it goes to, the user's first name
/// when Paper knows it, and the user's ask. The forwarded message is the composer's own copy, the one the recipients
/// will get, so the model never reads more than they will; the rest of its conversation is never part of it.
/// `WritePrompt` turns it into text.
public struct ForwardContext: Sendable, Hashable {
    /// The forwarded message as it is sent.
    public struct Message: Sendable, Hashable {
        /// Its writer's name, “someone at contoso.com”, or “someone”. Never an address.
        public var author: String
        public var date: Date?
        /// Its writer's own words (quoted history stripped, the mail's boilerplate dropped), redacted, cut at
        /// `maxCharacters` with `ReplyContextBuilder.cutMarker`.
        public var text: String
        /// What it quotes, cleaned the same way, given only when the own words are fewer than `fewOwnWords`: a forward
        /// of a forward says “FYI, see below” and little else, while its recipients get all of it. Empty otherwise.
        public var quoted: String
        /// Attachments as a count only; never their names.
        public var attachmentCount: Int

        public init(author: String, date: Date? = nil, text: String, quoted: String = "", attachmentCount: Int = 0) {
            self.author = author
            self.date = date
            self.text = text
            self.quoted = quoted
            self.attachmentCount = attachmentCount
        }
    }

    /// The most characters of the forwarded message, its own words and what it quotes together.
    public static let maxCharacters = 12_000
    /// Own words shorter than this are too few to describe the message by: what it quotes is read too.
    public static let fewOwnWords = 200
    /// The most characters of the author's name.
    static let maxAuthorCharacters = 80

    /// The forward's own subject (“Fwd: …”): redacted, one line, at most 300 characters.
    public var subject: String
    /// The forwarded message; nil for a selection's rewrite, which sends the selection and the instruction alone.
    public var message: Message?
    /// The first names of the To recipients, at most four; never Cc, never Bcc, never an address.
    public var recipientFirstNames: [String]
    /// The user's first name, to sign with; nil when Paper does not know it.
    public var userFirstName: String?
    public var ask: WriteAsk
    /// The body ends in the account's signature, so the model leaves out a sign-off name.
    public var appendsSignature: Bool

    public init(subject: String = "", message: Message?, recipientFirstNames: [String] = [], userFirstName: String? = nil,
                ask: WriteAsk, appendsSignature: Bool = false) {
        self.subject = subject
        self.message = message
        self.recipientFirstNames = recipientFirstNames
        self.userFirstName = userFirstName
        self.ask = ask
        self.appendsSignature = appendsSignature
    }

    /// What a write of `ask` sends from what the composer holds; nil when `inputs` holds no forwarded message (it is
    /// then written as a new message is), or when a part of the ask is longer than is sent.
    public init?(_ inputs: ComposeWriteInputs, ask: WriteAsk) {
        guard let forwarded = inputs.forwarded, WriteKind.forward.lengthRefusal(of: ask) == nil else { return nil }
        let ask = inputs.cleaned(ask)
        guard !ask.isRewrite else {
            self.init(message: nil, ask: ask, appendsSignature: inputs.appendsSignature)
            return
        }
        // No address-to-name directory: the composer holds the forwarded message's author as shown, not its headers.
        let redactor = AIRedactor()
        let (own, quoted) = Self.text(of: forwarded.text, redactor: redactor)
        self.init(subject: inputs.sentSubject,
                  message: Message(author: Self.author(forwarded.author, redactor: redactor), date: forwarded.date, text: own,
                                   quoted: quoted, attachmentCount: max(0, forwarded.attachmentCount)),
                  recipientFirstNames: inputs.recipientFirstNames, userFirstName: inputs.userFirstName, ask: ask,
                  appendsSignature: inputs.appendsSignature)
    }

    /// The forwarded message's text as it is sent. Its writer's own words come first, cleaned as a reply's target
    /// message is (`QuotedHistory.ownWords`, `MailBoilerplate`, the redactor). When those are fewer than `fewOwnWords`
    /// and the message quotes more, what it quotes follows, cleaned the same way. The two together stay within
    /// `limit`, the cut marked.
    static func text(of plainText: String, redactor: AIRedactor, limit: Int = maxCharacters,
                     fewOwnWords: Int = fewOwnWords) -> (own: String, quoted: String) {
        // Bytes bound the read, four to a character so text in any script is read as far; only the head of a very long
        // message is ever copied.
        let bytes = (limit + 512) * 4
        let head = ReplyContextBuilder.normalizedNewlines(QuotedHistory.limited(plainText, to: bytes + 512))
        let headWasCut = plainText.utf8.count > bytes + 512
        let read = QuotedHistory.ownWords(of: head, limit: bytes)
        let ownWasCut = read.utf8.count >= bytes - 4
        var own = MailBoilerplate.trimmedForFullText(read, sawTheEnd: !ownWasCut)
        own = ReplyContextBuilder.prefix(own, characters: limit + 256, wasCut: ownWasCut)
        own = fit(ReplyContextBuilder.tidied(redactor.redact(own)), into: limit, wasCut: ownWasCut)
        guard own.count < fewOwnWords, !ownWasCut else { return (own, "") }

        let room = limit - own.count
        var quoted = MailBoilerplate.trimmedForFullText(QuotedHistory.quotedPart(of: head), sawTheEnd: !headWasCut)
        quoted = ReplyContextBuilder.prefix(quoted, characters: room + 256, wasCut: headWasCut)
        quoted = fit(ReplyContextBuilder.tidied(redactor.redact(quoted)), into: room, wasCut: headWasCut)
        return (own, quoted)
    }

    /// `text` in at most `room` characters, ending in the cut marker when it is not all of what was written: it was
    /// longer than the room, or the read stopped before its end (`wasCut`).
    private static func fit(_ text: String, into room: Int, wasCut: Bool) -> String {
        if !wasCut, text.count <= room { return text }
        let limit = max(0, room - ReplyContextBuilder.cutMarker.count)
        if text.count > limit { return ReplyContextBuilder.cut(text, to: limit) }
        return text.isEmpty ? text : text + ReplyContextBuilder.cutMarker
    }

    /// The forwarded message's writer as the model may name them: the name the composer shows when it is one, on one
    /// line. The composer falls back to the address when the sender gave no name; that becomes “someone at
    /// contoso.com”, never the address.
    static func author(_ shown: String, redactor: AIRedactor) -> String {
        if let name = ReplyContextBuilder.usableName(shown) {
            let line = WriteSubjectLine.oneLine(redactor.redact(name))
            if !line.isEmpty { return String(line.prefix(maxAuthorCharacters)) }
        }
        guard let at = shown.lastIndex(of: "@") else { return "someone" }
        let domain = shown[shown.index(after: at)...].lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ">\"')")))
        let isDomain = !domain.isEmpty && domain.count <= 253 && domain.contains(".")
            && domain.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return isDomain ? "someone at \(domain)" : "someone"
    }
}
