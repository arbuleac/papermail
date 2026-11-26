import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// The column, its strip and the week drawn in light and dark at the 600 pt minimum height and at 900: every part has a
/// size, the fit placed the sample week, and the pixels are more than a blank page. `PAPER_RENDER_DIR=<dir>` writes the
/// renders there to look at.
@MainActor
final class CalendarRenderTests: XCTestCase {
    private typealias Support = CalendarTestSupport

    private let modes: [(name: String, appearance: NSAppearance)] = [
        ("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!),
    ]

    override func tearDown() {
        Quire.Motion.finishAll()
        super.tearDown()
    }

    private func sampleState() throws -> (CalendarState, InMemoryMailStore) {
        let store = try Support.store()
        try Support.write(Support.sampleWeek(), to: store)
        let state = Support.state(store: store)
        return (state, store)
    }

    func testTheColumnDrawsInLightAndDarkAtBothHeights() throws {
        let (state, _) = try sampleState()
        defer { state.tearDown() }
        for mode in modes {
            for height in [600.0, 900.0] {
                let column = DayColumnView(state: state)
                let window = Support.host(column, size: NSSize(width: Quire.Layout.CalendarPane.columnWidth, height: height),
                                          appearance: mode.appearance)
                defer { window.close() }
                XCTAssertEqual(column.timeline.frame.minY, CalendarMetrics.columnTimelineTop)
                XCTAssertGreaterThan(column.timeline.bounds.height, 0, "no zero-size timeline")
                let fit = try XCTUnwrap(column.timeline.fit, "the day is fitted")
                XCTAssertLessThanOrEqual(CGFloat(fit.allDayHeight + fit.hoursHeight), column.timeline.fitHeight + 0.5,
                                         "nothing scrolls: the fit stays inside the height")
                XCTAssertFalse(column.timeline.placed.isEmpty, "today's events are placed")
                XCTAssertFalse(column.timeline.placed.contains { $0.event.response == .declined }, "declined is never drawn")
                for placed in column.timeline.placed {
                    XCTAssertGreaterThan(placed.face.width, 0)
                    XCTAssertGreaterThan(placed.face.height, 0)
                    XCTAssertTrue(column.timeline.bounds.contains(placed.face), "\(placed.event.title) inside the timeline")
                }
                let bitmap = try XCTUnwrap(Support.render(column))
                assertDrawn(bitmap, "column \(mode.name) \(height)")
                Support.writeIfAsked(bitmap, name: "calendar-column-\(mode.name)-\(Int(height)).png")
            }
        }
    }

    func testTheStripDrawsInLightAndDarkAtBothHeights() throws {
        let (state, _) = try sampleState()
        defer { state.tearDown() }
        for mode in modes {
            for height in [600.0, 900.0] {
                let strip = DayStripView(state: state)
                let window = Support.host(strip, size: NSSize(width: Quire.Layout.CalendarPane.stripWidth, height: height),
                                          appearance: mode.appearance)
                defer { window.close() }
                XCTAssertFalse(strip.bars.isEmpty, "today's busy events show as bars")
                for bar in strip.bars { XCTAssertGreaterThan(bar.rect.height, 0) }
                XCTAssertNotNil(strip.nowY, "the now line on today")
                let bitmap = try XCTUnwrap(Support.render(strip))
                assertDrawn(bitmap, "strip \(mode.name) \(height)")
                Support.writeIfAsked(bitmap, name: "calendar-strip-\(mode.name)-\(Int(height)).png")
            }
        }
    }

    func testTheWeekDrawsInLightAndDarkAtBothHeights() throws {
        let (state, _) = try sampleState()
        defer { state.tearDown() }
        state.span = .week
        for mode in modes {
            for height in [600.0, 900.0] {
                let week = WeekView(state: state)
                let window = Support.host(week, size: NSSize(width: 1_000, height: height), appearance: mode.appearance)
                defer { window.close() }
                let fit = try XCTUnwrap(week.timeline.fit)
                XCTAssertEqual(fit.days.count, 7)
                XCTAssertTrue(fit.days[5].isFolded && fit.days[6].isFolded, "the empty weekend folds")
                XCTAssertEqual(week.headings.days.count, 7, "the headings follow the fit")
                XCTAssertGreaterThan(week.timeline.placed.count, 8)
                let bitmap = try XCTUnwrap(Support.render(week))
                assertDrawn(bitmap, "week \(mode.name) \(height)")
                Support.writeIfAsked(bitmap, name: "calendar-week-\(mode.name)-\(Int(height)).png")
            }
        }
    }

    func testTheCardsDrawInLightAndDark() throws {
        let (state, store) = try sampleState()
        defer { state.tearDown() }
        let conversation = ConversationID(accountID: Support.accountA.id, providerID: "thread-invite")
        let message = MessageID(accountID: Support.accountA.id, providerID: "msg-invite")
        try store.upsertMessages([MessageMetadata(id: message, conversationID: conversation, subject: "Design review", snippet: "",
                                                  from: nil, date: Support.at(8), roles: [.inbox], isRead: true, isStarred: false,
                                                  hasAttachments: false)])
        let invitation = CalendarInvitation(method: .request, uid: "mail-uid", title: "Design review", start: Support.at(13, 30),
                                            end: Support.at(14, 30), location: "Bay 4",
                                            organizer: .init(name: "Rachel Kim", address: "rachel@contoso.test"),
                                            userAddress: Support.accountA.email, userResponse: .needsAction)
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: ""), renderedHTML: "", plainText: "", invitation: invitation),
                           for: message)
        try store.saveMailTimes([MailTime(messageID: message, start: Support.at(16, 30), phrase: "4:30")], for: message)
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { state.selection?.invitation != nil }))
        for mode in modes {
            // The column beside a reader-sized space, its details open over it.
            let column = DayColumnView(state: state)
            let window = Support.host(NSView(), size: NSSize(width: 640, height: 820), appearance: mode.appearance)
            defer { window.close() }
            let host = try XCTUnwrap(window.contentView)
            column.frame = NSRect(x: 400, y: 0, width: 240, height: 820)
            host.addSubview(column)
            window.layoutIfNeeded()
            let review = try XCTUnwrap(column.timeline.placed.first { $0.event.title == "Contract call with Fabrikam" })
            column.timeline.activate(.event(review.event.id))
            let card = try XCTUnwrap(column.details.card)
            XCTAssertGreaterThan(card.frame.height, 60)
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(Support.render(host))
            assertDrawn(bitmap, "details \(mode.name)")
            Support.writeIfAsked(bitmap, name: "calendar-details-\(mode.name).png")
            column.dismissDetails()

            // The column opened over the reader's edge.
            column.isOverlay = true
            let overlay = try XCTUnwrap(Support.render(host))
            Support.writeIfAsked(overlay, name: "calendar-overlay-\(mode.name).png")
            column.isOverlay = false

            // The week with the invitation's card beside its pencil.
            state.span = .week
            let week = WeekView(state: state)
            let weekWindow = Support.host(week, size: NSSize(width: 1_064, height: 800), appearance: mode.appearance)
            defer { weekWindow.close(); state.span = .day }
            let invitationCard = try XCTUnwrap(week.selectionDetails)
            XCTAssertGreaterThan(invitationCard.frame.height, 100)
            let weekBitmap = try XCTUnwrap(Support.render(week))
            assertDrawn(weekBitmap, "week card \(mode.name)")
            Support.writeIfAsked(weekBitmap, name: "calendar-week-card-\(mode.name).png")
        }
    }

    /// An event's details with every row (spec §20): the kicker, the title, when, elsewhere, how it repeats, the overlap,
    /// Where, Call, Phone, Meeting ID, Passcode, Organizer, Guests, the Mail row, the notes, the answers, Join and Open in,
    /// drawn in light, dark and both Increase Contrast modes; in IC the footer's hairline is `ruleStrong`.
    func testTheDetailsCardWithEveryRowDrawsInEveryMode() throws {
        var event = Support.event("crit", title: "Design critique", start: Support.at(19), end: Support.at(20), response: .needsAction,
                                  joinURL: "https://teams.microsoft.com/l/x", location: "Bay 4", invitationUID: "uid-crit",
                                  webURL: "https://outlook.office.test/item")
        event.seriesID = "S"
        event.timeZone = "America/Los_Angeles"
        event.callService = .teams
        event.organizer = "Rachel Kim"
        let notes = "Weekly look at the reader and composer work. Bring one thing you would change: https://docs.example.test/crit"
        let details = CalendarEventDetails(
            organizer: EmailAddress(name: "Rachel Kim", address: "rachel@contoso.test"),
            guests: [EventGuest(name: "Alex Morgan", address: Support.accountA.email, response: .needsAction, isSelf: true),
                     EventGuest(name: "Marcus Bell", address: "marcus@contoso.test", response: .accepted),
                     EventGuest(name: "Aisha Patel", address: "aisha@contoso.test", response: .declined)],
            guestCount: 3, answersKnown: true,
            notes: EventNotes(text: notes, links: [EventNotes.Link(location: 79, length: 30, url: "https://docs.example.test/crit")]),
            call: EventCall(meetingID: "284 113 905 771", passcode: "Qx7bTe",
                            phones: [EventPhone(number: "+1 555-0134", dial: "+15550134,,601225430#", region: "US", pin: "601225430")],
                            pinLabel: .conferenceID, morePhonesURL: "https://dialin.example.test/more"),
            repeats: "Every week on Thursday, 12 times")
        let message = MessageMetadata(id: MessageID(accountID: Support.accountA.id, providerID: "m1"),
                                      conversationID: ConversationID(accountID: Support.accountA.id, providerID: "c1"),
                                      subject: "Design critique", snippet: "", from: EmailAddress(name: "Rachel Kim", address: "rachel@contoso.test"),
                                      to: [], date: Support.at(9, on: Support.day(12)), roles: [.inbox], isRead: true, isStarred: false,
                                      hasAttachments: false)
        let invitation = CalendarInvitation(method: .request, uid: "uid-crit", title: "Design critique", start: Support.at(19), end: Support.at(20),
                                            organizer: .init(name: "Rachel Kim", address: "rachel@contoso.test"))
        let text = CalendarText(calendar: Support.calendar)
        let model = EventDetailsModel(.init(
            event: event, details: details, related: RelatedInvitation(message: message, invitation: invitation),
            accountName: "Demo Outlook", dot: .qInk2, kind: .microsoft, overlap: "Overlaps Roadmap sync with Elena, 19:30 - 20:00",
            text: text, now: Support.at(11, 40)))
        XCTAssertEqual(model.rows.map(\.label), ["Where", "Call", "Phone", "Meeting ID", "Passcode", "Organizer", "Guests"])
        XCTAssertNotNil(model.elsewhere)
        XCTAssertNotNil(model.repeats)
        XCTAssertNotNil(model.overlap)
        XCTAssertNotNil(model.mail)
        XCTAssertNotNil(model.notes)
        XCTAssertNotNil(model.answers)

        for mode in QuireMode.allCases {
            var hairlines: [NSColor] = []
            let bitmap = try XCTUnwrap(QuireOffscreenRenderer.render(mode: mode, scale: 2) {
                let card = EventDetailsCardView()
                card.maxHeight = 900
                card.apply(model)
                hairlines = self.descendants(of: card).compactMap { ($0 as? NSBox)?.fillColor }
                let page = NSView(frame: NSRect(x: 0, y: 0, width: card.frame.width + 24, height: card.frame.height + 24))
                card.setFrameOrigin(NSPoint(x: 12, y: 12))
                page.addSubview(card)
                return page
            })
            assertDrawn(bitmap, "details card \(mode.rawValue)")
            Support.writeIfAsked(bitmap, name: "calendar-details-card-\(mode.rawValue).png")
            let strong = mode == .lightHC || mode == .darkHC
            XCTAssertEqual(hairlines.contains(.qRuleStrong), strong, "\(mode.rawValue): the footer's hairline is ruleStrong in IC alone")
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// More than a blank surface: many colours across the render (inks, words, rules).
    private func assertDrawn(_ bitmap: NSBitmapImageRep, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, label, file: file, line: line)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0, label, file: file, line: line)
        var colours: Set<UInt32> = []
        let step = 3
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(colour.redComponent * 31), g = UInt32(colour.greenComponent * 31), b = UInt32(colour.blueComponent * 31)
                colours.insert(r << 10 | g << 5 | b)
            }
        }
        XCTAssertGreaterThan(colours.count, 12, "\(label) draws more than a blank page", file: file, line: line)
    }
}
