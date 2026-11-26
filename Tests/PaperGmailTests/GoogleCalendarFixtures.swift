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
       "etag": "\"3512345678901001\"",
       "status": "confirmed",
       "htmlLink": "https://www.google.com/calendar/event?eid=N2sybTRuNnA4cjB0MnY0eDZ6OGIwZDJmNGggYWRhQGV4YW1wbGUuY29t",
       "updated": "2026-11-18T09:12:44.123Z",
       "summary": "Design review",
       "location": "Room 4",
       "organizer": {"email": "ben@contoso.test", "displayName": "Ben Carter"},
       "start": {"dateTime": "2026-11-19T15:00:00+02:00", "timeZone": "Europe/Athens"},
       "end": {"dateTime": "2026-11-19T16:00:00+02:00", "timeZone": "Europe/Athens"},
       "iCalUID": "5h0v6l1b@google.com",
       "attendees": [{"responseStatus": "accepted"}, {"self": true, "responseStatus": "accepted"}],
       "hangoutLink": "https://meet.google.com/abc-defg-hij",
       "conferenceData": {"conferenceSolution": {"name": "Google Meet", "key": {"type": "hangoutsMeet"}}, "entryPoints": [
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
       "start": {"dateTime": "2026-11-19T10:30:00-05:00", "timeZone": "Mars/Olympus_Mons"},
       "end": {"dateTime": "2026-11-19T11:15:00-05:00"},
       "iCalUID": "040000008200E00074C5B7101A82E008@fabrikam.test",
       "attendees": [{"self": true, "responseStatus": "tentative"}, {"responseStatus": "accepted"}],
       "conferenceData": {"conferenceSolution": {"name": "Zoom Meeting", "key": {"type": "addOn"}}, "entryPoints": [
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
       "start": {"dateTime": "2026-11-20T09:00:00+01:00", "timeZone": "Europe/Paris"},
       "end": {"dateTime": "2026-11-20T10:00:00+01:00", "timeZone": "Europe/Paris"},
       "iCalUID": "unanswered01@contoso.test",
       "attendees": [{"self": true, "responseStatus": "needsAction"}, {"responseStatus": "accepted"}],
       "eventType": "default"
      },
      {
       "id": "standup_20261119T080000Z",
       "etag": "\"3512345678901002\"",
       "status": "confirmed",
       "updated": "2026-11-02T08:00:00Z",
       "summary": "Standup",
       "location": "https://acme.zoom.us/j/555",
       "organizer": {"email": "erin@contoso.test", "displayName": "Erin"},
       "start": {"dateTime": "2026-11-19T09:00:00+01:00", "timeZone": "Europe/Berlin"},
       "end": {"dateTime": "2026-11-19T09:15:00+01:00", "timeZone": "Europe/Berlin"},
       "iCalUID": "standup@contoso.test",
       "recurringEventId": "standup",
       "originalStartTime": {"dateTime": "2026-11-19T09:00:00+01:00", "timeZone": "Europe/Berlin"},
       "attendees": [{"self": true, "responseStatus": "accepted"}],
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

    // MARK: An answer given from the calendar (`maxAttendees=1`: only the participant's own entry comes back)

    /// An instance of a weekly series, the user not answered yet.
    static let answerGetSelf = #"""
    {
     "id": "standup_20261119T080000Z",
     "status": "confirmed",
     "iCalUID": "standup@contoso.test",
     "sequence": 3,
     "summary": "Standup",
     "start": {"dateTime": "2026-11-19T09:00:00+01:00", "timeZone": "Europe/Berlin"},
     "end": {"dateTime": "2026-11-19T09:15:00+01:00", "timeZone": "Europe/Berlin"},
     "recurringEventId": "standup",
     "originalStartTime": {"dateTime": "2026-11-19T09:00:00+01:00", "timeZone": "Europe/Berlin"},
     "organizer": {"email": "erin@contoso.test", "displayName": "Erin Park"},
     "attendees": [{"email": "ada@example.com", "displayName": "Ada L.", "self": true, "responseStatus": "needsAction"}],
     "attendeesOmitted": true
    }
    """#

    /// The series itself: no instance, so no RECURRENCE-ID.
    static let answerGetSeries = #"""
    {
     "id": "standup",
     "status": "confirmed",
     "iCalUID": "standup@contoso.test",
     "sequence": 3,
     "summary": "Standup",
     "start": {"dateTime": "2026-11-02T09:00:00+01:00", "timeZone": "Europe/Berlin"},
     "end": {"dateTime": "2026-11-02T09:15:00+01:00", "timeZone": "Europe/Berlin"},
     "organizer": {"email": "erin@contoso.test", "displayName": "Erin Park"},
     "attendees": [{"email": "ada@example.com", "self": true, "responseStatus": "needsAction"}],
     "attendeesOmitted": true
    }
    """#

    /// The same instance, already answered (a retry after a send whose reply was lost, or the phone).
    static let answerGetSelfAnswered = answerGetSelf.replacingOccurrences(of: "\"needsAction\"", with: "\"accepted\"")

    /// An event on the calendar that does not list the user.
    static let answerGetNoSelf = #"""
    {"id": "standup_20261119T080000Z", "status": "confirmed", "iCalUID": "standup@contoso.test", "summary": "Standup",
     "start": {"dateTime": "2026-11-19T09:00:00+01:00"}, "end": {"dateTime": "2026-11-19T09:15:00+01:00"},
     "organizer": {"email": "erin@contoso.test"}, "attendeesOmitted": true}
    """#

    /// A cancelled instance.
    static let answerGetCancelled = #"{"id": "standup_20261119T080000Z", "status": "cancelled"}"#

    /// An event a group calendar organizes: nobody to mail.
    static let answerGetGroupOrganizer = answerGetSelf.replacingOccurrences(
        of: #""organizer": {"email": "erin@contoso.test", "displayName": "Erin Park"}"#,
        with: #""organizer": {"email": "c_1a2b3c@group.calendar.google.com", "displayName": "Team calendar"}"#)

    /// What the patch answers under `fields=id`.
    static let patchReply = #"{"id": "standup_20261119T080000Z"}"#

    // MARK: Details (`events.get` with `GmailProvider.detailsFields`)

    /// A Meet call with a dial-in, nine attendees (the user, the organizer, a room, an optional guest, every answer) and
    /// an HTML description with formatting, an image, a link, a phone link and a script link.
    static let eventDetailsMeet = #"""
    {
     "id": "standup_20261119T080000Z",
     "etag": "\"3512345678901002\"",
     "description": "<b>Agenda</b><br>Weekly status.<ul><li>Wins</li><li>Blockers</li></ul><img src=\"https://tracker.example.test/p.gif\"><a href=\"https://docs.example.test/notes\">Notes</a> <a href=\"tel:+15550100\">Call Erin</a> <a href=\"javascript:alert(1)\">Click</a>",
     "organizer": {"email": "erin@contoso.test", "displayName": "Erin Park"},
     "attendees": [
      {"email": "erin@contoso.test", "displayName": "Erin Park", "organizer": true, "responseStatus": "accepted"},
      {"email": "ben@contoso.test", "displayName": "Ben Carter", "responseStatus": "accepted"},
      {"email": "ada@example.com", "self": true, "responseStatus": "needsAction"},
      {"email": "room4@resource.calendar.google.com", "displayName": "Room 4", "resource": true, "responseStatus": "accepted"},
      {"email": "carol@fabrikam.test", "optional": true, "responseStatus": "tentative"},
      {"email": "dan@northwind.test", "displayName": "Dan", "responseStatus": "declined"},
      {"email": "fay@contoso.test", "responseStatus": "needsAction"},
      {"email": "gus@contoso.test", "displayName": "Gus", "responseStatus": "accepted"},
      {"email": "hal@contoso.test", "displayName": "Hal", "responseStatus": "accepted"}
     ],
     "guestsCanSeeOtherGuests": true,
     "conferenceData": {
      "conferenceSolution": {"name": "Google Meet", "key": {"type": "hangoutsMeet"}},
      "entryPoints": [
       {"entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij", "label": "meet.google.com/abc-defg-hij"},
       {"entryPointType": "phone", "uri": "tel:+1-555-0188", "label": "+1 555-0188", "pin": "248913557", "regionCode": "US"},
       {"entryPointType": "more", "uri": "https://tel.meet.example.test/abc-defg-hij?pin=248913557"}
      ]
     },
     "recurringEventId": "standup",
     "start": {"dateTime": "2026-11-19T09:00:00+01:00", "timeZone": "Europe/Berlin"}
    }
    """#

    /// A Zoom add-on's conference: the meeting code and passcode on the video entry.
    static let eventDetailsZoomAddOn = #"""
    {
     "id": "zoomcall0001",
     "etag": "\"3512345678901003\"",
     "organizer": {"email": "carol@fabrikam.test"},
     "attendees": [{"email": "ada@example.com", "self": true, "responseStatus": "tentative"}],
     "conferenceData": {
      "conferenceSolution": {"name": "Zoom Meeting", "key": {"type": "addOn"}},
      "entryPoints": [
       {"entryPointType": "video", "uri": "https://us02web.zoom.us/j/81234567890", "meetingCode": "812 3456 7890", "passcode": "551902"}
      ]
     },
     "start": {"dateTime": "2026-11-19T10:30:00-05:00"}
    }
    """#

    /// The organizer hid the guest list.
    static let eventDetailsHiddenGuests = #"""
    {
     "id": "hidden000001",
     "etag": "\"3512345678901004\"",
     "description": "Surprise party: Zoom at https://acme.zoom.us/j/999 and the gift list https://gifts.example.test/list",
     "organizer": {"email": "erin@contoso.test", "displayName": "Erin Park"},
     "attendees": [{"email": "ada@example.com", "self": true, "responseStatus": "needsAction"}],
     "guestsCanSeeOtherGuests": false,
     "start": {"dateTime": "2026-11-21T18:00:00Z"}
    }
    """#

    /// A Teams meeting an Exchange organizer sent to a Google account: no conference, the location only the service's
    /// name, and the invitation's DESCRIPTION kept as Exchange wrote it, plain text with its addresses in angle brackets.
    static let eventDetailsExchangeTeams = #"""
    {
     "id": "exchteams0001",
     "etag": "\"3512345678901005\"",
     "description": "Weekly look at the numbers.\nContact: Jane Doe <jane@fabrikam.test>\n________________________________________________________________________________\nMicrosoft Teams meeting\nJoin on your computer, mobile app or room device\nClick here to join the meeting<https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d>\nMeeting ID: 284 113 905 771\nPasscode: Qx7bTe\nDownload Teams<https://www.microsoft.com/microsoft-teams/download-app> | Join on the web<https://www.microsoft.com/microsoft-teams/join-a-meeting>\n________________________________________________________________________________",
     "location": "Microsoft Teams Meeting",
     "organizer": {"email": "jane@fabrikam.test", "displayName": "Jane Doe"},
     "attendees": [
      {"email": "jane@fabrikam.test", "displayName": "Jane Doe", "organizer": true, "responseStatus": "accepted"},
      {"email": "ada@example.com", "self": true, "responseStatus": "needsAction"}
     ],
     "start": {"dateTime": "2026-11-20T15:00:00Z"}
    }
    """#

    /// The series of the standup instances: weekly on Thursday, twelve times, one exception.
    static let seriesParent = #"""
    {
     "recurrence": ["EXDATE;TZID=Europe/Berlin:20261126T090000", "RRULE:FREQ=WEEKLY;BYDAY=TH;COUNT=12"],
     "start": {"dateTime": "2026-11-19T09:00:00+01:00", "timeZone": "Europe/Berlin"}
    }
    """#
}
