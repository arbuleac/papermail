import Foundation

/// What an event's details card reads while it is open (`CalendarStoring.observeEventCard`): the row, its stored
/// details, and where the newest answer covering it stands in the outbox.
public struct EventCardState: Hashable, Sendable {
    public var event: CalendarEvent
    public var details: StoredEventDetails?
    public var answer: EventAnswerState?

    public init(event: CalendarEvent, details: StoredEventDetails? = nil, answer: EventAnswerState? = nil) {
        self.event = event
        self.details = details
        self.answer = answer
    }
}
