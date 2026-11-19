import Foundation
import SSCore

/// A mark on the calendar that is not an event (spec §5.54, “Marks”): a conversation coming back from Later, a message
/// Send Later sends, or a time the selected mail names. The fit places it (`CalendarFit.Mark`); this says what it is.
struct CalendarMark: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A snoozed conversation comes back (§5.45).
        case later(ConversationID)
        /// A Send Later message goes (§5.46), by its id in the outbox.
        case sendLater(id: String, accountID: AccountID)
        /// A time the selected conversation's mail names: a click, or B, sets 30 minutes aside there.
        case mailTime(ConversationID, MessageID)
    }

    var id: String
    var kind: Kind
    var start: Date
    /// How long it keeps its hours open: a minute for a return or a send, the time the mail names (30 minutes when it
    /// names no length) for a mail's time.
    var span: TimeInterval
    /// The subject, for Later and Send Later; the phrase, for a mail's time.
    var title: String

    var fitMark: CalendarFit.Mark { CalendarFit.Mark(id: id, start: start, span: span) }

    var isMailTime: Bool {
        if case .mailTime = kind { return true }
        return false
    }
}
