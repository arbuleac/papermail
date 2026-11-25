import Foundation

/// What the demo's provider says of an event when its details are read (`CalendarProvider.calendarEventDetails`): the
/// facts as Google or Graph would give them (a description in HTML, the guests and their answers, the call's numbers),
/// run through the same `EventNotesReader` and call-code reading the providers use, so the demo exercises the readers.
/// Every address is on a `.test` host and every person from `DemoCatalog`.
enum DemoEventDetails {
    /// The details of `event`, read from what the demo's provider holds; plain details (no notes, no guests) for the
    /// events it says nothing more of.
    static func details(for event: CalendarEvent, profile: DemoProfile) -> CalendarEventDetails {
        let me = EventGuest(name: profile.displayName, address: profile.email, response: response(event.response), isSelf: true)
        switch (profile.kind, event.title) {
        case (.gmail, "Sam's birthday dinner"):
            return google(organizer: DemoCatalog.sam, guests: [
                me, guest(DemoCatalog.priya, .accepted),
                guest(DemoCatalog.jordan, .tentative), guest(DemoCatalog.diego, .needsAction), guest(DemoCatalog.hannah, .accepted),
                guest(DemoCatalog.maya, .declined),
            ], description: """
                <p>Table for 8 under Sam's name. The menu: \
                <a href="https://casalisboa.demo-gmail.test/menu">https://casalisboa.demo-gmail.test/menu</a></p>\
                <p>Bring nothing but yourself.</p>
                """)
        case (.gmail, "Call with Priya: Lisbon plans"):
            var details = google(organizer: DemoCatalog.priya, guests: [me],
                                 description: "Flights first, then where to stay. Shortlist: https://docs.demo-gmail.test/lisbon")
            details.call = EventCall(
                phones: [EventPhone(number: "+1 555-0188", dial: "+15550188,,248913557#", region: "US", pin: "248913557")],
                pinLabel: .pin, morePhonesURL: "https://tel.meet.demo-gmail.test/lsb-trip-mar")
            return details
        case (.gmail, "Pottery class"):
            var details = google(organizer: DemoCatalog.hannah, guests: [
                me, guest(DemoCatalog.theo, .accepted),
            ], description: "Aprons are provided. Wear something you don't mind getting clay on.")
            details.repeats = repeats("FREQ=WEEKLY;BYDAY=\(weekday(event.start, zone: "Europe/Berlin"));COUNT=10",
                                      start: event.start, zone: "Europe/Berlin")
            return details
        case (.gmail, "Neighbourhood clean-up"):
            return google(organizer: DemoCatalog.jordan, guests: [
                guest(DemoCatalog.sam, .accepted),
                guest(DemoCatalog.priya, .tentative), guest(DemoCatalog.diego, .needsAction), me,
            ], description: "Gloves and bags provided. Sign-up sheet: https://docs.demo-gmail.test/cleanup")
        case (.microsoft, "Design critique"):
            var details = outlook(organizer: DemoCatalog.rachel, isOrganizer: false,
                                  guests: [me, guest(DemoCatalog.marcus, nil), guest(DemoCatalog.aisha, nil)],
                                  body: "<div>Weekly look at the reader and composer work. Bring one thing you would change.</div>"
                                    + teamsBlock(join: "https://teams.demo-outlook.test/l/meetup-join/design-critique",
                                                 meetingID: "284 113 905 771", passcode: "Qx7bTe", dial: "+15550134,,601225430#"))
            details.call = callWithCodes(details.notes, tollNumber: "+1 555-0134", conferenceID: "601225430", region: "US")
            details.repeats = repeats("FREQ=WEEKLY;BYDAY=\(weekday(event.start, zone: "America/Los_Angeles"));COUNT=12",
                                      start: event.start, zone: "America/Los_Angeles")
            return details
        case (.microsoft, "Standup"):
            var details = outlook(organizer: DemoCatalog.rachel, isOrganizer: false,
                                  guests: [me, guest(DemoCatalog.marcus, nil), guest(DemoCatalog.aisha, nil), guest(DemoCatalog.tom, nil)],
                                  body: teamsBlock(join: "https://teams.demo-outlook.test/l/meetup-join/standup",
                                                   meetingID: "219 554 870 302", passcode: "Hk8sPa", dial: "+15550134,,733019264#"))
            details.call = callWithCodes(details.notes, tollNumber: "+1 555-0134", conferenceID: "733019264", region: "US")
            details.repeats = "Every weekday"
            return details
        case (.microsoft, "Fabrikam renewal call"):
            var details = outlook(organizer: DemoCatalog.Person(name: profile.displayName, address: profile.email), isOrganizer: true, guests: [
                guest(DemoCatalog.sophie, .accepted), guest(DemoCatalog.tom, .accepted), guest(DemoCatalog.elena, .needsAction),
            ], body: "<p>Renewal terms and the Q1 rollout. Draft: https://docs.demo-outlook.test/fabrikam-renewal</p>")
            details.call = callWithCodes(details.notes, tollNumber: "+1 555-0134", conferenceID: "418002377", region: "US")
            return details
        case (.microsoft, "Quarterly planning"):
            var details = outlook(organizer: DemoCatalog.elena, isOrganizer: false, guests: [
                me, guest(DemoCatalog.tom, nil), guest(DemoCatalog.rachel, nil), guest(DemoCatalog.aisha, nil), guest(DemoCatalog.marcus, nil),
            ], body: "<p>Agenda: last quarter in numbers, the roadmap, hiring.</p><p>Plan draft: https://docs.demo-outlook.test/q1-plan</p>"
                + teamsBlock(join: "https://teams.demo-outlook.test/l/meetup-join/quarterly-planning",
                             meetingID: "512 774 309 118", passcode: "Tn4wQs", dial: "+15550134,,906114582#"))
            details.call = callWithCodes(details.notes, tollNumber: "+1 555-0134", conferenceID: "906114582", region: "US")
            return details
        default:
            return CalendarEventDetails(organizer: nil, userIsOrganizer: event.response == .organizer)
        }
    }

