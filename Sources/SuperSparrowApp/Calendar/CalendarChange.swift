/// What moved in `CalendarState`, so each view does only the work its change calls for: a minute's tick redraws the
/// now line's band, a key-state change redraws the selected events, and only a change of what is drawn refits.
struct CalendarChange: OptionSet, Sendable {
    let rawValue: Int

    /// Events, marks, the selection's pencil, rule and hatch, the scope or the accounts' inks: refit and redraw.
    static let content = CalendarChange(rawValue: 1 << 0)
    /// The minute moved: the now line and the next call's Join.
    static let now = CalendarChange(rawValue: 1 << 1)
    /// Today is another day (midnight, a zone or locale change): kickers, today's marks, the now line's day.
    static let day = CalendarChange(rawValue: 1 << 2)
    /// The shown day, the shown week or the span moved.
    static let shown = CalendarChange(rawValue: 1 << 3)
    /// An account's calendar state (the foot) or Connect's progress.
    static let statuses = CalendarChange(rawValue: 1 << 4)
    /// The window's key state the margin rule follows.
    static let windowKey = CalendarChange(rawValue: 1 << 5)
    /// The selected conversation changed, or its context finished reading.
    static let selection = CalendarChange(rawValue: 1 << 6)
}

/// A view that draws from `CalendarState`.
@MainActor
protocol CalendarStateObserver: AnyObject {
    func calendarState(_ state: CalendarState, didChange change: CalendarChange)
}
