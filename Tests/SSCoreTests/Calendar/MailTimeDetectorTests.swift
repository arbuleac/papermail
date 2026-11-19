import Foundation
import XCTest
@testable import SSCore

/// The times of day a message's words name (`MailTimeDetector`). The system detector resolves relative words against
/// the moment it runs, so every phrase here is written from today's date and every expectation worked out from it.
final class MailTimeDetectorTests: XCTestCase {
    private let message = MessageID(accountID: AccountID("detector"), providerID: "m1")
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        now = Date()
    }

    private func times(_ text: String, receivedHoursAgo hours: Double = 1, window: DateInterval? = nil,
                       calendar: Calendar? = nil) -> [MailTime] {
        MailTimeDetector.shared.times(in: text, messageID: message, received: now.addingTimeInterval(-hours * 3_600), now: now,
                                      window: window, calendar: calendar ?? self.calendar)
    }

    /// `hour:minute` on the day `days` after today.
    private func at(days: Int, _ hour: Int, _ minute: Int = 0, in calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? self.calendar!
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// Days from today to the next `weekday` (1 is Sunday), never today: the detector reads “Friday” on a Friday as next
    /// week's.
    private func daysToNext(weekday: Int) -> Int {
        (1...7).first { calendar.component(.weekday, from: at(days: $0, 12)) == weekday }!
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // MARK: Found

    func testAWeekdayAtAnHourIsFound() throws {
        let found = times("Hi Alex,\n\nCould we move our call to Friday at 3pm?\n\nJordan")
        XCTAssertEqual(found.count, 1)
        let time = try XCTUnwrap(found.first)
        XCTAssertEqual(time.start, at(days: daysToNext(weekday: 6), 15))
        XCTAssertEqual(time.phrase, "Friday at 3pm")
        XCTAssertEqual(time.messageID, message)
        XCTAssertNil(time.duration, "no length named")
    }

    func testTomorrowAtABareHourIsFound() {
        let found = times("See you tomorrow at 10.")
        XCTAssertEqual(found.map(\.start), [at(days: 1, 10)])
        XCTAssertEqual(found.map(\.phrase), ["tomorrow at 10"])
    }

    func testADateWithHoursAndMinutesIsFound() {
        let day = at(days: 6, 10)
        // The year only when the day falls in the next one, so the detector never takes it for this year's, gone by.
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        let phrase = format(day, sameYear ? "d MMM HH:mm" : "d MMM yyyy HH:mm")
        let found = times("Shall we say \(phrase) in the lobby?")
        XCTAssertEqual(found.map(\.start), [day])
        XCTAssertEqual(found.map(\.phrase), [phrase])
    }

    func testARangeKeepsItsLength() throws {
        let found = times("Friday from 3 to 4pm works for me.")
        let time = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(time.start, at(days: daysToNext(weekday: 6), 15))
        XCTAssertEqual(time.duration, 3_600)
    }

    func testNoonCountsAsATimeOfDay() {
        XCTAssertEqual(times("Lunch tomorrow at noon?").map(\.start), [at(days: 1, 12)])
    }

    // MARK: Left out

    func testADateWithoutATimeOfDayIsIgnored() {
        let day = format(at(days: 5, 12), "d MMMM")
        XCTAssertEqual(times("Your card will be charged on \(day). Next Tuesday works too."), [])
    }

    func testATimeGoneByIsIgnored() {
        XCTAssertEqual(times("We met yesterday at 3pm and again at 9:00 on \(format(at(days: -2, 9), "d MMMM yyyy")).").count, 0)
    }

    func testATimeOutsideTheCalendarWindowIsIgnored() {
        let far = at(days: CalendarWindow.daysAhead + 10, 10)
        XCTAssertEqual(times("Save the date: \(format(far, "d MMMM yyyy")) at 10am."), [])
        // The same time inside a window that holds it is found.
        let wide = DateInterval(start: now, duration: Double(CalendarWindow.daysAhead + 20) * 86_400)
        XCTAssertEqual(times("Save the date: \(format(far, "d MMMM yyyy")) at 10am.", window: wide).map(\.start), [far])
    }

    func testQuotedLinesAreIgnored() {
        XCTAssertEqual(times("Sounds good.\n> Could we move our call to Friday at 3pm?\n>> tomorrow at 10?"), [])
    }

    func testTheRepliesAMessageQuotesAreIgnored() {
        let gmail = """
            Works for me.

            On Tue, Nov 17, 2026 at 3:12 PM Priya Raman <priya.raman@demo-mail.test> wrote:
            Could we move our call to Friday at 3pm?
            """
        XCTAssertEqual(times(gmail), [])
        let outlook = """
            Thanks, see below.

            From: Rachel Kim <rachel.kim@northwind-labs.test>
            Sent: Tuesday, November 17, 2026 3:12 PM
            To: Alex Morgan <alex@demo-outlook.test>
            Subject: Q4 roadmap review

            Can we meet tomorrow at 10?
            """
        XCTAssertEqual(times(outlook), [])
        let original = "Noted.\n\n-----Original Message-----\nCan we meet tomorrow at 10?"
        XCTAssertEqual(times(original), [])
        // The sender's own words above the quote are read.
        XCTAssertEqual(times("Tomorrow at 10 then.\n\n" + original).map(\.start), [at(days: 1, 10)])
        // A signature's hours are not a time proposed.
        XCTAssertEqual(times("Talk soon.\n-- \nAlex Morgan\nOffice hours: tomorrow at 9am to 5pm"), [])
    }

    func testAtMostThreeAreKeptInTheOrderTheyAreNamed() {
        let text = "Options: tomorrow at 9am, tomorrow at 11am, tomorrow at 2pm, tomorrow at 4pm or tomorrow at 5pm."
        XCTAssertEqual(times(text).map(\.start), [at(days: 1, 9), at(days: 1, 11), at(days: 1, 14)])
    }

    func testTheSameTimeNamedTwiceIsFoundOnce() {
        XCTAssertEqual(times("Tomorrow at 10? To confirm: tomorrow at 10.").count, 1)
    }

    func testMailReceivedFourDaysAgoIsNotRead() {
        XCTAssertEqual(times("Could we move our call to Friday at 3pm?", receivedHoursAgo: 4 * 24), [])
        XCTAssertEqual(times("Could we move our call to Friday at 3pm?", receivedHoursAgo: 2 * 24).count, 1,
                       "two days ago is recent")
    }

    /// The detector reads a wall clock in the Mac's zone; a calendar in another zone gets the same wall clock in its own.
    func testTheWallClockIsReadInTheCalendarsZone() throws {
        let zone = ["Asia/Tokyo", "America/New_York"].compactMap(TimeZone.init(identifier:))
            .first { $0.secondsFromGMT(for: now) != TimeZone.current.secondsFromGMT(for: now) }!
        var elsewhere = Calendar(identifier: .gregorian)
        elsewhere.timeZone = zone
        let found = times("Could we move our call to Friday at 3pm?", calendar: elsewhere)
        let time = try XCTUnwrap(found.first)
        XCTAssertEqual(elsewhere.component(.hour, from: time.start), 15)
        XCTAssertEqual(elsewhere.component(.weekday, from: time.start), 6)
    }

    // MARK: The words

    func testTimesOfDayAreToldFromDates() {
        for phrase in ["3pm", "3 PM", "10:30 a.m.", "14:30", "14h30", "15 Uhr", "3 o'clock", "tomorrow at 10", "@ 4",
                       "noon", "Midnight"] {
            XCTAssertTrue(MailTimeDetector.namesTimeOfDay(phrase), phrase)
        }
        for phrase in ["25 Nov", "1 December", "next Tuesday", "this evening", "Friday afternoon", "2026-11-25",
                       "in 2026", "at 2026", "27.11.2026"] {
            XCTAssertFalse(MailTimeDetector.namesTimeOfDay(phrase), phrase)
        }
    }

    func testOnlyTheFirstSixteenKilobytesOfOwnWordsAreRead() {
        let filler = String(repeating: "Nothing to see here. ", count: 1_000)
        let own = MailTimeDetector.ownWords(of: filler + "\nTomorrow at 10?")
        XCTAssertLessThanOrEqual(own.utf8.count, MailTimeDetector.maximumScannedLength)
        XCTAssertEqual(times(filler + "\nTomorrow at 10?"), [])
        XCTAssertEqual(times("Tomorrow at 10?\n" + filler).count, 1)
    }

    // MARK: Cost

    /// Opt-in measurement: `SS_PERF=1 swift test -c release --filter MailTimeDetectorTests`. The detector runs beside the
    /// sanitizer for every recent body; its worst case is the cap's worth of text dense with times, and the common case a
    /// personal mail that names none, which the look for a time of day turns away before the detector runs.
    func testTheDetectorsCostPerBody() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("Set SS_PERF=1 to measure the mail time detector.")
        }
        let line = "Could we meet tomorrow at 10, or on Friday from 3 to 4pm, or else next Tuesday at 09:30? "
        let dense = String(repeating: line, count: MailTimeDetector.maximumScannedLength / line.utf8.count + 1)
        let plain = String(repeating: "Thanks for the notes. The draft reads well and the figures add up. ", count: 60)
        _ = times(dense)
        let iterations = 50
        let denseMs = Self.millisecondsPerIteration(iterations) { _ = times(dense) }
        let plainMs = Self.millisecondsPerIteration(iterations) { _ = times(plain) }
        print(String(format: "MailTimeDetector: %.2f ms for %d KB dense with times, %.3f ms for %d KB naming none",
                     denseMs, MailTimeDetector.maximumScannedLength / 1024, plainMs, plain.utf8.count / 1024))
        #if !DEBUG
        XCTAssertLessThan(denseMs, 40, "the cap keeps the worst body near the sanitizer's own cost")
        XCTAssertLessThan(plainMs, 1, "mail that names no time costs next to nothing")
        #endif
    }

    private static func millisecondsPerIteration(_ iterations: Int, _ block: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure {
            for _ in 0..<iterations { block() }
        }
        let perIteration = elapsed / iterations
        return Double(perIteration.components.seconds) * 1000 + Double(perIteration.components.attoseconds) / 1e15
    }
}
