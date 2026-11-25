import Foundation

/// The main calendar of each demo account, laid out around the demo's reference the way its mailbox is, so the day
/// column and the week always open on a believable week: the Outlook account's working days (a standup every weekday,
/// meetings, focus time shown as free, an all-day go-live, a declined demo and a tentative team outing) and the Gmail
/// account's evenings and weekend (a concert, a dentist, a birthday held all day, a declined game night). The demo's
/// invitations are on their calendars too, under the same UID, as Google and Exchange put them there when they arrive;
/// each has an event that overlaps it, so the invitation card warns of the overlap and the calendar hatches it.
///
/// It also writes the demo's mail that names a time (“Could we move our call to Monday at 3pm?”), so the calendar
/// marks a time found in mail from the first launch.
///
/// Everything follows from the profile and the reference, like the mailbox: the same reference gives the same calendar.
enum DemoCalendar {
    /// The zone the demo's own events are read in: the Mac's, as `DemoInvitations` writes its times.
    static var macCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// Every event of the account's main calendar across the calendar window around `reference` (`CalendarWindow`), as a
    /// read reports them (`CalendarProvider.calendarEvents(in:)`): ids made from the provider ids, all `synced`,
    /// ordered by start, then end, then id.
    static func events(for profile: DemoProfile, accountID: AccountID, reference: Date,
                       calendar: Calendar = macCalendar) -> [CalendarEvent] {
        var builder = Builder(profile: profile, accountID: accountID, reference: reference, calendar: calendar)
        if profile.kind == .gmail { builder.personal() } else { builder.work() }
        return builder.events.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
    }

    /// Where a provider's web calendar would show the event (`CalendarEvent.webURL`), on a `.test` host that never
    /// resolves, like every address in the demo.
    static func webURL(providerID: String, kind: ProviderKind) -> String {
        switch kind {
        case .gmail: return "https://calendar.demo-gmail.test/event?eid=\(providerID)"
        case .microsoft: return "https://outlook.demo-outlook.test/calendar/item/\(providerID)"
        }
    }

    /// The invitations on the calendars that came with no mail: an answer from their details goes on the calendar alone.
    static let cleanupUID = "cleanup-2026@demo-gmail.test"
    static let planningUID = "AAMkADemoUID-quarterly-planning"

    // MARK: Mail that names a time

    /// A recent mail asking to move a call, which names a day and a time of day.
    struct TimeMail {
        let subject: String
        let from: DemoCatalog.Person
        let text: String
        /// How long before the reference it arrived: recent enough to be read for times (`MailTimeDetector.recentDays`),
        /// never the newest mail, which stays an invitation.
        let hoursAgo: Double
    }

    /// The account's mail that names a time. The day is named by its weekday, the first working day at least two days
    /// after the reference, so the detector, which resolves a weekday against the moment it reads the mail, finds it
    /// still to come.
    static func timeMails(for profile: DemoProfile, reference: Date, calendar: Calendar = macCalendar) -> [TimeMail] {
        let day = proposedDay(after: reference, calendar: calendar)
        switch profile.kind {
        case .gmail:
            return [TimeMail(
                subject: "Moving our call", from: DemoCatalog.jordan,
                text: "Hi Alex, something came up at work. Could we move our call to \(day) at 3pm? Same number as last time.\nJordan",
                hoursAgo: 2
            )]
        case .microsoft:
            return [TimeMail(
                subject: "Density review: new time?", from: DemoCatalog.marcus,
                text: "Rachel can only join after lunch. Could we push the density review to \(day) from 2 to 3pm?\nMarcus",
                hoursAgo: 3.5
            )]
        }
    }

