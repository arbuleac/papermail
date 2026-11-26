import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// An event's details in the main window (spec §5.54): its links through the one opener, an answer stored first and
/// shown at once with the card left open, its give-up toasted once, Show the mail, single keys resting in the card.
@MainActor
final class MainWindowEventDetailsTests: XCTestCase {
    private typealias Support = CalendarTestSupport
    private var harnesses: [MainWindowHarness] = []
    private var opened: [URL] = []

    override func tearDown() {
        harnesses.forEach { $0.close() }
        harnesses = []
        opened = []
        super.tearDown()
    }

    private func harness() throws -> MainWindowHarness {
        let clock = Support.Clock()
        let harness = try MainWindowHarness(calendar: Support.calendar, now: { clock.now })
        harnesses.append(harness)
        harness.controller.openCalendarURL = { [weak self] url in self?.opened.append(url) }
        harness.controller.window?.layoutIfNeeded()
        harness.controller.desk.view.layoutSubtreeIfNeeded()
        return harness
    }

    private func invitation(_ harness: MainWindowHarness, response: CalendarEvent.Response = .needsAction) throws -> CalendarEvent {
        var event = Support.event("evt", title: "Quarterly planning", start: Support.at(15), end: Support.at(16, 30), response: response,
                                  joinURL: "https://teams.microsoft.com/l/x", location: "Microsoft Teams Meeting",
                                  invitationUID: "uid-planning", webURL: "https://calendar.google.com/event?eid=1")
        event.organizer = "Elena Rossi"
        try Support.write([event], to: harness.environment.store)
        harness.spin { harness.controller.desk.column.timeline.placed(withID: event.id) != nil }
        return event
    }

    // MARK: Links

    func testLinksGoThroughTheOneOpenerHttpsAndTelOnly() throws {
        let harness = try self.harness()
        let controller = harness.controller
        harness.settings.blocksTrackers = true
        XCTAssertTrue(controller.openEventLink(URL(string: "https://docs.example.test/plan?utm_source=mail&id=7")!))
        XCTAssertEqual(opened.last?.absoluteString, "https://docs.example.test/plan?id=7", "stripped while Block trackers is on")
        harness.settings.blocksTrackers = false
        XCTAssertTrue(controller.openEventLink(URL(string: "https://docs.example.test/plan?utm_source=mail")!))
        XCTAssertEqual(opened.last?.absoluteString, "https://docs.example.test/plan?utm_source=mail", "kept when it is off")
        XCTAssertTrue(controller.openEventLink(EventLinkPolicy.phoneURL("+15550134,,601225430#")!))
        XCTAssertEqual(opened.last?.absoluteString, "tel:+15550134,,601225430%23")
        let before = opened.count
        for refused in ["http://plain.example.test/", "javascript:alert(1)", "file:///etc/passwd", "https://zoom.us@evil.test/j/1",
                        "mailto:x@example.test", "maps://?q=Casa"] {
            XCTAssertFalse(controller.openEventLink(URL(string: refused)!), refused)
        }
        XCTAssertEqual(opened.count, before, "nothing refused ever opens")
        XCTAssertFalse(opened.contains { $0.absoluteString.contains("maps") }, "no maps link, ever")
    }

    // MARK: Answers

