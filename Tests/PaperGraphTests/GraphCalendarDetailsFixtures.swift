import Foundation

/// Outlook events read for their details (`GET /me/events/{id}?$select=body,organizer,attendees,…`), in Graph's
/// documented shape, recorded and anonymized on `.test` hosts.
enum GraphCalendarDetailsFixtures {
    /// The organizer's copy of a Teams meeting: every guest's answer, a room, a body with Teams' block.
    static let teamsOrganizerCopy = #"""
    {
     "@odata.etag": "W/\"DwAAABYAAAB\"",
     "id": "AAMkOCCURRENCE=",
     "changeKey": "DwAAABYAAAB",
     "type": "occurrence",
     "seriesMasterId": "AAMkMASTER=",
     "isOrganizer": true,
     "hideAttendees": false,
     "body": {"contentType": "html", "content": "<html><head><style>p{color:red}</style><meta http-equiv=\"Content-Type\" content=\"text/html\"></head><body><div>Weekly look at the reader and composer work.</div><div>________________________________________________________________________________</div><div><span>Microsoft Teams meeting</span></div><div><a href=\"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x\">Click here to join the meeting</a></div><div>Meeting ID: 284 113 905 771</div><div>Passcode: Qx7bTe</div><div><a href=\"tel:+15550134,,601225430%23\">+1 555-0134,,601225430#</a> United States</div><div><a href=\"https://nam11.safelinks.protection.outlook.test/?url=https%3A%2F%2Fteams.microsoft.com%2FmeetingOptions\">Meeting options</a></div><div>________________________________________________________________________________</div></body></html>"},
     "organizer": {"emailAddress": {"name": "Alex Morgan", "address": "alex@northwind.test"}},
     "attendees": [
      {"type": "required", "status": {"response": "accepted", "time": "2026-11-12T10:00:00Z"}, "emailAddress": {"name": "Rachel Kim", "address": "rachel.kim@northwind.test"}},
      {"type": "required", "status": {"response": "tentativelyAccepted", "time": "2026-11-12T10:00:00Z"}, "emailAddress": {"name": "Marcus Bell", "address": "marcus.bell@northwind.test"}},
      {"type": "optional", "status": {"response": "declined", "time": "2026-11-12T10:00:00Z"}, "emailAddress": {"name": "Aisha Patel", "address": "aisha.patel@northwind.test"}},
      {"type": "required", "status": {"response": "notResponded", "time": "0001-01-01T00:00:00Z"}, "emailAddress": {"name": "Tom Hughes", "address": "tom.hughes@northwind.test"}},
      {"type": "resource", "status": {"response": "accepted", "time": "2026-11-12T10:00:00Z"}, "emailAddress": {"name": "Bay 4", "address": "bay4@northwind.test"}}
     ],
     "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x", "conferenceId": "601225430", "tollNumber": "+1 555-0134", "tollFreeNumbers": ["+1 800-555-0199"], "quickDial": "+15550134,,601225430#"}
    }
    """#

    /// An attendee's copy: every other guest's answer is `none`, and the user is listed by the account's address.
    static let teamsAttendeeCopy = #"""
    {
     "id": "AAMkOCCURRENCE=",
     "changeKey": "DwAAABYAAAC",
     "type": "occurrence",
     "seriesMasterId": "AAMkMASTER=",
     "isOrganizer": false,
     "body": {"contentType": "html", "content": "<div>Weekly look.</div>"},
     "organizer": {"emailAddress": {"name": "Rachel Kim", "address": "rachel.kim@northwind.test"}},
     "attendees": [
      {"type": "required", "status": {"response": "none", "time": "0001-01-01T00:00:00Z"}, "emailAddress": {"name": "Rachel Kim", "address": "rachel.kim@northwind.test"}},
      {"type": "required", "status": {"response": "none", "time": "0001-01-01T00:00:00Z"}, "emailAddress": {"name": "Marcus Bell", "address": "marcus.bell@northwind.test"}},
      {"type": "required", "status": {"response": "notResponded", "time": "0001-01-01T00:00:00Z"}, "emailAddress": {"name": "Alex Morgan", "address": "Alex@Northwind.test"}}
     ],
     "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x"}
    }
    """#

    /// The organizer hid the guests; the body names a Zoom call (scheduled in Outlook).
    static let hiddenAttendees = #"""
    {
     "id": "AAMkHIDDEN=",
     "changeKey": "DwAAABYAAAD",
     "type": "singleInstance",
     "isOrganizer": false,
     "hideAttendees": true,
     "body": {"contentType": "html", "content": "<p>Join Zoom Meeting <a href=\"https://acme.zoom.us/j/81234567890?pwd=x\">https://acme.zoom.us/j/81234567890</a></p><p>Meeting ID: 812 3456 7890<br>Passcode: 551902</p>"},
     "organizer": {"emailAddress": {"name": "Rachel Kim", "address": "rachel.kim@northwind.test"}},
     "attendees": [{"type": "required", "status": {"response": "none"}, "emailAddress": {"name": "Marcus Bell", "address": "marcus.bell@northwind.test"}}]
    }
    """#

    /// No online meeting: the organizer typed a Zoom link in the location, and the body holds the invitation Zoom wrote,
    /// with another of its links (a personal room) first. The event's call is the location's.
    static let zoomInTheLocation = #"""
    {
     "id": "AAMkZOOM=",
     "changeKey": "DwAAABYAAAE",
     "type": "singleInstance",
     "isOrganizer": false,
     "onlineMeeting": null,
     "onlineMeetingUrl": null,
     "location": {"displayName": "https://acme.zoom.us/j/81234567890?pwd=x", "locationType": "default"},
     "body": {"contentType": "html", "content": "<p>Rachel's personal room: <a href=\"https://acme.zoom.us/my/rachel.kim\">https://acme.zoom.us/my/rachel.kim</a></p><p>Join Zoom Meeting <a href=\"https://acme.zoom.us/j/81234567890?pwd=x\">https://acme.zoom.us/j/81234567890</a></p><p>Meeting ID: 812 3456 7890<br>Passcode: 551902</p>"},
     "organizer": {"emailAddress": {"name": "Rachel Kim", "address": "rachel.kim@northwind.test"}},
     "attendees": []
    }
    """#

    /// No Teams join address, but the older online meeting address Exchange still fills; the body links elsewhere.
    static let onlineMeetingURLOnly = #"""
    {
     "id": "AAMkSKYPE=",
     "changeKey": "DwAAABYAAAF",
     "type": "singleInstance",
     "isOrganizer": false,
     "onlineMeetingUrl": "https://meet.lync.northwind.test/rachel/K7P2",
     "location": {"displayName": "Bay 4"},
     "body": {"contentType": "html", "content": "<p>Or join from a browser: <a href=\"https://teams.microsoft.com/l/meetup-join/19%3ameeting_y\">Teams</a></p><p>Meeting ID: 512 774 309 118<br>Passcode: Tn4wQs</p>"},
     "organizer": {"emailAddress": {"name": "Rachel Kim", "address": "rachel.kim@northwind.test"}},
     "attendees": []
    }
    """#

    /// The series master's recurrence, weekly with a count, in the zone it was made in.
    static let seriesMaster = #"""
    {
     "id": "AAMkMASTER=",
     "originalStartTimeZone": "Pacific Standard Time",
     "start": {"dateTime": "2026-11-20T18:00:00.0000000", "timeZone": "UTC"},
     "recurrence": {"pattern": {"type": "weekly", "interval": 1, "daysOfWeek": ["friday"], "firstDayOfWeek": "sunday", "index": "first"},
                    "range": {"type": "numbered", "startDate": "2026-11-20", "numberOfOccurrences": 12, "recurrenceTimeZone": "Pacific Standard Time"}}
    }
    """#
}
