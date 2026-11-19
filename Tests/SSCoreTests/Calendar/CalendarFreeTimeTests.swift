import XCTest
@testable import SSCore

/// Free time for B and for a row dropped on a day cell, the day cells' tracks, and the selected invitation's
/// overlaps, over the concept page's sample ("now" is Thursday 19 November, 11:40).
final class CalendarFreeTimeTests: XCTestCase {
    private let sample = CalendarFitSample()

    private func slots(_ day: Int, events: [CalendarEvent]? = nil, now: Date? = nil) -> [[String]] {
        let format = DateFormatter()
        format.calendar = sample.calendar
        format.timeZone = sample.calendar.timeZone
        format.dateFormat = "HH:mm"
        return CalendarFit.freeSlots(on: sample.day(day), events: events ?? sample.drawn, now: now ?? sample.now,
                                     calendar: sample.calendar)
            .map { [format.string(from: $0.start), format.string(from: $0.end)] }
    }

    private func busy(_ id: String, _ day: Int, _ start: String, _ end: String,
                      response: CalendarEvent.Response = .accepted, free: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, accountID: CalendarFitSample.gmail, providerID: id, title: id,
                      start: sample.date(day, start), end: sample.date(day, end), response: response, isFree: free)
    }

    // MARK: Free slots

    /// Today's free time starts at the next quarter hour from now; the pencilled invitation counts as busy.
    func testTodaysFreeTimeStartsFromNow() {
        XCTAssertEqual(slots(3), [["11:45", "13:00"], ["14:00", "17:00"]],
                       "11:40 rounds up to 11:45; the invitation and the 1:1 take 13:00 to 14:00; the QBR 17:00")
        XCTAssertEqual(CalendarFit.firstFreeHalfHour(on: sample.day(3), events: sample.drawn, now: sample.now,
                                                     calendar: sample.calendar),
                       sample.date(3, "11:45"))
        XCTAssertEqual(slots(3, now: sample.date(3, "7:10")).first, ["09:00", "09:30"],
                       "before the working day, today starts at 09:00, not at now")
        XCTAssertEqual(slots(3, now: sample.date(3, "11:45")).first?.first, "11:45", "a quarter hour exactly stays")
        XCTAssertEqual(slots(3, now: sample.date(3, "17:40")), [], "after the working day there is nothing today")
    }

    /// Any later day starts at 09:00; free and all-day events take no time; a day before today has none.
    func testOtherDaysStartAtNine() {
        XCTAssertEqual(slots(4), [["09:00", "09:30"], ["09:45", "11:00"], ["12:00", "18:00"]],
                       "Friday: the standup and the customer interview; the concert is after 18:00")
        XCTAssertEqual(slots(5), [["09:00", "18:00"]], "an empty Saturday")
        XCTAssertEqual(slots(6), [["09:00", "12:30"], ["14:00", "18:00"]])
        XCTAssertEqual(slots(2), [], "Wednesday is past")
        XCTAssertEqual(slots(2, now: sample.date(-3, "9:00")), [["09:00", "09:30"], ["11:30", "15:00"], ["15:30", "18:00"]],
                       "seen from the week before: 09:45 to 10:00 is too short to count")
    }

    /// After a busy event the next stretch starts on the quarter hour it ends in; a stretch under 30 minutes is no
    /// slot; only busy events count.
    func testFreeTimeIsQuarterHourAlignedAndAtLeastHalfAnHour() {
        let events = [
            busy("a", 4, "9:00", "10:10"),
            busy("b", 4, "10:45", "11:20"),
            busy("free", 4, "12:00", "13:00", free: true),
            busy("declined", 4, "13:00", "14:00", response: .declined),
            busy("tentative", 4, "16:00", "17:00", response: .tentative),
        ]
        XCTAssertEqual(slots(4, events: events), [["10:15", "10:45"], ["11:30", "16:00"], ["17:00", "18:00"]])
    }

    /// A day busy from 09:00 to 18:00 has nothing free, and neither has a day with only 20-minute gaps.
    func testAFullDayHasNoFreeHalfHour() {
        let full = [busy("x", 4, "8:30", "12:00"), busy("y", 4, "11:00", "18:30")]
        XCTAssertEqual(slots(4, events: full), [])
        XCTAssertNil(CalendarFit.firstFreeHalfHour(on: sample.day(4), events: full, now: sample.now,
                                                   calendar: sample.calendar))
        let gappy = stride(from: 9, to: 18, by: 1).map { busy("g\($0)", 4, "\($0):00", "\($0):40") }
        XCTAssertEqual(slots(4, events: gappy), [], "twenty minutes between meetings is no half hour")
    }

    /// B with no time in the mail: the shown day first (a weekend day only because the user is looking at it), then
    /// the weekdays after it.
    func testBLooksFromTheShownDayAndSkipsWeekendsAfterIt() {
        func block(from day: Int, shown: Bool, events: [CalendarEvent]? = nil) -> Date? {
            CalendarFit.firstFreeHalfHour(searchingFrom: sample.day(day), dayIsShown: shown,
                                          events: events ?? sample.drawn, now: sample.now, calendar: sample.calendar)
        }
        XCTAssertEqual(block(from: 3, shown: true), sample.date(3, "11:45"))
        XCTAssertEqual(block(from: 5, shown: true), sample.date(5, "9:00"), "the Saturday the column shows")
        XCTAssertEqual(block(from: 5, shown: false), sample.date(7, "9:00"), "otherwise the weekend is skipped")
        XCTAssertEqual(block(from: 0, shown: true), sample.date(3, "11:45"), "a past day looks from today")

        let fullFriday = sample.drawn + [busy("x", 4, "9:00", "18:00")]
        XCTAssertEqual(block(from: 4, shown: true, events: fullFriday), sample.date(7, "9:00"),
                       "a full Friday moves on to Monday, past the weekend")
        let fullYear = sample.drawn + (0..<40).map { busy("d\($0)", $0, "9:00", "18:00") }
        XCTAssertNil(block(from: 4, shown: true, events: fullYear), "nothing within three weeks")
    }

    // MARK: Day cells

    /// The week's cells over the column: each day's busy time on one shared range (08:00 to 20:00 this week),
    /// the invitation hollow, an all-day line where there is one.
    func testTheDayCellsDrawTheWeekOnOneRange() {
        let cells = CalendarFit.dayCells(days: sample.week(0), events: sample.drawn, marks: sample.marks,
                                         calendar: sample.calendar)
        XCTAssertEqual(cells.count, 7)
        XCTAssertEqual(cells.map(\.day), sample.week(0))
        func track(_ index: Int) -> [[Double]] {
            cells[index].segments.map { [($0.start * 10_000).rounded() / 10_000, ($0.width * 10_000).rounded() / 10_000] }
        }
        XCTAssertEqual(cells[0].segments.map(\.eventID), ["e6", "e31", "e32"])
        XCTAssertEqual(track(0), [[0.125, 0.04], [0.25, 0.0833], [0.5, 0.125]], "a quarter-hour standup shows at 4%")
        XCTAssertEqual(cells[3].segments.map(\.eventID), ["e37", "e9", "e38", sample.pencil.id, "e39", "e40"])
        XCTAssertEqual(track(3), [[0, 0.0625], [0.125, 0.04], [0.2083, 0.0417], [0.4167, 0.0833], [0.4583, 0.0417],
                                  [0.75, 0.0833]])
        XCTAssertEqual(cells[3].segments.map(\.isHollow), [false, false, false, true, false, false],
                       "the unanswered invitation is an outline")
        XCTAssertEqual(cells[3].segments[3].accountID, CalendarFitSample.northwind)
        XCTAssertEqual(track(4).last, [0.875, 0.125], "the concert ends where the range does")
        XCTAssertEqual(track(5), [])
        XCTAssertEqual(track(6), [[0.375, 0.125]])
        XCTAssertEqual(cells.map { $0.allDay?.title }, [nil, nil, "Ana's birthday", nil, "Release freeze", nil, nil])
    }

    /// Free, declined and all-day events leave the track alone; a sliver at the range's end stays inside it.
    func testTheDayCellsShowOnlyBusyTime() {
        let events = [
            busy("free", 0, "10:00", "11:00", free: true),
            busy("declined", 0, "12:00", "13:00", response: .declined),
            busy("edge", 0, "17:55", "18:00"),
            busy("busy", 0, "14:00", "15:00"),
        ]
        let cells = CalendarFit.dayCells(days: [sample.day(0)], events: events, calendar: sample.calendar)
        XCTAssertEqual(cells[0].segments.map(\.eventID), ["busy", "edge"])
        let edge = cells[0].segments[1]
        XCTAssertEqual(edge.width, CalendarFit.minimumSegmentWidth)
        XCTAssertEqual(edge.start + edge.width, 1, accuracy: 1e-9, "the sliver is pulled back inside the track")
        XCTAssertNil(cells[0].allDay)
    }

    // MARK: The selected invitation

    /// The sample's invitation (pencilled from the mail) overlaps the 1:1 with Sam from 13:30 to 14:00.
    func testThePencilledInvitationNamesWhatItOverlaps() throws {
        let overlap = try XCTUnwrap(CalendarFit.invitationOverlap(uid: "roadmap-review@northwind.test",
                                                                  near: sample.pencil.start, in: sample.events,
                                                                  pencil: sample.pencil))
        XCTAssertEqual(overlap.event.id, sample.pencil.id)
        XCTAssertEqual(overlap.overlaps.map(\.event.title), ["1:1 with Sam"])
        XCTAssertEqual(overlap.overlaps.first?.interval,
                       DateInterval(start: sample.date(3, "13:30"), end: sample.date(3, "14:00")))

        let none = CalendarFit.invitationOverlap(uid: "unknown", in: sample.events)
        XCTAssertNil(none, "no event and no pencil: nothing to say")
    }

    /// Once the calendar has the invitation's event (Google adds it, unanswered), that event is the invitation: it
    /// never overlaps itself, and the pencil is no longer used.
    func testTheCalendarsOwnEventReplacesThePencil() throws {
        var own = sample.pencil
        own.id = CalendarEvent.localID(accountID: CalendarFitSample.northwind, providerID: "g-roadmap")
        own.providerID = "g-roadmap"
        XCTAssertFalse(CalendarFit.isPencil(own))
        let events = sample.events + [own]
        let overlap = try XCTUnwrap(CalendarFit.invitationOverlap(uid: own.invitationUID!, near: sample.pencil.start,
                                                                  in: events + [sample.pencil], pencil: sample.pencil))
        XCTAssertEqual(overlap.event.id, own.id)
        XCTAssertEqual(overlap.overlaps.map(\.event.title), ["1:1 with Sam"], "not itself, nor its pencil")

        var declined = own
        declined.response = .declined
        let answered = try XCTUnwrap(CalendarFit.invitationOverlap(uid: own.invitationUID!, in: sample.events + [declined],
                                                                   pencil: sample.pencil))
        XCTAssertEqual(answered.event.id, own.id)
        XCTAssertEqual(answered.overlaps, [], "a declined invitation overlaps nothing")
    }

    /// Only busy events overlap: free, declined and all-day ones never do. Several are listed by where they meet.
    func testOnlyBusyEventsOverlapAndTheyComeInOrder() throws {
        let invitation = busy("inv", 8, "10:00", "12:00", response: .needsAction)
        var withUID = invitation
        withUID.invitationUID = "uid-1"
        let allDay = CalendarEvent(id: "holiday", accountID: CalendarFitSample.gmail, providerID: "holiday",
                                   title: "Holiday", start: CalendarFitSample.floating(2026, 11, 24),
                                   end: CalendarFitSample.floating(2026, 11, 25), isAllDay: true)
        let events = [
            withUID,
            busy("late", 8, "11:30", "13:00"),
            busy("early", 8, "9:00", "10:30"),
            busy("inside", 8, "10:45", "11:00"),
            busy("touching", 8, "12:00", "12:30"),
            busy("free", 8, "10:00", "11:00", free: true),
            busy("declined", 8, "10:00", "11:00", response: .declined),
            allDay,
        ]
        let overlap = try XCTUnwrap(CalendarFit.invitationOverlap(uid: "uid-1", in: events))
        XCTAssertEqual(overlap.overlaps.map(\.event.id), ["early", "inside", "late"],
                       "an event that only touches its end does not overlap")
        XCTAssertEqual(overlap.overlaps.map(\.interval), [
            DateInterval(start: sample.date(8, "10:00"), end: sample.date(8, "10:30")),
            DateInterval(start: sample.date(8, "10:45"), end: sample.date(8, "11:00")),
            DateInterval(start: sample.date(8, "11:30"), end: sample.date(8, "12:00")),
        ])

        var allDayInvitation = allDay
        allDayInvitation.invitationUID = "uid-2"
        let wholeDay = try XCTUnwrap(CalendarFit.invitationOverlap(uid: "uid-2", in: events + [allDayInvitation]))
        XCTAssertEqual(wholeDay.overlaps, [], "an all-day invitation overlaps nothing")
    }

    /// A repeating invitation's occurrences share its UID: the one nearest the invitation's start is the one checked.
    func testARepeatingInvitationIsMatchedByItsOccurrence() throws {
        func occurrence(_ day: Int) -> CalendarEvent {
            var event = busy("weekly-\(day)", day, "15:00", "16:00", response: .needsAction)
            event.invitationUID = "weekly"
            return event
        }
        let events = [occurrence(1), occurrence(8), occurrence(15), busy("clash", 8, "15:30", "16:30")]
        let second = try XCTUnwrap(CalendarFit.invitationOverlap(uid: "weekly", near: sample.date(8, "15:00"),
                                                                 in: events))
        XCTAssertEqual(second.event.id, "weekly-8")
        XCTAssertEqual(second.overlaps.map(\.event.id), ["clash"])
        let first = try XCTUnwrap(CalendarFit.invitationOverlap(uid: "weekly", in: events))
        XCTAssertEqual(first.event.id, "weekly-1", "without a start, the first in the store's order")
        XCTAssertEqual(first.overlaps, [])
    }

    // MARK: Pencils

    /// The pencil keeps the invitation's facts, gets an id no calendar event has, and reads a floating time on the
    /// Mac's clock.
    func testAnInvitationBecomesAPencil() throws {
        let message = MessageID(accountID: CalendarFitSample.contoso, providerID: "m-42")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let wall = utc.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 13))!
        let floating = CalendarInvitation(method: .request, uid: "u", title: "Walk", start: wall,
                                          end: wall.addingTimeInterval(3_600), isFloating: true, location: "Park",
                                          conferenceURL: "https://meet.example.test/x",
                                          organizer: .init(name: "Lena Fischer", address: "lena@contoso.test"))
        let pencil = try XCTUnwrap(CalendarFit.pencil(for: floating, message: message, timeZone: sample.calendar.timeZone))
        XCTAssertEqual(pencil.id, "invitation|ct|m-42")
        XCTAssertEqual(pencil.start, sample.date(8, "13:00"), "13:00 as written, on the Mac's clock")
        XCTAssertEqual(pencil.end, sample.date(8, "14:00"))
        XCTAssertEqual(pencil.response, .needsAction)
        XCTAssertEqual(pencil.invitationUID, "u")
        XCTAssertNil(pencil.sourceMessage, "a pencil is no time set aside")
        XCTAssertFalse(pencil.isSetAside)
        XCTAssertTrue(CalendarFit.isPencil(pencil))
        XCTAssertFalse(CalendarFit.isPencil(sample.events[0]))
        XCTAssertEqual(pencil.location, "Park")
        XCTAssertEqual(pencil.joinURL, "https://meet.example.test/x")
        XCTAssertEqual(pencil.organizer, "Lena Fischer")
        XCTAssertNil(pencil.providerID)
        XCTAssertTrue(pencil.isShown)

        let zoned = CalendarInvitation(method: .request, uid: "z", title: "Call", start: wall,
                                       end: wall.addingTimeInterval(1_800), timeZoneID: "Europe/Berlin",
                                       userResponse: .accepted)
        let real = try XCTUnwrap(CalendarFit.pencil(for: zoned, message: message, timeZone: sample.calendar.timeZone))
        XCTAssertEqual(real.start, wall, "an instant stays the instant")
        XCTAssertEqual(real.response, .accepted)
        XCTAssertEqual(CalendarFit.pencil(for: zoned, message: message, timeZone: sample.calendar.timeZone,
                                          response: .tentative)?.response, .tentative, "the stored answer wins")

        let midnight = CalendarFitSample.floating(2026, 11, 24)
        let allDay = CalendarInvitation(method: .request, uid: "d", title: "Offsite", start: midnight,
                                        end: midnight.addingTimeInterval(86_400), isAllDay: true, isFloating: true,
                                        userIsOrganizer: true)
        let day = try XCTUnwrap(CalendarFit.pencil(for: allDay, message: message, timeZone: sample.calendar.timeZone))
        XCTAssertEqual(day.start, midnight, "an all-day pencil stays floating, as all-day events are held")
        XCTAssertTrue(day.isAllDay)
        XCTAssertEqual(day.response, .organizer)

        let cancelled = CalendarInvitation(method: .cancel, uid: "c", title: "Gone", start: wall, end: wall)
        XCTAssertNil(CalendarFit.pencil(for: cancelled, message: message, timeZone: sample.calendar.timeZone))
    }

    /// The calendar's Join opens only https (the window refuses http), so a pencil drawn from an invitation whose
    /// meeting link is http offers no Join that would do nothing; the reader's card keeps the link.
    func testAPencilOffersOnlyAnHttpsJoin() throws {
        let message = MessageID(accountID: CalendarFitSample.contoso, providerID: "m-43")
        let start = sample.date(8, "13:00")
        let http = CalendarInvitation(method: .request, uid: "h", title: "Call", start: start, end: start.addingTimeInterval(1_800),
                                      conferenceURL: "http://meet.onprem.test/j/1")
        XCTAssertNil(try XCTUnwrap(CalendarFit.pencil(for: http, message: message, timeZone: sample.calendar.timeZone)).joinURL)
        XCTAssertEqual(http.conferenceURL, "http://meet.onprem.test/j/1")
    }
}
