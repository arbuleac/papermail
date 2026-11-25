import Foundation
import PaperCore

/// Turns a Google Calendar event read for its details (`GmailProvider.detailsFields`) into `CalendarEventDetails`: the
/// guests without rooms, resources and the organizer, the user first; the conference's numbers, PIN, meeting code and
/// passcode; the description as text with its https and tel links (`EventNotesReader`). Pure.
enum GoogleCalendarDetailsMapper {
    /// Past this many guests Google may leave answers out (`maxAttendees`), so they are not said.
    static let answersKnownUpTo = 200

    static func details(from item: GoogleCalendarEvent, repeats: String?) -> CalendarEventDetails {
        var details = CalendarEventDetails()
        if let email = trimmed(item.organizer?.email) {
            details.organizer = EmailAddress(name: trimmed(item.organizer?.displayName), address: email)
        }
        details.userIsOrganizer = item.organizer?.isSelf == true
        let attendees = item.attendees ?? []
        let listed = attendees.filter { $0.resource != true && $0.organizer != true && trimmed($0.email) != nil }
        let guests = listed.map { person in
            EventGuest(name: trimmed(person.displayName), address: trimmed(person.email) ?? "",
                       response: response(person.responseStatus), isSelf: person.isSelf == true)
        }
        details.guestCount = guests.count
        details.guests = Array((guests.filter(\.isSelf) + guests.filter { !$0.isSelf }).prefix(CalendarEventDetails.maxGuests))
        details.answersKnown = attendees.count <= answersKnownUpTo
        if item.guestsCanSeeOtherGuests == false, !details.userIsOrganizer {
            details.guestsHidden = true
            details.guests = []
            details.guestCount = 0
        }
        details.notes = EventNotesReader.notes(from: item.description)
        details.call = call(from: item, notes: details.notes)
        details.repeats = repeats
        return details
    }

    /// The call's numbers and codes, and a join address from the notes when the conference names none.
    static func call(from item: GoogleCalendarEvent, notes: EventNotes?) -> EventCall? {
        var call = EventCall()
        let entries = item.conferenceData?.entryPoints ?? []
        let video = entries.first { $0.entryPointType == "video" }
        call.meetingID = trimmed(video?.meetingCode)
        call.passcode = trimmed(video?.passcode) ?? trimmed(video?.password) ?? trimmed(video?.accessCode)
        for entry in entries where entry.entryPointType == "phone" && call.phones.count < EventCall.maxPhones {
            guard let uri = trimmed(entry.uri), uri.lowercased().hasPrefix("tel:") else { continue }
            let number = String(uri.dropFirst(4))
            let digits = dialDigits(number)
            guard digits.contains(where: \.isNumber) else { continue }
            let pin = trimmed(entry.pin)
            let dial = digits + (pin.map { ",," + dialDigits($0) + "#" } ?? "")
            call.phones.append(EventPhone(number: trimmed(entry.label) ?? number, dial: dial, region: trimmed(entry.regionCode),
                                          pin: pin))
        }
        call.pinLabel = .pin
        call.morePhonesURL = entries.first { $0.entryPointType == "more" && EventLinkPolicy.web($0.uri) != nil }?.uri
        let videoJoin = video.flatMap { EventLinkPolicy.web($0.uri) }
        if videoJoin == nil { call.joinURL = EventNotesReader.joinAddress(in: notes) }
        return call.isEmpty ? nil : call
    }

    /// A number's dialling characters: `+` and digits.
    static func dialDigits(_ text: String) -> String {
        String(text.filter { $0 == "+" || ($0.isASCII && $0.isNumber) })
    }

    static func response(_ status: String?) -> InvitationResponse? {
        switch status {
        case "accepted": return .accepted
        case "tentative": return .tentative
        case "declined": return .declined
        case "needsAction": return .needsAction
        default: return nil
        }
    }

    /// The series' rule in words, from its `recurrence` lines: the first RRULE, said in the series' own zone; “Repeats”
    /// when it cannot be read.
    static func repeats(from series: GoogleCalendarSeries, mapper: GoogleCalendarMapper, account: CalendarAccountFacts) -> String {
        guard let line = series.recurrence?.first(where: { $0.uppercased().hasPrefix("RRULE:") }),
              let rule = RecurrenceRule(rrule: String(line.dropFirst("RRULE:".count))),
              let start = series.start, let times = mapper.times(start: start, end: series.end) else { return "Repeats" }
        let zone = times.isAllDay ? TimeZone(identifier: "UTC") ?? account.timeZone
            : start.timeZone.flatMap(TimeZone.init(identifier:)) ?? account.timeZone
        return rule.words(start: times.start, timeZone: zone, locale: account.locale)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