    // MARK: Shapes

    private static func guest(_ person: DemoCatalog.Person, _ answer: InvitationResponse?) -> EventGuest {
        EventGuest(name: person.name, address: person.address, response: answer)
    }

    /// As Google lists them (the organizer and rooms left out): the user first, every answer known.
    private static func google(organizer: DemoCatalog.Person, guests: [EventGuest], description: String) -> CalendarEventDetails {
        let listed = guests
        return CalendarEventDetails(
            organizer: organizer.email, userIsOrganizer: false,
            guests: listed.filter(\.isSelf) + listed.filter { !$0.isSelf }, guestCount: listed.count, answersKnown: true,
            notes: EventNotesReader.notes(from: description))
    }

    /// As Graph lists them: answers known on the organizer's copy alone.
    private static func outlook(organizer: DemoCatalog.Person, isOrganizer: Bool, guests: [EventGuest], body: String) -> CalendarEventDetails {
        let listed = isOrganizer ? guests : guests.map { guest in
            var unknown = guest
            unknown.response = nil
            return unknown
        }
        return CalendarEventDetails(
            organizer: organizer.email, userIsOrganizer: isOrganizer,
            guests: listed.filter(\.isSelf) + listed.filter { !$0.isSelf }, guestCount: listed.count, answersKnown: isOrganizer,
            notes: EventNotesReader.notes(from: body))
    }

    /// The block Teams writes under a meeting's notes.
    private static func teamsBlock(join: String, meetingID: String, passcode: String, dial: String) -> String {
        """
        <div>________________________________________________________________________________</div>\
        <div><span style="font-size:24px">Microsoft Teams meeting</span></div>\
        <div><b>Join on your computer, mobile app or room device</b></div>\
        <div><a href="\(join)">Click here to join the meeting</a></div>\
        <div>Meeting ID: \(meetingID)</div><div>Passcode: \(passcode)</div>\
        <div><b>Or call in (audio only)</b></div>\
        <div><a href="tel:\(dial.replacingOccurrences(of: "#", with: "%23"))">\(dial)</a> United States</div>\
        <div><a href="https://teams.demo-outlook.test/meetingOptions">Meeting options</a></div>\
        <div>________________________________________________________________________________</div>
        """
    }

    /// The toll number Teams states with its conference ID, and the meeting ID and passcode the notes write.
    private static func callWithCodes(_ notes: EventNotes?, tollNumber: String, conferenceID: String, region: String) -> EventCall {
        let codes = notes.map { EventNotesReader.callCodes(in: $0.text) }
        let digits = tollNumber.filter { $0 == "+" || $0.isNumber }
        return EventCall(meetingID: codes?.meetingID, passcode: codes?.passcode,
                         phones: [EventPhone(number: tollNumber, dial: digits + ",," + conferenceID + "#", region: region,
                                             pin: conferenceID)],
                         pinLabel: .conferenceID)
    }

    private static func response(_ response: CalendarEvent.Response) -> InvitationResponse? {
        switch response {
        case .accepted: return .accepted
        case .tentative: return .tentative
        case .declined: return .declined
        case .needsAction: return .needsAction
        case .organizer: return nil
        }
    }

    /// The series' rule in words, read from its RRULE as the providers read Google's.
    private static func repeats(_ rrule: String, start: Date, zone: String) -> String {
        guard let rule = RecurrenceRule(rrule: rrule) else { return "Repeats" }
        return rule.words(start: start, timeZone: TimeZone(identifier: zone) ?? .current, locale: Locale(identifier: "en_US"))
    }

    private static func weekday(_ date: Date, zone: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        return ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][calendar.component(.weekday, from: date) - 1]
    }
}
