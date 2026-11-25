import Foundation

/// Everything Help Me Write sends about a new message besides Paper's fixed instructions: its subject, the first names
/// of the people it is to, the user's first name when Paper knows it, and the user's ask. There is no mail in it: a new
/// message answers nothing, so nothing is read from the store, no other conversation, no earlier mail with these
/// people, no attachment names and no addresses. `WritePrompt` turns it into text.
///
/// A forward whose forwarded message is not there to read is written from one of these too.
public struct NewMessageContext: Sendable, Hashable {
    /// The Subject as typed: redacted, one line, at most 300 characters; empty when there is none.
    public var subject: String
    /// The first names of the To recipients, at most four; never Cc, never Bcc, never an address.
    public var recipientFirstNames: [String]
    /// The user's first name, to sign with; nil when Paper does not know it.
    public var userFirstName: String?
    public var ask: WriteAsk
    /// The body ends in the account's signature, so the model leaves out a sign-off name.
    public var appendsSignature: Bool
    /// The answer is to begin with a subject line, which becomes the message's subject.
    public var wantsSubject: Bool
    /// The body is still what a mail link or a Service filled in: the text around a selection to rewrite is redacted,
    /// cut only at blanks (`WriteRewriteFrame`), as the notes are.
    public var redactsAround: Bool

    public init(subject: String = "", recipientFirstNames: [String] = [], userFirstName: String? = nil, ask: WriteAsk,
                appendsSignature: Bool = false, wantsSubject: Bool = false, redactsAround: Bool = false) {
        self.subject = subject
        self.recipientFirstNames = recipientFirstNames
        self.userFirstName = userFirstName
        self.ask = ask
        self.appendsSignature = appendsSignature
        self.wantsSubject = wantsSubject
        self.redactsAround = redactsAround
    }

    /// What a write of `ask` sends from what the composer holds; nil when nothing may be sent: the ask gives nothing to
    /// write from, or a part of it is longer than is sent (never cut: the instruction can be the whole brief).
    ///
    /// A rewrite of a selection reads what a whole write reads (the subject, the names, the user's first name), so the
    /// part fits the message it stands in; it never asks for a subject.
    public init?(_ inputs: ComposeWriteInputs, ask: WriteAsk) {
        guard WriteKind.newMessage.lengthRefusal(of: ask) == nil else { return nil }
        let asked = ask
        let ask = inputs.cleaned(ask)
        // A selection of pictures alone has nothing to rewrite, and is never written over as a whole message.
        guard !WriteKind.newMessage.hasNothingToWriteFrom(ask), ask.isRewrite == asked.isRewrite else { return nil }
        guard !ask.isRewrite else {
            self.init(subject: inputs.sentSubject, recipientFirstNames: inputs.recipientFirstNames,
                      userFirstName: inputs.userFirstName, ask: ask, appendsSignature: inputs.appendsSignature,
                      wantsSubject: false, redactsAround: inputs.redactsOwnText)
            return
        }
        // Send asks about an empty Subject by this same test, so the field a subject is proposed for is the one Send
        // would ask about, and a typed subject never travels beside a request for another.
        let subjectIsEmpty = inputs.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.init(subject: inputs.sentSubject, recipientFirstNames: inputs.recipientFirstNames,
                  userFirstName: inputs.userFirstName, ask: ask, appendsSignature: inputs.appendsSignature,
                  wantsSubject: inputs.wantsSubject && inputs.forwarded == nil && subjectIsEmpty,
                  redactsAround: inputs.redactsOwnText)
    }
}