    /// The English name of the first weekday (Monday to Friday) two or more days after the reference.
    static func proposedDay(after reference: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: reference)
        var offset = 2
        while let day = calendar.date(byAdding: .day, value: offset, to: today), calendar.isDateInWeekend(day) { offset += 1 }
        let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: day)
    }

    // MARK: Building

    private struct Builder {
        let profile: DemoProfile
        let accountID: AccountID
        let reference: Date
        let calendar: Calendar
        var events: [CalendarEvent] = []

        init(profile: DemoProfile, accountID: AccountID, reference: Date, calendar: Calendar) {
            self.profile = profile
            self.accountID = accountID
            self.reference = reference
            self.calendar = calendar
        }

        private var today: Date { calendar.startOfDay(for: reference) }

        /// `hour:minute` on the day `offset` days after the reference's.
        private func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        private func isWeekend(_ offset: Int) -> Bool {
            calendar.isDateInWeekend(at(offset, 12))
        }

        /// The day offset of the `n`th working day from today: today itself for 0 when it is a weekday (the Monday after
        /// when it is not), the ones after it for positive `n`, the ones before it for negative `n`.
        private func workday(_ n: Int) -> Int {
            var offset = 0
            while isWeekend(offset) { offset += 1 }
            var remaining = n
            while remaining != 0 {
                offset += remaining > 0 ? 1 : -1
                if !isWeekend(offset) { remaining += remaining > 0 ? -1 : 1 }
            }
            return offset
        }

        /// The day `date` falls on (in `other`'s zone, else the demo's), as a stamp that keeps the ids of a repeat's
        /// occurrences the same from one launch to the next.
        private func stamp(_ date: Date, in other: Calendar? = nil) -> String {
            let parts = (other ?? calendar).dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }

        /// The start of the day `offset` days after the reference's, held floating: that date's midnight in UTC.
        private func floatingDay(_ offset: Int) -> Date {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            var parts = calendar.dateComponents([.year, .month, .day], from: at(offset, 12))
            parts.hour = 0
            return utc.date(from: parts) ?? at(offset, 0)
        }

        private mutating func add(
            _ key: String,
            _ title: String,
            start: Date,
            end: Date,
            location: String? = nil,
            response: CalendarEvent.Response = .organizer,
            isFree: Bool = false,
            joinURL: String? = nil,
            organizer: DemoCatalog.Person? = nil,
            invitationUID: String? = nil,
            isAllDay: Bool = false,
            seriesID: String? = nil,
            originalStart: Date? = nil,
            timeZone: String? = nil,
            kind: CalendarEvent.Kind? = nil,
            callService: CallService? = nil
        ) {
            let providerID = profile.kind == .gmail ? "demo\(key)" : "AAMkADemoEvent-\(key)"
            events.append(CalendarEvent(
                id: CalendarEvent.localID(accountID: accountID, providerID: providerID),
                accountID: accountID,
                providerID: providerID,
                title: title,
                location: location,
                start: start,
                end: end,
                isAllDay: isAllDay,
                response: response,
                isFree: isFree,
                joinURL: joinURL,
                webURL: DemoCalendar.webURL(providerID: providerID, kind: profile.kind),
                organizer: organizer?.name,
                invitationUID: invitationUID,
                seriesID: seriesID,
                originalStart: seriesID == nil ? nil : originalStart ?? start,
                timeZone: isAllDay ? nil : timeZone,
                kind: kind,
                callService: joinURL == nil ? nil : callService,
                version: "demo-1"
            ))
        }

        private mutating func addAllDay(_ key: String, _ title: String, on offset: Int) {
            let start = floatingDay(offset)
            add(key, title, start: start, end: start.addingTimeInterval(86_400), isAllDay: true)
        }

        /// The starts of a weekly repeat's occurrences, each with a key of its own, as the providers expand a repeat into
        /// single events. Counted in `zone`, the repeat's own, so its wall clock holds across a change of daylight saving.
        private func weekly(_ key: String, count: Int, first: Date, zone: String) -> [(key: String, start: Date)] {
            var repeatCalendar = Calendar(identifier: .gregorian)
            repeatCalendar.timeZone = TimeZone(identifier: zone) ?? calendar.timeZone
            return (0..<count).compactMap { week in
                repeatCalendar.date(byAdding: .day, value: 7 * week, to: first).map { (key + stamp($0, in: repeatCalendar), $0) }
            }
        }

        // MARK: Gmail

        mutating func personal() {
            let meet = "https://meet.demo-gmail.test/"
            let dinner = DemoInvitations.dinnerStart(reference: reference)
            add("birthdaydinner", "Sam's birthday dinner", start: dinner, end: dinner.addingTimeInterval(DemoInvitations.dinnerLength),
                location: "Casa Lisboa, 24 Valencia Street", response: .needsAction, organizer: DemoCatalog.sam,
                invitationUID: DemoInvitations.dinnerUID)
            // Booked before the dinner was planned: the dinner's invitation overlaps it.
            add("bluelantern", "Jazz at the Blue Lantern", start: dinner.addingTimeInterval(30 * 60),
                end: dinner.addingTimeInterval(3 * 3_600), location: "Blue Lantern, 18 Mission Street")
            let pottery = DemoInvitations.potteryStart(reference: reference)
            for (key, start) in weekly("pottery", count: DemoInvitations.potteryClasses, first: pottery, zone: "Europe/Berlin") {
                add(key, "Pottery class", start: start, end: start.addingTimeInterval(DemoInvitations.potteryLength),
                    location: "Tonwerk Studio, Kastanienallee 12, Berlin", response: .accepted, organizer: DemoCatalog.hannah,
                    invitationUID: DemoInvitations.potteryUID, seriesID: "demopottery", timeZone: "Europe/Berlin")
            }
            // On the calendar with no mail about it: answered from its details alone.
            add("cleanup", "Neighbourhood clean-up", start: at(5, 10), end: at(5, 12), location: "Dolores Park, the playground gate",
                response: .needsAction, organizer: DemoCatalog.jordan, invitationUID: DemoCalendar.cleanupUID)

            add("runsam", "Run with Sam", start: at(-2, 7, 30), end: at(-2, 8, 30), location: "Dolores Park",
                response: .accepted, organizer: DemoCatalog.sam)
            add("haircut", "Haircut", start: at(-1, 17, 30), end: at(-1, 18, 15), location: "Barber & Co.")
            add("priyacall", "Call with Priya: Lisbon plans", start: at(0, 18, 30), end: at(0, 19), response: .accepted,
                joinURL: meet + "lsb-trip-mar", organizer: DemoCatalog.priya, timeZone: "Europe/Lisbon", callService: .meet)
            add("dentist", "Dentist", start: at(1, 8, 30), end: at(1, 9, 15), location: "Bright Smile Dental, 410 Castro Street")
            addAllDay("mumbirthday", "Mum's birthday", on: 2)
            add("boardgames", "Board games at Jordan's", start: at(2, 19), end: at(2, 22), response: .declined,
                organizer: DemoCatalog.jordan)
            add("theosync", "Side project sync with Theo", start: at(3, 20), end: at(3, 21), response: .accepted,
                joinURL: meet + "syn-ceng-ine", organizer: DemoCatalog.theo, callService: .meet)
            let sunday = (1...7).first { calendar.component(.weekday, from: at($0, 12)) == 1 } ?? 7
            add("sundaydinner", "Sunday dinner at Mum and Dad's", start: at(sunday, 17), end: at(sunday, 20))
            add("bookclub", "Book club", start: at(6, 19), end: at(6, 21), location: "Hannah's", response: .accepted,
                organizer: DemoCatalog.hannah)
        }

        // MARK: Outlook

        mutating func work() {
            let teams = "https://teams.demo-outlook.test/l/meetup-join/"
            let window = CalendarWindow.around(reference, calendar: calendar)
            let days = calendar.dateComponents([.day], from: today, to: window.end).day ?? CalendarWindow.daysAhead
            for offset in -CalendarWindow.daysBack..<days where !isWeekend(offset) {
                add("standup-\(stamp(at(offset, 12)))", "Standup", start: at(offset, 9, 30), end: at(offset, 9, 45),
                    location: "Microsoft Teams Meeting", response: .accepted, joinURL: teams + "standup",
                    organizer: DemoCatalog.rachel, seriesID: "AAMkADemoSeries-standup", callService: .teams)
            }
            let critique = DemoInvitations.critiqueStart(reference: reference)
            for (key, start) in weekly("critique-", count: DemoInvitations.critiqueCount, first: critique, zone: "America/Los_Angeles") {
                add(key, "Design critique", start: start, end: start.addingTimeInterval(DemoInvitations.critiqueLength),
                    location: "Bay 4", response: .needsAction, joinURL: teams + "design-critique", organizer: DemoCatalog.rachel,
                    invitationUID: DemoInvitations.critiqueUID, seriesID: "AAMkADemoSeries-critique",
                    timeZone: "America/Los_Angeles", callService: .teams)
            }
            // Put in before the critique's invitation came: the invitation overlaps its second half hour.
            add("roadmapsync", "Roadmap sync with Elena", start: critique.addingTimeInterval(30 * 60),
                end: critique.addingTimeInterval(90 * 60), location: "Microsoft Teams Meeting", joinURL: teams + "roadmap-sync",
                callService: .teams)

            add("sprintplanning", "Sprint planning", start: at(workday(-2), 10), end: at(workday(-2), 11, 30), location: "Bay 4",
                response: .accepted, organizer: DemoCatalog.rachel)
            add("incidentreview", "Incident review: delayed syncs", start: at(workday(-1), 11), end: at(workday(-1), 12),
                location: "Microsoft Teams Meeting", response: .accepted, joinURL: teams + "incident-review",
                organizer: DemoCatalog.aisha, callService: .teams)
            add("rachel1on1", "1:1 with Rachel", start: at(workday(0), 14), end: at(workday(0), 14, 30),
                location: "Microsoft Teams Meeting", response: .accepted, joinURL: teams + "rachel-alex",
                organizer: DemoCatalog.rachel, callService: .teams)
            add("focus-\(stamp(at(workday(0), 12)))", "Focus time", start: at(workday(0), 15), end: at(workday(0), 17), isFree: true,
                kind: .focusTime)
            add("interview", "Interview: senior engineer", start: at(workday(1), 11), end: at(workday(1), 12), location: "Bay 2",
                response: .accepted, organizer: DemoCatalog.aisha)
            add("fabrikam", "Fabrikam renewal call", start: at(workday(1), 16), end: at(workday(1), 16, 30),
                location: "Microsoft Teams Meeting", joinURL: teams + "fabrikam-renewal", callService: .teams)
            // On the calendar with no mail about it: answered from its details alone.
            add("quarterlyplanning", "Quarterly planning", start: at(workday(2), 15), end: at(workday(2), 16, 30),
                location: "Microsoft Teams Meeting", response: .needsAction, joinURL: teams + "quarterly-planning",
                organizer: DemoCatalog.elena, invitationUID: DemoCalendar.planningUID, callService: .teams)
            addAllDay("contosogolive", "Contoso go-live", on: workday(2))
            add("lunchlearn", "Lunch & learn: Swift concurrency", start: at(workday(2), 12), end: at(workday(2), 13),
                location: "Kitchen, 3rd floor", response: .accepted, organizer: DemoCatalog.tom)
            add("vendordemo", "Vendor demo", start: at(workday(3), 13), end: at(workday(3), 14), response: .declined,
                organizer: DemoCatalog.elena)
            add("focus-\(stamp(at(workday(3), 12)))", "Focus time", start: at(workday(3), 15), end: at(workday(3), 17), isFree: true,
                kind: .focusTime)
            add("teamdrinks", "Team drinks", start: at(workday(4), 17, 30), end: at(workday(4), 19, 30), location: "The Anchor",
                response: .tentative, organizer: DemoCatalog.elena)
        }
    }
}
