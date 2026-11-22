import Foundation
import PaperCore

/// What the calendar views ask of the window that holds them (spec §5.54). The views only read the store, through
/// `CalendarState`; every change (a turn of the day, time set aside, an answer, a removal) is the shell's to make,
/// store first, as every other action is, so it gets its toast and its undo.
@MainActor
protocol CalendarViewDelegate: AnyObject {
    /// ‹ › (or [ ]) in the column: a day back or forward; in the week, seven.
    func turnDay(by days: Int)
    /// Today, in the column; This Week, in the week.
    func goToToday()
    /// A day cell was clicked (or ← → moved the cells): show that day in the column.
    func selectDay(_ day: Date)
    /// A day's heading in the week was clicked: back to the reader and the column, on that day.
    func openWeekHeading(day: Date)
    /// A pencilled invitation drawn from mail was clicked, or Show the mail on a Later mark: select its conversation.
    func selectConversation(_ id: ConversationID)
    /// Set 30 minutes aside for `conversation` from `start`: a row dropped on a timeline, or a click on the selected
    /// mail's time.
    func blockTime(for conversation: ConversationID, at start: Date)
    /// Set the first free half hour of `day` aside for `conversation`: a row dropped on a day cell. The shell says
    /// “No free half hour on Sat 21 Nov” when there is none.
    func blockTimeFirstFree(for conversation: ConversationID, on day: Date)
    /// Remove, in the details of time set aside from this Mac.
    func removeEvent(_ event: CalendarEvent)
    /// Join, Open in Google Calendar or Outlook, How to turn it on.
    func openURL(_ url: URL)
    /// Show the mail, in the details of time set aside for a mail.
    func showMail(_ message: MessageID)
    /// Show the mail, in the details of a Send Later mark: the message waiting in the Outbox.
    func showPendingSend(id: String)
    /// Connect, in the foot: ask each of these accounts for the calendar permission, one after another.
    func connect(accountIDs: [AccountID])
    /// Accept · Tentative · Decline on the week's invitation card (spec §5.14 rules: no toast, no undo).
    func answerInvitation(_ response: InvitationResponse, for message: MessageID)
    /// A click on the folded strip: open the column over the reader's edge (or close it).
    func openStrip()
    /// The Day button in the week's header: what D does.
    func toggleDayColumn()
    /// The Week button in the week's header: what W does.
    func toggleWeek()
}
