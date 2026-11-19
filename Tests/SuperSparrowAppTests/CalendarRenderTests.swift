import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The column, its strip and the week drawn in light and dark at the 600 pt minimum height and at 900: every part has a
/// size, the fit placed the sample week, and the pixels are more than a blank page. `SS_RENDER_DIR=<dir>` writes the
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
            let invitationCard = try XCTUnwrap(week.invitationCard)
            XCTAssertGreaterThan(invitationCard.frame.height, 100)
            let weekBitmap = try XCTUnwrap(Support.render(week))
            assertDrawn(weekBitmap, "week card \(mode.name)")
            Support.writeIfAsked(weekBitmap, name: "calendar-week-card-\(mode.name).png")
        }
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
