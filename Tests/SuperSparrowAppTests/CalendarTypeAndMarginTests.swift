import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The calendar's type and margins (spec §5.54, Quire 1.9.1 and 1.9.2): an event too narrow for its range shows its start
/// alone, the hatch over an invitation's overlap never runs through its words, a mark's chip never covers a fold's range,
/// and an hour label gives way to the now time where it is drawn.
@MainActor
final class CalendarTypeAndMarginTests: XCTestCase {
    private typealias Support = CalendarTestSupport
    private typealias Pane = Quire.Layout.CalendarPane

    override func tearDown() {
        Quire.Motion.finishAll()
        super.tearDown()
    }

    // MARK: The time line

    func testAnEventTooNarrowForItsRangeShowsItsStartAlone() {
        let range = "17:30 - 18:30"
        let wide = CalendarEventPainter.timeLine(range: range, start: "17:30", color: .black, width: 200)
        XCTAssertEqual(wide.string, range)
        let rangeWidth = CalendarType.width(of: wide)
        let narrow = CalendarEventPainter.timeLine(range: range, start: "17:30", color: .black, width: rangeWidth - 1)
        XCTAssertEqual(narrow.string, "17:30", "never “17:30 -…”")
        XCTAssertEqual(CalendarEventPainter.timeLine(range: range, start: "17:30", color: .black, width: rangeWidth).string, range,
                       "the range while it fits exactly")
    }

    // MARK: The gutter

    func testAnHourLabelHeldInsideTheTopGivesWayToANowJustPastIt() {
        let lineHeight: CGFloat = 14
        // 00:00 on the timeline's top edge is held at 0 to 14; now at 00:19 is 17 pt down, its label 10 to 24.
        let top = CalendarTimelineView.hourLabelTop(lineY: 0, lineHeight: lineHeight, fitHeight: 500)
        XCTAssertEqual(top, 0)
        XCTAssertTrue(CalendarTimelineView.hourLabelGivesWay(labelTop: top, lineHeight: lineHeight, nowY: 17),
                      "measured from the line it would have kept, 17 pt off, it overlapped the now label")
        // An hour line clear of the edges, and a now 20 pt from it, keeps its label.
        let middle = CalendarTimelineView.hourLabelTop(lineY: 200, lineHeight: lineHeight, fitHeight: 500)
        XCTAssertEqual(middle, 193)
        XCTAssertFalse(CalendarTimelineView.hourLabelGivesWay(labelTop: middle, lineHeight: lineHeight, nowY: 220))
        XCTAssertTrue(CalendarTimelineView.hourLabelGivesWay(labelTop: middle, lineHeight: lineHeight, nowY: 210))
        // At the bottom, held inside it too.
        XCTAssertEqual(CalendarTimelineView.hourLabelTop(lineY: 500, lineHeight: lineHeight, fitHeight: 500), 486)
    }

    // MARK: The hatch