    func testAcceptStoresFirstAndTheCardStaysOpenWaiting() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let column = harness.controller.desk.column
        column.timeline.activate(.event(event.id))
        let card = try XCTUnwrap(column.details.card)
        XCTAssertEqual(card.model?.answers?.chosen, nil)
        let accept = try XCTUnwrap(card.buttons.first { $0.title == "Accept" })
        accept.performClick(nil)
        XCTAssertEqual(try harness.environment.store.calendarEvent(id: event.id)?.response, .accepted, "store first")
        harness.spin { column.details.card?.model?.answers?.waiting == true }
        XCTAssertTrue(column.details.card === card, "the card stays open")
        XCTAssertEqual(card.model?.answers, .init(chosen: .accepted, waiting: true, asksSpan: false))
        XCTAssertEqual(card.answerButtons[.accepted]?.isOn, true)
        XCTAssertEqual(card.answerButtons[.accepted]?.onSymbol, Quire.Icon.pending, "the queued glyph while it waits")
        let queued = try harness.environment.store.pendingOperations(accountID: event.accountID, limit: 10)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.targets, [], "no mail: answered on the calendar")
        XCTAssertNil(harness.toastMessage, "no toast, no undo")

        // A click on the chosen one does nothing.
        accept.performClick(nil)
        XCTAssertEqual(try harness.environment.store.pendingOperations(accountID: event.accountID, limit: 10).count, 1)
    }

    func testAGivenUpAnswerPutsTheFaceBackSaysSoOnTheCardAndToastsOnce() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let column = harness.controller.desk.column
        column.timeline.activate(.event(event.id))
        try XCTUnwrap(column.details.card?.buttons.first { $0.title == "Tentative" }).performClick(nil)
        var operation = try XCTUnwrap(try harness.environment.store.pendingOperations(accountID: event.accountID, limit: 10).first)
        operation.status = .failed
        try harness.environment.store.updateOperation(operation)
        harness.spin { column.details.card?.model?.answerLine == .failed }
        XCTAssertEqual(column.details.card?.model?.answerLine, .failed)
        XCTAssertEqual(try harness.environment.store.calendarEvent(id: event.id)?.response, .needsAction, "put back")
        harness.spin { harness.toastMessage != nil }
        XCTAssertEqual(harness.toastMessage, "Couldn't answer the invitation. Restored.")
    }

    // MARK: Copy

    func testACopyWritesTheValueAsWrittenAndTheButtonSaysCopiedForAMoment() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let column = harness.controller.desk.column
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        column.details.pasteboard = board
        column.details.copiedDuration = 0.2
        column.timeline.activate(.event(event.id))
        let card = try XCTUnwrap(column.details.card)
        let copy = try XCTUnwrap(card.keyViews.compactMap { $0 as? QuireIconButton }.first)
        XCTAssertEqual(copy.accessibilityLabel(), "Copy link")
        XCTAssertEqual(copy.toolTip, "Copy Link")
        copy.performClick(nil)
        XCTAssertEqual(board.string(forType: .string), "https://teams.microsoft.com/l/x", "as written, never stripped")
        XCTAssertTrue(copy.isOn, "the check")
        XCTAssertEqual(copy.toolTip, "Copied")
        harness.spin { !copy.isOn }
        XCTAssertFalse(copy.isOn, "and back")
        XCTAssertEqual(copy.toolTip, "Copy Link")
    }

    // MARK: Keyboard

    func testTheKeyboardOpensOnJoinNeverAnAnswerAndSingleKeysRest() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let column = harness.controller.desk.column
        column.timeline.activate(.event(event.id), fromKeyboard: true)
        let card = try XCTUnwrap(column.details.card)
        let responder = harness.controller.window?.firstResponder as? QuireButton
        XCTAssertEqual(responder?.title, "Join", "focus on Join, never an answer")
        XCTAssertTrue(KeyboardRouter.isTextInput(responder), "single keys rest while focus is in the card")
        let titles = card.keyViews.compactMap { ($0 as? QuireButton)?.title }
        XCTAssertEqual(titles, ["Accept", "Tentative", "Decline", "Join", "Open in Google Calendar"], "the Tab loop in order")
        XCTAssertTrue(card.keyViews.last?.nextKeyView === card.keyViews.first, "around and around")
        card.cancelOperation(nil)
        XCTAssertNil(column.details.card, "Esc closes it")
    }

    // MARK: VoiceOver

    func testTheCardIsADialogNamedByItsTitle() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let column = harness.controller.desk.column
        column.timeline.activate(.event(event.id))
        let card = try XCTUnwrap(column.details.card)
        XCTAssertEqual(card.accessibilityRole(), .group)
        XCTAssertEqual(card.accessibilitySubrole(), .dialog)
        XCTAssertEqual(card.accessibilityLabel(), "Quarterly planning")
        XCTAssertEqual(card.accessibilityHelp(), "Event details")
        let accept = try XCTUnwrap(card.answerButtons[.accepted])
        XCTAssertEqual(accept.accessibilitySubrole(), .toggle)
        XCTAssertEqual(accept.accessibilityValue() as? NSNumber, 0)
    }
}
