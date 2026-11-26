import Foundation
import PaperCore

/// Turns an Outlook event read for its details into `CalendarEventDetails`: guests without rooms and the organizer, the
/// user first (found by the account's address); the dial-in numbers and conference ID Teams states; the body as text
/// with its https and tel links (`EventNotesReader`), and the meeting ID and passcode written in it when Graph states
/// none. An attendee's copy reports `none` for every other guest, so answers are known only on the organizer's. Pure.
enum GraphCalendarDetailsMapper {
    static func details(from event: GraphEvent, accountEmail: String, repeats: String?) -> CalendarEventDetails {
        var details = CalendarEventDetails()
        let organizerAddress = event.organizer?.emailAddress?.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let organizerAddress, !organizerAddress.isEmpty {
            details.organizer = EmailAddress(name: nonEmpty(event.organizer?.emailAddress?.name), address: organizerAddress)
        }
        let isOrganizer = event.isOrganizer ?? false
        details.userIsOrganizer = isOrganizer
        details.answersKnown = isOrganizer
        let guests: [EventGuest] = (event.attendees ?? []).compactMap { attendee in
            guard attendee.type?.lowercased() != "resource",
                  let address = nonEmpty(attendee.emailAddress?.address),
                  address.caseInsensitiveCompare(organizerAddress ?? "") != .orderedSame else { return nil }
            return EventGuest(name: nonEmpty(attendee.emailAddress?.name), address: address,
                              response: response(attendee.status?.response),
                              isSelf: address.caseInsensitiveCompare(accountEmail) == .orderedSame)
        }
        details.guestCount = guests.count
        details.guests = Array((guests.filter(\.isSelf) + guests.filter { !$0.isSelf }).prefix(CalendarEventDetails.maxGuests))
        if event.hideAttendees == true, !isOrganizer {
            details.guestsHidden = true
            details.guests = []
            details.guestCount = 0
        }
        details.notes = EventNotesReader.notes(from: event.body?.content)
        details.call = call(from: event.onlineMeeting, notes: details.notes, hasJoin: hasJoin(event))
        details.repeats = repeats
        return details
    }

    /// The event names its own call, as its row reads it: Teams' join address, else the online meeting's, else one in the
    /// location (a Zoom or Teams link an organizer typed there). The card then takes the row's address, and the numbers
    /// and codes the notes give go with that call, never with another the notes link to.
    private static func hasJoin(_ event: GraphEvent) -> Bool {
        GraphCalendarMapper.joinURL(of: event) != nil
    }

    /// The numbers Teams states (the toll number, then each toll-free one), each dialled with the conference ID; the
    /// meeting ID and passcode from the notes; a join address from the notes when the event names none.
    static func call(from meeting: GraphOnlineMeeting?, notes: EventNotes?, hasJoin: Bool) -> EventCall? {
        var call = EventCall(pinLabel: .conferenceID)
        let conference = nonEmpty(meeting?.conferenceId)
        let numbers = ([meeting?.tollNumber] + (meeting?.tollFreeNumbers ?? []).map(Optional.some)).compactMap(nonEmpty)
        for number in numbers where call.phones.count < EventCall.maxPhones {
            let digits = GoogleLikeDigits.dial(number)
            guard digits.contains(where: \.isNumber) else { continue }
            let dial = digits + (conference.map { ",," + GoogleLikeDigits.dial($0) + "#" } ?? "")
            call.phones.append(EventPhone(number: number, dial: dial, region: nil, pin: conference))
        }
        if let notes {
            let codes = EventNotesReader.callCodes(in: notes.text)
            call.meetingID = codes.meetingID
            call.passcode = codes.passcode
        }
        if !hasJoin { call.joinURL = EventNotesReader.joinAddress(in: notes) }
        return call.isEmpty ? nil : call
    }

    static func response(_ value: String?) -> InvitationResponse? {
        switch value?.lowercased() {
        case "accepted": return .accepted
        case "tentativelyaccepted": return .tentative
        case "declined": return .declined
        case "notresponded": return .needsAction
        default: return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A number's dialling characters: `+` and digits.
    private enum GoogleLikeDigits {
        static func dial(_ text: String) -> String {
            String(text.filter { $0 == "+" || ($0.isASCII && $0.isNumber) })
        }
    }
}
