import Foundation

/// Google Calendar API replies, in the shape `events.list` gives them under the provider's `fields` mask (only the
/// fields asked for; an attendee's `self` only when true), and the API's error replies as Google words them.
enum GoogleCalendarFixtures {
    /// The first page of a window: a call in Bucharest (+02:00) with Meet, a call in New York (-05:00) on Zoom, an
    /// all-day day of the user's own, a three-day holiday, invitations declined and not answered yet, a cancelled
    /// occurrence, a working location, an absence and focus time.
    static let firstPage = #"""
    {
     "items": [
      {
       "id": "7k2m4n6p8r0t2v4x6z8b0d2f4h",
       "status": "confirmed",
       "htmlLink": "https://www.google.com/calendar/event?eid=N2sybTRuNnA4cjB0MnY0eDZ6OGIwZDJmNGggYWRhQGV4YW1wbGUuY29t",
       "updated": "2026-11-18T09:12:44.123Z",
       "summary": "Design review",
       "location": "Room 4",
       "organizer": {"email": "ben@contoso.test", "displayName": "Ben Carter"},
       "start": {"dateTime": "2026-11-19T15:00:00+02:00"},
       "end": {"dateTime": "2026-11-19T16:00:00+02:00"},
       "iCalUID": "5h0v6l1b@google.com",
       "attendees": [{"responseStatus": "accepted"}, {"self": true, "responseStatus": "accepted"}],
       "hangoutLink": "https://meet.google.com/abc-defg-hij",
       "conferenceData": {"entryPoints": [
        {"entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"},
        {"entryPointType": "phone", "uri": "tel:+1-555-0100"}
       ]},
       "eventType": "default"
      },
      {
       "id": "zoomcall0001",
       "status": "confirmed",
       "htmlLink": "https://www.google.com/calendar/event?eid=em9vbWNhbGwwMDAx",
       "updated": "2026-11-17T20:00:00.000Z",
       "summary": "Quarterly sync",
       "organizer": {"email": "carol@fabrikam.test"},
       "start": {"dateTime": "2026-11-19T10:30:00-05:00"},
       "end": {"dateTime": "2026-11-19T11:15:00-05:00"},
       "iCalUID": "040000008200E00074C5B7101A82E008@fabrikam.test",
       "attendees": [{"self": true, "responseStatus": "tentative"}, {"responseStatus": "accepted"}],
       "conferenceData": {"entryPoints": [
        {"entryPointType": "more", "uri": "https://zoom.us/meeting/more"},
        {"entryPointType": "video", "uri": "https://us02web.zoom.us/j/81234567890"}
       ]},
       "eventType": "default"
      },
      {
       "id": "alldayown001",
       "status": "confirmed",
       "htmlLink": "https://www.google.com/calendar/event?eid=YWxsZGF5b3duMDAx",
       "updated": "2026-11-01T08:00:00.000Z",
       "summary": "Moving day",
       "organizer": {"email": "ada@example.com", "self": true},
       "start": {"date": "2026-11-20"},
       "end": {"date": "2026-11-21"},
       "transparency": "transparent",
       "iCalUID": "alldayown001@google.com",
       "eventType": "default"
      },
      {
       "id": "holiday00001",
       "status": "confirmed",
       "updated": "2026-10-01T08:00:00.000Z",
       "summary": "Lisbon",
       "organizer": {"email": "ada@example.com", "self": true},
       "start": {"date": "2026-11-23"},
       "end": {"date": "2026-11-26"},
       "iCalUID": "holiday00001@google.com",
       "eventType": "default"
      },
      {
       "id": "declined0001",
       "status": "confirmed",
       "updated": "2026-11-16T12:00:00Z",
       "summary": "Vendor pitch",
       "organizer": {"email": "dan@northwind.test", "displayName": "Dan"},
       "start": {"dateTime": "2026-11-19T13:00:00Z"},
       "end": {"dateTime": "2026-11-19T14:00:00Z"},
       "iCalUID": "declined0001@northwind.test",
       "attendees": [{"responseStatus": "accepted"}, {"self": true, "responseStatus": "declined"}],
       "eventType": "default"
      },
      {
       "id": "unanswered01",
       "status": "confirmed",
       "updated": "2026-11-19T07:00:00Z",
       "summary": "Offsite planning",
       "organizer": {"email": "erin@contoso.test"},
       "start": {"dateTime": "2026-11-20T09:00:00+01:00"},
       "end": {"dateTime": "2026-11-20T10:00:00+01:00"},
       "iCalUID": "unanswered01@contoso.test",
       "attendees": [{"self": true, "responseStatus": "needsAction"}, {"responseStatus": "accepted"}],
       "eventType": "default"
      },
      {
       "id": "standup_20261120T080000Z",
       "status": "cancelled"
      },
      {
       "id": "workloc00001",
       "status": "confirmed",
       "updated": "2026-11-10T08:00:00Z",
       "summary": "Office",
       "organizer": {"email": "ada@example.com", "self": true},
       "start": {"date": "2026-11-19"},
       "end": {"date": "2026-11-20"},
       "transparency": "transparent",
       "eventType": "workingLocation"
      },
      {
       "id": "absence00001",
       "status": "confirmed",
       "updated": "2026-11-10T08:00:00Z",
       "summary": "Out of office",
       "organizer": {"email": "ada@example.com", "self": true},
       "start": {"dateTime": "2026-11-27T00:00:00+02:00"},
       "end": {"dateTime": "2026-11-28T00:00:00+02:00"},
       "eventType": "outOfOffice"
      },
      {
       "id": "focus0000001",
       "status": "confirmed",
       "updated": "2026-11-10T08:00:00Z",
       "summary": "Focus time",
       "organizer": {"email": "ada@example.com", "self": true},
       "start": {"dateTime": "2026-11-19T07:00:00Z"},
       "end": {"dateTime": "2026-11-19T09:00:00Z"},
       "eventType": "focusTime"
      }
     ],
     "nextPageToken": "CiAKGjBpNDd2Nmp2Zml2cXRwYjBpOXA"
    }
    """#

    /// The last page: time set aside on a Mac (its client key in the private property), an event shown as free, and
    /// one with no title and an organizer named only by address, whose join entry is not a web address.
    static let lastPage = #"""
    {
     "items": [
      {
       "id": "0123456789abcdef0123456789abcdef",
       "status": "confirmed",
       "htmlLink": "https://www.google.com/calendar/event?eid=MDEyMzQ1Njc4OWFiY2RlZg",
       "updated": "2026-11-19T11:02:03.456Z",
       "summary": "Q3 budget",
       "organizer": {"email": "ada@example.com", "self": true},
       "start": {"dateTime": "2026-11-21T13:00:00+02:00"},
       "end": {"dateTime": "2026-11-21T13:30:00+02:00"},
       "iCalUID": "0123456789abcdef0123456789abcdef@google.com",
       "eventType": "default",
       "extendedProperties": {"private": {"paperKey": "0123456789abcdef0123456789abcdef", "otherApp": "x"}}
      },
      {
       "id": "freeevent001",
       "status": "confirmed",
       "updated": "2026-11-12T08:00:00Z",
       "summary": "Gym (if time allows)",
       "organizer": {"email": "ada@example.com", "self": true},
       "start": {"dateTime": "2026-11-21T18:00:00+02:00"},
       "end": {"dateTime": "2026-11-21T19:00:00+02:00"},
       "transparency": "transparent",
       "eventType": "default"
      },
      {
       "id": "untitled0001",
       "status": "tentative",
       "updated": "2026-11-12T08:00:00Z",
       "organizer": {"email": "frank@tailspin.test"},
       "start": {"dateTime": "2026-11-22T10:00:00Z"},
       "end": {"dateTime": "2026-11-22T10:30:00Z"},
       "attendees": [{"self": true, "responseStatus": "accepted"}],
       "conferenceData": {"entryPoints": [{"entryPointType": "video", "uri": "javascript:alert(1)"}]},
       "eventType": "default"
      }
     ]
    }
    """#

    static let emptyPage = #"{"items": []}"#

    /// What `events.insert` answers: the whole event as Google now has it.
    static let inserted = #"""
    {
     "kind": "calendar#event",
     "etag": "\"3512345678901234\"",
     "id": "0123456789abcdef0123456789abcdef",
     "status": "confirmed",
     "htmlLink": "https://www.google.com/calendar/event?eid=MDEyMzQ1Njc4OWFiY2RlZg",
     "created": "2026-11-19T11:02:03.000Z",
     "updated": "2026-11-19T11:02:03.456Z",
     "summary": "Q3 budget",
     "description": "Set aside in Paper for: Q3 budget",
     "creator": {"email": "ada@example.com", "self": true},
     "organizer": {"email": "ada@example.com", "self": true},
     "start": {"dateTime": "2026-11-19T15:00:00+02:00", "timeZone": "UTC"},
     "end": {"dateTime": "2026-11-19T15:30:00+02:00", "timeZone": "UTC"},
     "iCalUID": "0123456789abcdef0123456789abcdef@google.com",
     "sequence": 0,
     "extendedProperties": {"private": {"paperKey": "0123456789abcdef0123456789abcdef"}},
     "reminders": {"useDefault": false},
     "eventType": "default"
    }
    """#

    /// `messages.get?format=minimal&fields=id,threadId`.
    static let messageThread = #"{"id": "18c2f3a4b5c6d7e8", "threadId": "18c2f0000aaa1111"}"#

    static let duplicate = #"""
    {"error": {"code": 409, "message": "The requested identifier already exists.",
     "errors": [{"domain": "global", "reason": "duplicate", "message": "The requested identifier already exists."}]}}
    """#

    static let gone = #"""
    {"error": {"code": 410, "message": "Resource has been deleted",
     "errors": [{"domain": "global", "reason": "deleted", "message": "Resource has been deleted"}]}}
    """#

    /// A token without the calendar scope, as Google words it today: the classic reason and the ErrorInfo one.
    static let scopeInsufficient = #"""
    {"error": {"code": 403, "message": "Request had insufficient authentication scopes.",
     "errors": [{"message": "Insufficient Permission", "domain": "global", "reason": "insufficientPermissions"}],
     "status": "PERMISSION_DENIED",
     "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
       "domain": "googleapis.com", "metadata": {"service": "calendar-json.googleapis.com", "method": "calendar.v3.Events.List"}}]}}
    """#

    /// The same refusal with the ErrorInfo reason alone.
    static let scopeInsufficientDetailsOnly = #"""
    {"error": {"code": 403, "message": "Request had insufficient authentication scopes.", "status": "PERMISSION_DENIED",
     "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
       "domain": "googleapis.com", "metadata": {"service": "calendar-json.googleapis.com"}}]}}
    """#

    /// The Calendar API not enabled for the OAuth client's project: a Help entry, then the ErrorInfo.
    static let serviceDisabled = #"""
    {"error": {"code": 403,
     "message": "Google Calendar API has not been used in project 123456789012 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/calendar-json.googleapis.com/overview?project=123456789012 then retry.",
     "errors": [{"message": "Google Calendar API has not been used in project 123456789012 before or it is disabled.",
       "domain": "usageLimits", "reason": "accessNotConfigured", "extendedHelp": "https://console.developers.google.com"}],
     "status": "PERMISSION_DENIED",
     "details": [
      {"@type": "type.googleapis.com/google.rpc.Help", "links": [{"description": "Google developers console API activation",
        "url": "https://console.developers.google.com/apis/api/calendar-json.googleapis.com/overview?project=123456789012"}]},
      {"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "SERVICE_DISABLED", "domain": "googleapis.com",
       "metadata": {"service": "calendar-json.googleapis.com", "consumer": "projects/123456789012"}}]}}
    """#

    /// The same refusal with the ErrorInfo reason alone.
    static let serviceDisabledDetailsOnly = #"""
    {"error": {"code": 403, "message": "Google Calendar API has not been used in project 123456789012 before or it is disabled.",
     "status": "PERMISSION_DENIED",
     "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "SERVICE_DISABLED", "domain": "googleapis.com"}]}}
    """#

    static let rateLimitForbidden = #"""
    {"error": {"code": 403, "message": "Rate Limit Exceeded",
     "errors": [{"domain": "usageLimits", "reason": "rateLimitExceeded", "message": "Rate Limit Exceeded"}]}}
    """#

    /// A 403 that is neither a scope, the API nor a limit: someone else's calendar the user may only read.
    static let writerAccessRequired = #"""
    {"error": {"code": 403, "message": "You need to have writer access to this calendar.",
     "errors": [{"domain": "calendar", "reason": "requiredAccessLevel", "message": "You need to have writer access to this calendar."}]}}
    """#

    static let tooManyRequests = #"""
    {"error": {"code": 429, "message": "Rate Limit Exceeded",
     "errors": [{"domain": "usageLimits", "reason": "rateLimitExceeded", "message": "Rate Limit Exceeded"}],
     "status": "RESOURCE_EXHAUSTED"}}
    """#

    static let backendError = #"""
    {"error": {"code": 500, "message": "Backend Error", "errors": [{"domain": "global", "reason": "backendError", "message": "Backend Error"}]}}
    """#
}
