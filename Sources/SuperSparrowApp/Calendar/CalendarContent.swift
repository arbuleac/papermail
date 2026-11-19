import Foundation
import SSCore

/// What a calendar view draws for its days, gathered once from `CalendarState` (the store's events, the marks and the
/// selected conversation) and handed to `CalendarFit` with the view's own size. Everything here is account-scoped and
/// already filtered to what is shown, so the views never ask the store anything.
struct CalendarContent: Sendable {
    /// The days, each at its first instant.
    var days: [Date]
    /// The events to lay out: shown ones of the scope's accounts on these days, with the selected invitation's pencil
    /// when the calendar holds no copy of it.
    var events: [CalendarEvent]
    var marks: [CalendarMark]
    /// The selected conversation's events: its invitation's (or the pencil) and time set aside for it. They carry the
    /// margin rule and are drawn above their neighbours.
    var selectedEventIDs: Set<String>
    /// The invitation's event and the times it shares with others: hatched (spec §5.54, “The selected conversation”).
    var hatches: [String: [DateInterval]]
    /// What the invitation overlaps, by title, for VoiceOver (“overlaps Hiring sync”).
    var overlapTitles: [String: [String]]
    /// The pencil drawn from the selected mail, when there is one on these days.
    var pencilID: String?
    /// Bumped on every change of what this holds: a view refits only when it moves.
    var version: Int

    static let empty = CalendarContent(days: [], events: [], marks: [], selectedEventIDs: [], hatches: [:],
                                       overlapTitles: [:], pencilID: nil, version: -1)

    var fitMarks: [CalendarFit.Mark] { marks.map(\.fitMark) }

    func mark(withID id: String) -> CalendarMark? {
        marks.first { $0.id == id }
    }
}
