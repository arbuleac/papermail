import Foundation

/// A day and time of day a message's text names (“Could we move our call to Friday at 3pm?”), found once on this Mac
/// when its body is stored (`MailTimeDetector`, the system's date detector) and kept beside it (docs/DATA-MODEL.md,
/// "Mail times"), so selecting the conversation never reads its text again. The calendar marks it while the
/// conversation is selected, and B sets time aside there. A date without a time of day (“charged on 1 December”) is
/// never one.
public struct MailTime: Hashable, Codable, Sendable {
    public var messageID: MessageID
    /// The instant named, in this Mac's zone as the text was read.
    public var start: Date
    /// The length the text names (“from 3 to 4pm”), when it names one.
    public var duration: TimeInterval?
    /// The words it was found in, as they appear in the message's plain text, for the reader to underline.
    public var phrase: String

    public init(messageID: MessageID, start: Date, duration: TimeInterval? = nil, phrase: String) {
        self.messageID = messageID
        self.start = start
        self.duration = duration
        self.phrase = phrase
    }
}
