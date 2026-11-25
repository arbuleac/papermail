import Foundation

/// What an event's details show beyond its row (docs/DATA-MODEL.md, `calendar_event_details`): the organizer, the
/// guests and their answers, the notes as text with their links, the call's numbers and codes, and how it repeats.
/// Read from the provider when a card opens (or for the next day's events) and kept beside the event, which takes it
/// when it goes. Every field is optional or defaulted and decoded leniently, so a later build's keys are ignored and a
/// JSON this build cannot read is no details.
public struct CalendarEventDetails: Hashable, Codable, Sendable {
    /// Name and address; nil when none is named.
    public var organizer: EmailAddress?
    public var userIsOrganizer: Bool
    /// Provider order, the user first; the organizer, rooms and resources left out; at most `maxGuests`.
    public var guests: [EventGuest]
    /// Everyone listed before the cap (the organizer, rooms and resources left out).
    public var guestCount: Int
    /// Whether each guest's answer is known: Google always (up to 200 guests), Microsoft only on the organizer's copy.
    public var answersKnown: Bool
    /// The organizer hid the guest list from guests (Google's `guestsCanSeeOtherGuests`, Graph's `hideAttendees`).
    public var guestsHidden: Bool
    public var notes: EventNotes?
    public var call: EventCall?
    /// The series' rule in words (“Every week on Thursday”), “Repeats” when it cannot be said.
    public var repeats: String?

    /// The most guests kept (Quire's `calendarPane.detailsGuestsKept`).
    public static let maxGuests = 100

    public init(organizer: EmailAddress? = nil, userIsOrganizer: Bool = false, guests: [EventGuest] = [], guestCount: Int = 0,
                answersKnown: Bool = false, guestsHidden: Bool = false, notes: EventNotes? = nil, call: EventCall? = nil,
                repeats: String? = nil) {
        self.organizer = organizer
        self.userIsOrganizer = userIsOrganizer
        self.guests = guests
        self.guestCount = guestCount
        self.answersKnown = answersKnown
        self.guestsHidden = guestsHidden
        self.notes = notes
        self.call = call
        self.repeats = repeats
    }

    private enum CodingKeys: String, CodingKey {
        case organizer, userIsOrganizer, guests, guestCount, answersKnown, guestsHidden, notes, call, repeats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        organizer = try? container.decodeIfPresent(EmailAddress.self, forKey: .organizer)
        userIsOrganizer = (try? container.decodeIfPresent(Bool.self, forKey: .userIsOrganizer)) ?? false
        guests = (try? container.decodeIfPresent([EventGuest].self, forKey: .guests)) ?? []
        guestCount = (try? container.decodeIfPresent(Int.self, forKey: .guestCount)) ?? guests.count
        answersKnown = (try? container.decodeIfPresent(Bool.self, forKey: .answersKnown)) ?? false
        guestsHidden = (try? container.decodeIfPresent(Bool.self, forKey: .guestsHidden)) ?? false
        notes = try? container.decodeIfPresent(EventNotes.self, forKey: .notes)
        call = try? container.decodeIfPresent(EventCall.self, forKey: .call)
        repeats = try? container.decodeIfPresent(String.self, forKey: .repeats)
    }
}
