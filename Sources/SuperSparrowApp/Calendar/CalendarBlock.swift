import Foundation
import SSCore

/// Time set aside for a mail (spec §5.54, “Setting time aside”; BRIEF decision 4): 30 minutes in the calendar of the
/// mail's account, titled with its subject, busy, linking back to the mail. The shell writes it through
/// `MailClient.addCalendarEvent` (store first, as `creating`), and the engine creates it on the provider, which writes the
/// description and leaves out guests and reminders.
enum CalendarBlock {
    /// The block for `conversation` from `start`, set aside for its newest message that is not a draft; nil when the
    /// store holds none of its messages.
    static func event(for conversation: ConversationID, at start: Date, store: MailStoring) -> CalendarEvent? {
        let messages = ((try? store.messages(in: conversation)) ?? []).filter { !$0.roles.contains(.drafts) }
        guard let newest = messages.max(by: { $0.date < $1.date }) else { return nil }
        let subject = newest.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(id: CalendarEvent.newLocalID(accountID: conversation.accountID), accountID: conversation.accountID,
                             providerID: nil, title: subject.isEmpty ? "No subject" : subject, start: start,
                             end: start.addingTimeInterval(CalendarState.blockLength), response: .organizer,
                             sourceMessage: newest.id, clientKey: CalendarEvent.newClientKey(), sync: .creating)
    }
}

extension CalendarState {
    /// The first free half hour of `day` (a row dropped on its cell): on the quarter hour, from now on today and from
    /// 09:00 on later days, until 18:00. Busy is every account's shown, not free, not all-day event: one person keeps
    /// the time. Reads the store for that day; an action, not a frame.
    func firstFreeHalfHour(on day: Date) -> Date? {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let events = (try? store.calendarEvents(in: DateInterval(start: start, end: end), accountIDs: nil)) ?? []
        return CalendarFit.firstFreeHalfHour(on: start, events: events, now: now, calendar: calendar)
    }

    /// Where B sets 30 minutes aside for the selected conversation (spec §5.54): the first time its mail names that is
    /// still ahead and not set aside yet; otherwise the first free half hour from `day` on (the day the column shows,
    /// today's when it shows a day past or is hidden; while the week shows, its first day or today, whichever is later),
    /// day by day for up to three weeks, passing over a Saturday or Sunday unless it is `day` and `dayIsShown`. Nil when
    /// there is none, or when nothing is selected.
    func blockStart(from day: Date, dayIsShown: Bool) -> Date? {
        guard let selection else { return nil }
        return blockStart(for: selection, from: day, dayIsShown: dayIsShown)
    }

    /// As `blockStart(from:dayIsShown:)`, for a conversation's context read by the caller: B pressed before the
    /// selection's read landed, or in a reader window, whose conversation is not the list's.
    func blockStart(for selection: CalendarSelection, from day: Date, dayIsShown: Bool) -> Date? {
        let setAside = Set(events.filter { $0.isShown && $0.sourceMessage.map(selection.messageIDs.contains) == true }.map(\.start))
        if let time = selection.mailTimes.first(where: { $0.start > now && !setAside.contains($0.start) }) { return time.start }
        let first = max(calendar.startOfDay(for: day), today)
        let end = calendar.date(byAdding: .day, value: Self.blockSearchDays + 1, to: first) ?? first
        let events = (try? store.calendarEvents(in: DateInterval(start: first, end: end), accountIDs: nil)) ?? []
        return CalendarFit.firstFreeHalfHour(searchingFrom: day, dayIsShown: dayIsShown, events: events, now: now, calendar: calendar,
                                             searchDays: Self.blockSearchDays)
    }

    /// Three weeks, as far as B looks for a free half hour.
    static let blockSearchDays = 21
}