    /// A pencilled invitation hatched over its whole face, drawn as the timeline draws it.
    private final class FaceView: NSView {
        var look: CalendarEventLook?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.qPaper.setFill()
            bounds.fill()
            if let look { CalendarEventPainter.draw(look) }
        }
    }

    /// Pixels of `rect` (points, flipped) whose colour is clearly saturated, as the `warning` hatch is and the words,
    /// `paper` and `rule` are not.
    private func saturatedPixels(in bitmap: NSBitmapImageRep, rect: NSRect) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / max(1, bitmap.size.width)
        var count = 0
        let minX = Int((rect.minX * scale).rounded(.down)), maxX = Int((rect.maxX * scale).rounded(.up))
        let minY = Int((rect.minY * scale).rounded(.down)), maxY = Int((rect.maxY * scale).rounded(.up))
        for y in max(0, minY)..<min(bitmap.pixelsHigh, maxY) {
            for x in max(0, minX)..<min(bitmap.pixelsWide, maxX) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if colour.saturationComponent > 0.35, colour.brightnessComponent > 0.2 { count += 1 }
            }
        }
        return count
    }

    func testTheHatchNeverRunsThroughAnInvitationsWords() throws {
        for mode in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            let face = NSRect(x: 10, y: 10, width: 160, height: 80)
            let event = Support.event("dinner", title: "Dinner", start: Support.at(19, 30), end: Support.at(22),
                                      response: .needsAction)
            let look = CalendarEventLook(
                event: event, face: face, slotHeight: face.height + 2 * Pane.eventInsetY, isPencilled: true, isSelected: false,
                isWindowKey: true, interaction: .rest, hatches: [(face.minY, face.height)], ink: .systemBlue, isAlone: true,
                moreCount: 0, joinWidth: 0, style: .column, timeText: "19:30 - 22:00", startText: "19:30", place: nil)
            let view = FaceView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
            view.look = look
            let window = Support.host(view, size: view.frame.size, appearance: mode.1)
            defer { window.close() }
            let bitmap = try XCTUnwrap(Support.render(view))

            let left = face.minX + Pane.eventPadLeading
            let timeTop = face.minY + Pane.eventPadTop
            let timeWidth = CalendarType.width(of: QuireFont.attributedString("19:30 - 22:00", role: .meta, color: .black))
            let titleTop = timeTop + QuireFont.Role.meta.lineHeight
            let titleWidth = CalendarType.width(of: CalendarType.line("Dinner", role: .label, color: .black, italic: true))
            let time = NSRect(x: left, y: timeTop, width: timeWidth, height: QuireFont.Role.meta.lineHeight)
            let title = NSRect(x: left, y: titleTop, width: titleWidth, height: QuireFont.Role.label.lineHeight)
            XCTAssertEqual(saturatedPixels(in: bitmap, rect: time), 0, "\(mode.0): under the time")
            XCTAssertEqual(saturatedPixels(in: bitmap, rect: title), 0, "\(mode.0): under the title")
            let below = NSRect(x: left, y: title.maxY + 4, width: 100, height: face.maxY - title.maxY - 8)
            XCTAssertGreaterThan(saturatedPixels(in: bitmap, rect: below), 50,
                                 "\(mode.0): the hatch still shows below the words")
        }
    }

    // MARK: Marks and folds

    func testAMarkAtAFoldsEdgeHangsIntoTheOpenHoursAndLeavesTheFoldsRangeClear() throws {
        let store = try Support.store()
        let conversation = ConversationID(accountID: Support.accountA.id, providerID: "thread-9")
        let message = MessageID(accountID: Support.accountA.id, providerID: "msg-9")
        try store.upsertMessages([MessageMetadata(id: message, conversationID: conversation, subject: "Friday", snippet: "",
                                                  from: nil, date: Support.at(8), roles: [.inbox], isRead: true, isStarred: false,
                                                  hasAttachments: false)])
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: ""), renderedHTML: "", plainText: ""), for: message)
        // 09:00 tomorrow, where the night's fold ends, with the column on Friday as the shell turns it for this mail.
        let nine = Support.at(9, on: Support.day(20))
        try store.saveMailTimes([MailTime(messageID: message, start: nine, phrase: "9am Friday")], for: message)
        try Support.write([], to: store)
        let state = Support.state(store: store)
        defer { state.tearDown() }
        let column = DayColumnView(state: state)
        // Short enough that no hour beyond the working day opens, so the night folds right up to 09:00.
        let window = Support.host(column, size: NSSize(width: Pane.columnWidth, height: 600))
        defer { window.close() }
        state.shownDay = Support.day(20)
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { column.timeline.placedMarks.contains { $0.mark.isMailTime } }))

        let timeline = column.timeline
        let fit = try XCTUnwrap(timeline.fit)
        let mark = try XCTUnwrap(timeline.placedMarks.first { $0.mark.isMailTime })
        let night = try XCTUnwrap(fit.folds.first, "the night folds")
        let band = timeline.foldRect(night)
        XCTAssertEqual(band.maxY, mark.lineY, accuracy: 1, "the mark's line is the fold's lower edge")
        for fold in fit.folds {
            XCTAssertFalse(mark.chip.intersects(timeline.foldRect(fold)), "the chip leaves every fold's range in sight")
        }
        XCTAssertEqual(mark.chip.minY, band.maxY, accuracy: 0.5, "it hangs from its line into the open hours")
    }
}
