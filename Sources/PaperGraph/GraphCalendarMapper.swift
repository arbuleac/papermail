import Foundation
import PaperCore

/// Reads Outlook's events (a `calendarView` page, a block Graph just created) into the store's `CalendarEvent`. Times
/// come in UTC (`Prefer: outlook.timezone="UTC"`), so a timed event is the instant its `dateTime` names. An all-day event
/// is held as its own dates' UTC midnights (floating): Exchange keeps it as midnight to midnight in the zone it was made
/// in, which the UTC preference moves, so its dates are read back in that zone (`GraphEventTime.allDay`).
struct GraphCalendarMapper {
    let accountID: AccountID

    /// Nil for an event the calendar leaves out (cancelled) or cannot place (no id, a start or end that does not read).
    func event(from graph: GraphEvent) -> CalendarEvent? {
        guard graph.isCancelled != true, let providerID = Self.nonEmpty(graph.id),
              let startValue = graph.start, let endValue = graph.end,
              let start = GraphEventTime.read(startValue), let end = GraphEventTime.read(endValue) else {
            return nil
        }
        let isAllDay = graph.isAllDay ?? false
        var first = start.date
        var last = end.date
        if isAllDay {
            guard let startDay = GraphEventTime.allDay(startValue, originalZone: graph.originalStartTimeZone),
                  let endDay = GraphEventTime.allDay(endValue, originalZone: graph.originalEndTimeZone ?? graph.originalStartTimeZone)
            else { return nil }
            first = startDay
            // The end is exclusive; one that names no later day still holds its own day rather than none.
            last = endDay > startDay ? endDay : startDay.addingTimeInterval(86_400)
        }
        let isOrganizer = graph.isOrganizer ?? false
        let response = Self.response(graph.responseStatus?.response, isOrganizer: isOrganizer)
        let location = Self.nonEmpty(graph.location?.displayName)
        let joinURL = Self.webAddress(graph.onlineMeeting?.joinUrl) ?? Self.webAddress(graph.onlineMeetingUrl)
            ?? EventLinkPolicy.callAddress(inLocation: location)
        let type = graph.type?.lowercased()
        let isOccurrence = type == "occurrence" || type == "exception"
        return CalendarEvent(
            id: CalendarEvent.localID(accountID: accountID, providerID: providerID),
            accountID: accountID,
            providerID: providerID,
            title: graph.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            location: location,
            start: first,
            end: max(last, first),
            isAllDay: isAllDay,
            response: response,
            isFree: graph.showAs?.lowercased() == "free",
            joinURL: joinURL,
            webURL: Self.webAddress(graph.webLink),
            organizer: isOrganizer || response == .organizer ? nil : Self.organizer(graph.organizer?.emailAddress),
            invitationUID: Self.nonEmpty(graph.iCalUId),
            clientKey: Self.nonEmpty(graph.transactionId),
            sync: .synced,
            updatedAt: graph.lastModifiedDateTime.flatMap(GraphDate.parse),
            seriesID: isOccurrence ? Self.nonEmpty(graph.seriesMasterId) : nil,
            originalStart: isOccurrence ? graph.originalStart.flatMap(GraphDate.parse) : nil,
            timeZone: isAllDay ? nil : graph.originalStartTimeZone.flatMap { CalendarTimeZones.timeZone(named: $0)?.identifier },
            kind: Self.kind(graph.showAs),
            callService: Self.callService(graph.onlineMeetingProvider, joinURL: joinURL),
            version: Self.nonEmpty(graph.changeKey)
        )
    }

    /// Out of office and working elsewhere; every other `showAs` is an ordinary event.
    static func kind(_ showAs: String?) -> CalendarEvent.Kind? {
        switch showAs?.lowercased() {
        case "oof": return .outOfOffice
        case "workingelsewhere": return .workingElsewhere
        default: return nil
        }
    }

    /// The call's service: Graph's own word for Teams and Skype, else the join address's host; nil without a call.
    static func callService(_ provider: String?, joinURL: String?) -> CallService? {
        guard let joinURL else { return nil }
        switch provider?.lowercased() {
        case "teamsforbusiness": return .teams
        case "skypeforbusiness", "skypeforconsumer": return .skype
        default: return CallService(joinURL: joinURL) ?? .other
        }
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

    /// Only an https address: Join and Open in Outlook open nothing else (the window refuses any other scheme, http
    /// included), so a link it would refuse is never offered as a button that does nothing.
    private static func webAddress(_ value: String?) -> String? {
        nonEmpty(value).flatMap { CalendarInvitationReader.webAddress($0)?.scheme?.lowercased() == "https" ? $0 : nil }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
