/// What the window shows of the calendar: the day column beside the reader (or its strip), or the week in the reader's
/// place (spec §5.54). The state observes only what the span needs, so the week's seven days are read only while it
/// shows.
enum CalendarSpan: Hashable, Sendable {
    case day
    case week
}
