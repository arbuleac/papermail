import Foundation

// Decoded and encoded shapes of the Google Calendar API's events collection, as GmailWire keeps Gmail's: only the
// fields the provider reads are declared, so fields Google adds never break decoding, and everything but an event's id
// is optional. The listing asks for these fields alone (`GmailProvider.calendarFields`).

/// One page of `events.list`.
struct GoogleCalendarEventList: Decodable, Sendable {
    var items: [GoogleCalendarEvent]?
    var nextPageToken: String?
}

/// An event of `events.list`, `events.get` or `events.insert`.
struct GoogleCalendarEvent: Decodable, Sendable {
    /// `date` for an all-day event (`yyyy-MM-dd`), `dateTime` (RFC 3339 with its offset) for a timed one.
    struct Time: Codable, Sendable {
        var date: String?
        var dateTime: String?
    }

    struct Person: Decodable, Sendable {
        var email: String?
        var displayName: String?
        var isSelf: Bool?
        var responseStatus: String?

        private enum CodingKeys: String, CodingKey {
            case email, displayName, responseStatus
            case isSelf = "self"
        }
    }

    struct EntryPoint: Decodable, Sendable {
        var entryPointType: String?
        var uri: String?
    }

    struct ConferenceData: Decodable, Sendable {
        var entryPoints: [EntryPoint]?
    }

    struct ExtendedProperties: Decodable, Sendable {
        var privateProperties: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case privateProperties = "private"
        }
    }

    var id: String
    /// confirmed, tentative or cancelled.
    var status: String?
    var summary: String?
    var location: String?
    var start: Time?
    var end: Time?
    /// `transparent` when the event does not block time; absent means opaque.
    var transparency: String?
    var attendees: [Person]?
    var organizer: Person?
    var hangoutLink: String?
    var conferenceData: ConferenceData?
    var htmlLink: String?
    var iCalUID: String?
    var updated: String?
    /// default, outOfOffice, focusTime, workingLocation, birthday or fromGmail.
    var eventType: String?
    var extendedProperties: ExtendedProperties?
}

/// The body of `events.insert` for time set aside for a mail: busy and private, with no attendees (so Google mails
/// nobody) and no reminders.
struct GoogleCalendarEventInsert: Encodable, Sendable {
    struct Reminders: Encodable, Sendable {
        var useDefault: Bool
    }

    struct ExtendedProperties: Encodable, Sendable {
        var privateProperties: [String: String]

        private enum CodingKeys: String, CodingKey {
            case privateProperties = "private"
        }
    }

    /// The client key, when it is one Google takes as an id: a create replayed after a lost reply then answers 409
    /// instead of making a second copy.
    var id: String?
    var summary: String
    var description: String
    var start: GoogleCalendarEvent.Time
    var end: GoogleCalendarEvent.Time
    var transparency: String
    /// Private: the title is a mail's subject and the description links to the mail, so whoever else sees the
    /// calendar (the domain, a delegate) sees only that the time is busy. The owner still sees it all.
    var visibility = "private"
    var reminders: Reminders
    var extendedProperties: ExtendedProperties?
}

/// The reason codes of a Google error reply, from both places Google puts them: the classic `errors[].reason`
/// (`insufficientPermissions`, `accessNotConfigured`) and the `google.rpc.ErrorInfo` entries of `details[]`
/// (`ACCESS_TOKEN_SCOPE_INSUFFICIENT`, `SERVICE_DISABLED`). Each entry is read on its own, so an entry of a shape this
/// does not know (a Help entry with links) never hides the others.
struct GoogleErrorReasons: Decodable, Sendable {
    var reasons: [String]

    private struct Reasoned: Decodable {
        var reason: String?

        init(from decoder: Decoder) throws {
            reason = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .reason)
        }

        private enum CodingKeys: String, CodingKey {
            case reason
        }
    }

    private struct Body: Decodable {
        var errors: [Reasoned]?
        var details: [Reasoned]?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            errors = try? container.decodeIfPresent([Reasoned].self, forKey: .errors)
            details = try? container.decodeIfPresent([Reasoned].self, forKey: .details)
        }

        private enum CodingKeys: String, CodingKey {
            case errors, details
        }
    }

    private enum CodingKeys: String, CodingKey {
        case error
    }

    init(from decoder: Decoder) throws {
        let body = try decoder.container(keyedBy: CodingKeys.self).decode(Body.self, forKey: .error)
        reasons = ((body.errors ?? []) + (body.details ?? [])).compactMap(\.reason)
    }

    /// The reasons in `body`, none when it is not a Google error reply.
    static func reasons(in body: Data) -> [String] {
        (try? JSONDecoder().decode(GoogleErrorReasons.self, from: body))?.reasons ?? []
    }
}
