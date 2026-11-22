import Foundation
import PaperCore

/// Body of `POST /me/events` for time set aside for a mail: busy and private, no attendees (none are named, so Exchange
/// sends no invitation), no reminder, and one plain line saying what it is for.
struct GraphEventPayload: Encodable, Sendable {
    struct DateTimeZone: Encodable, Sendable {
        var dateTime: String
        var timeZone = "UTC"
    }

    var subject: String
    var start: DateTimeZone
    var end: DateTimeZone
    var showAs = "busy"
    /// Private: the subject is a mail's, so delegates and colleagues who see the calendar see only that the time is
    /// busy. The owner still sees it all.
    var sensitivity = "private"
    var isReminderOn = false
    var body: GraphBodyPayload
    /// Graph's guard against a second copy when a create is sent again after a lost reply; reads report it back.
    var transactionId: String?

    init(_ event: CalendarEvent) {
        subject = event.title
        start = DateTimeZone(dateTime: GraphEventTime.dateTime(event.start))
        end = DateTimeZone(dateTime: GraphEventTime.dateTime(event.end))
        // Decision 4 would add the message's `webLink`, but the store keeps none for a message and the provider gets the
        // event alone: the line names the subject only, rather than spend a request on the link.
        body = GraphBodyPayload(contentType: "text", content: "Set aside in Paper for: \(event.title)")
        transactionId = event.clientKey
    }
}
