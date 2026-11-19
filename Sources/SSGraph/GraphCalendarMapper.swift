import Foundation
import SSCore

/// Reads Outlook's events (a `calendarView` page, a block Graph just created) into the store's `CalendarEvent`. Times
/// come in UTC (`Prefer: outlook.timezone="UTC"`), so a timed event is the instant its `dateTime` names. An all-day event
/// keeps the date written, held as that date's UTC midnight (floating), whatever zone Graph names beside it: Exchange
/// writes all-day events at midnight of their own dates, and shifting them through a zone would move them a day.
struct GraphCalendarMapper {
    let accountID: AccountID

    /// Nil for an event the calendar leaves out (cancelled) or cannot place (no id, a start or end that does not read).
    func event(from graph: GraphEvent) -> CalendarEvent? {
        guard graph.isCancelled != true, let providerID = Self.nonEmpty(graph.id),
              let start = graph.start.flatMap(GraphEventTime.read), let end = graph.end.flatMap(GraphEventTime.read) else {
            return nil
        }
        let isAllDay = graph.isAllDay ?? false
        var first = start.date
        var last = end.date
        if isAllDay {
            guard let startDay = start.day, let endDay = end.day else { return nil }
            first = startDay
            // The end is exclusive; one that names no later day still holds its own day rather than none.
            last = endDay > startDay ? endDay : startDay.addingTimeInterval(86_400)
        }
        let isOrganizer = graph.isOrganizer ?? false
        let response = Self.response(graph.responseStatus?.response, isOrganizer: isOrganizer)
        return CalendarEvent(
            id: CalendarEvent.localID(accountID: accountID, providerID: providerID),
            accountID: accountID,
            providerID: providerID,
            title: graph.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            location: Self.nonEmpty(graph.location?.displayName),
            start: first,
            end: max(last, first),
            isAllDay: isAllDay,
            response: response,
            isFree: graph.showAs?.lowercased() == "free",
            joinURL: Self.webAddress(graph.onlineMeeting?.joinUrl) ?? Self.webAddress(graph.onlineMeetingUrl),
            webURL: Self.webAddress(graph.webLink),
            organizer: isOrganizer || response == .organizer ? nil : Self.organizer(graph.organizer?.emailAddress),
            invitationUID: Self.nonEmpty(graph.iCalUId),
            clientKey: Self.nonEmpty(graph.transactionId),
            sync: .synced,
            updatedAt: graph.lastModifiedDateTime.flatMap(GraphDate.parse)
        )
    }

    /// Graph's answer words. `none` and `notResponded` are an invitation not answered yet, except on an event the user
    /// organized, which has nothing to answer.
    static func response(_ value: String?, isOrganizer: Bool) -> CalendarEvent.Response {
        switch value?.lowercased() {
        case "organizer": return .organizer
        case "accepted": return .accepted
        case "tentativelyaccepted": return .tentative
        case "declined": return .declined
        default: return isOrganizer ? .organizer : .needsAction
        }
    }

    /// The name, or the address when there is no name.
    private static func organizer(_ address: GraphEmailAddress?) -> String? {
        nonEmpty(address?.name) ?? nonEmpty(address?.address)
    }

    /// Only a web address: Join and Open in Outlook hand it to the browser.
    private static func webAddress(_ value: String?) -> String? {
        nonEmpty(value).flatMap { CalendarInvitationReader.webAddress($0) == nil ? nil : $0 }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
