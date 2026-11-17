import Foundation

// Decodable shapes of the Graph resources this module reads. Every property except `id` is optional because
// `$select` and delta responses return partial objects.

struct GraphListResponse<Item: Decodable>: Decodable {
    var value: [Item]
    var nextLink: String?
    var deltaLink: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
        case deltaLink = "@odata.deltaLink"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent([Item].self, forKey: .value) ?? []
        nextLink = try container.decodeIfPresent(String.self, forKey: .nextLink)
        deltaLink = try container.decodeIfPresent(String.self, forKey: .deltaLink)
    }
}

struct GraphEmailAddress: Decodable, Sendable {
    var name: String?
    var address: String?
}

struct GraphRecipient: Decodable, Sendable {
    var emailAddress: GraphEmailAddress?
}

struct GraphFlag: Decodable, Sendable {
    var flagStatus: String?
}

struct GraphItemBody: Decodable, Sendable {
    var contentType: String?
    var content: String?
}

struct GraphInternetHeader: Decodable, Sendable {
    var name: String?
    var value: String?
}

struct GraphRemoved: Decodable, Sendable {
    var reason: String?
}

struct GraphMessage: Decodable, Sendable {
    var id: String
    var conversationId: String?
    var internetMessageId: String?
    var subject: String?
    var bodyPreview: String?
    var from: GraphRecipient?
    var toRecipients: [GraphRecipient]?
    var ccRecipients: [GraphRecipient]?
    var bccRecipients: [GraphRecipient]?
    var replyTo: [GraphRecipient]?
    var receivedDateTime: String?
    var isRead: Bool?
    var flag: GraphFlag?
    var inferenceClassification: String?
    var parentFolderId: String?
    var hasAttachments: Bool?
    var changeKey: String?
    var isDraft: Bool?
    var body: GraphItemBody?
    var uniqueBody: GraphItemBody?
    var internetMessageHeaders: [GraphInternetHeader]?
    /// Present on delta items that left the folder (deleted or moved).
    var removed: GraphRemoved?
    /// The derived type of an event message (`#microsoft.graph.eventMessageRequest`, `#microsoft.graph.eventMessage`),
    /// which Graph names on every instance that is not a plain message.
    var odataType: String?
    /// Event messages only: `meetingRequest`, `meetingCancelled`, or a response to the organizer.
    var meetingMessageType: String?
    /// Event messages only, when expanded (`$expand=microsoft.graph.eventMessage/event`).
    var event: GraphEvent?

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, internetMessageId, subject, bodyPreview, from
        case toRecipients, ccRecipients, bccRecipients, replyTo, receivedDateTime, isRead, flag
        case inferenceClassification, parentFolderId, hasAttachments, changeKey, isDraft
        case body, uniqueBody, internetMessageHeaders
        case removed = "@removed"
        case odataType = "@odata.type"
        case meetingMessageType, event
    }

    /// An event message: a meeting request, a cancellation, or a response the organizer receives.
    var isEventMessage: Bool {
        odataType?.lowercased().contains("eventmessage") ?? false
    }

    /// A response the organizer receives (`#microsoft.graph.eventMessageResponse`): no invitation to show.
    var isEventResponse: Bool {
        odataType?.lowercased().hasSuffix("eventmessageresponse") ?? false
    }
}

/// A date and time in a named zone, as Graph writes an event's start and end.
struct GraphDateTimeZone: Decodable, Sendable {
    var dateTime: String?
    var timeZone: String?
}

struct GraphResponseStatus: Decodable, Sendable {
    var response: String?
}

struct GraphAttendee: Decodable, Sendable {
    var type: String?
    var status: GraphResponseStatus?
    var emailAddress: GraphEmailAddress?
}

struct GraphLocation: Decodable, Sendable {
    var displayName: String?
}

struct GraphOnlineMeeting: Decodable, Sendable {
    var joinUrl: String?
}

struct GraphRecurrencePattern: Decodable, Sendable {
    var type: String?
    var interval: Int?
    var month: Int?
    var dayOfMonth: Int?
    var daysOfWeek: [String]?
    var index: String?
}

struct GraphRecurrenceRange: Decodable, Sendable {
    var type: String?
    var startDate: String?
    var endDate: String?
    var numberOfOccurrences: Int?
}

struct GraphPatternedRecurrence: Decodable, Sendable {
    var pattern: GraphRecurrencePattern?
    var range: GraphRecurrenceRange?
}

/// The calendar event an event message is about.
struct GraphEvent: Decodable, Sendable {
    var id: String?
    var iCalUId: String?
    var subject: String?
    var isAllDay: Bool?
    var isCancelled: Bool?
    var isOrganizer: Bool?
    var type: String?
    var start: GraphDateTimeZone?
    var end: GraphDateTimeZone?
    var originalStart: String?
    var originalStartTimeZone: String?
    var location: GraphLocation?
    var organizer: GraphRecipient?
    var attendees: [GraphAttendee]?
    var responseStatus: GraphResponseStatus?
    var recurrence: GraphPatternedRecurrence?
    var onlineMeeting: GraphOnlineMeeting?
}

struct GraphFolder: Decodable, Sendable {
    var id: String
    var displayName: String?
    var childFolderCount: Int?
}

struct GraphAttachment: Decodable, Sendable {
    var id: String
    var name: String?
    var contentType: String?
    var size: Int?
    var isInline: Bool?
    var contentId: String?
    var contentBytes: String?
    var odataType: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, contentType, size, isInline, contentId, contentBytes
        case odataType = "@odata.type"
    }
}

struct GraphUser: Decodable, Sendable {
    var id: String?
    var displayName: String?
    var mail: String?
    var userPrincipalName: String?
}

struct GraphErrorEnvelope: Decodable, Sendable {
    struct Body: Decodable, Sendable {
        var code: String?
        var message: String?
    }
    var error: Body?
}
