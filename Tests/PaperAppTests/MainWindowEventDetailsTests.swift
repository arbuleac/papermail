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

    private var suites: [String] = []
    private var analyticsHooks: (active: () -> Bool, key: () -> Bool)?

    override func tearDown() {
        harnesses.forEach { $0.close() }
        harnesses = []
        opened = []
        if let analyticsHooks {
            Analytics.reset(transport: TelemetryDeckTransport(), defaults: .standard)
            Analytics.appIsActive = analyticsHooks.active
            Analytics.keyIsBeingHandled = analyticsHooks.key
        }
        analyticsHooks = nil
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    /// Analytics started on a recorder, as a launch with an app ID starts it; `tearDown` puts it back.
    private func recordAnalytics() throws -> RecordingAnalyticsTransport {
        analyticsHooks = (Analytics.appIsActive, Analytics.keyIsBeingHandled)
        let suite = "MainWindowEventDetailsTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let recorder = RecordingAnalyticsTransport()
        Analytics.reset(transport: recorder, defaults: defaults)
        Analytics.performanceSampleRate = 0
        var launch = LaunchOptions(arguments: ["Paper"])
        launch.telemetryAppID = "TEST-APP-ID"
        XCTAssertTrue(Analytics.start(launch: launch, defaults: defaults, bundle: Bundle(for: Self.self)))
        return recorder
    }

    /// A plain key as the window delivers it, down then up, to its first responder and up the responder chain (the
    /// keyboard router lets every key through while focus is in the card: `isTextInput`). The test window is never
    /// key, so the window is sent the key itself.
    private func press(_ characters: String, keyCode: UInt16, in window: NSWindow) throws {
        XCTAssertTrue(KeyboardRouter.isTextInput(window.firstResponder), "the router stands aside")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
            window.sendEvent(event)
        }
    }

    /// Every view under `view`, depth first.
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
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

    /// ↩ and keypad Enter press the control that has focus, as Space does; Esc closes the card from anywhere in it.
    func testReturnPressesTheFocusedControlAndEscClosesTheCard() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let column = harness.controller.desk.column
        let window = try XCTUnwrap(harness.controller.window)
        column.timeline.activate(.event(event.id), fromKeyboard: true)
        XCTAssertEqual((window.firstResponder as? QuireButton)?.title, "Join")
        try press("\r", keyCode: 36, in: window)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://teams.microsoft.com/l/x"], "↩ on Join joins")
        XCTAssertNotNil(column.details.card, "and the card stays")

        let accept = try XCTUnwrap(column.details.card?.answerButtons[.accepted])
        XCTAssertTrue(window.makeFirstResponder(accept))
        try press("\u{3}", keyCode: 76, in: window)
        XCTAssertEqual(try harness.environment.store.calendarEvent(id: event.id)?.response, .accepted, "Enter on Accept answers")
        harness.spin { column.details.card?.model?.answers?.waiting == true }
        XCTAssertTrue(column.details.card?.answerButtons[.accepted] === window.firstResponder, "focus kept on the answer")

        try press("\u{1b}", keyCode: 53, in: window)
        XCTAssertNil(column.details.card, "Esc, with focus on a control in it")
        XCTAssertTrue(window.firstResponder === column.timeline || (window.firstResponder as? NSView)?.isDescendant(of: column.timeline) == true,
                      "focus back on the event")
    }

    /// A Font, Text size or Quire setting change, or the appearance's, builds the open card again.
    func testTheCardIsBuiltAgainWhenTheEnvironmentChanges() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let column = harness.controller.desk.column
        column.timeline.activate(.event(event.id))
        let card = try XCTUnwrap(column.details.card)
        let before = try XCTUnwrap(card.answerButtons[.accepted])
        NotificationCenter.default.post(name: QuireEnvironment.didChangeNotification, object: nil)
        XCTAssertTrue(column.details.card === card, "the same card, in place")
        XCTAssertFalse(card.answerButtons[.accepted] === before, "its parts made again")
        let rebuilt = card.answerButtons[.accepted]
        card.appearance = NSAppearance(named: card.effectiveAppearance.name == .darkAqua ? .aqua : .darkAqua)
        XCTAssertFalse(card.answerButtons[.accepted] === rebuilt, "and on an appearance change")
    }

    // MARK: Show the mail

    /// From the week, Show the mail brings the reader and the column back on the event's day, the column shown even
    /// when it was hidden before the week.
    func testShowTheMailFromTheWeekComesBackOnTheEventsDay() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let conversation = harness.list.conversations[2].id
        let mail = try XCTUnwrap(try harness.environment.store.messages(in: conversation).max { $0.date < $1.date })
        let aside = Support.event("aside", title: mail.subject, start: Support.at(15, on: Support.day(20)),
                                  end: Support.at(15, 30, on: Support.day(20)), sourceMessage: mail.id)
        try Support.write([aside], to: harness.environment.store)
        XCTAssertTrue(controller.perform(.toggleDayColumn), "D hides the column")
        XCTAssertFalse(controller.desk.isColumnOn)
        XCTAssertTrue(controller.perform(.toggleWeek))
        let week = controller.desk.week
        week.layoutSubtreeIfNeeded()
        harness.spin { week.timeline.placed(withID: aside.id) != nil }
        week.timeline.activate(.event(aside.id))
        harness.spin { week.details.card?.model?.mail?.message != nil }
        let card = try XCTUnwrap(week.details.card)
        let button = try XCTUnwrap(descendants(of: card).compactMap { $0 as? MailButton }.first)
        button.performClick(nil)
        XCTAssertEqual(controller.desk.placement, .column)
        XCTAssertTrue(controller.desk.isColumnOn, "the column comes back with the reader")
        XCTAssertEqual(controller.calendarState.shownDay, Support.day(20), "on the event's day, not the week's")
        XCTAssertEqual(harness.list.selectedConversationID, conversation)
    }

    // MARK: Analytics

    /// An occurrence answered with no menu (its mail invites to it alone) is counted as the engine answers it: one
    /// occurrence. Nothing is counted when nothing is queued.
    func testAnOccurrenceAnsweredWithoutTheMenuCountsAsAnOccurrence() throws {
        let harness = try self.harness()
        var event = try invitation(harness)
        event.seriesID = "S"
        event.originalStart = event.start
        try Support.write([event], to: harness.environment.store)
        let recorder = try recordAnalytics()
        harness.controller.answerCalendarEvent(.accepted, eventID: event.id, span: .single, invitationMessage: nil)
        let sent = recorder.sent.filter { $0.name == "Calendar.invitationAnswered" }
        XCTAssertEqual(sent.map { $0.parameters["span"] }, ["occurrence"])
        XCTAssertEqual(sent.first?.parameters["route"], "calendar")
        harness.controller.answerCalendarEvent(.accepted, eventID: event.id, span: .single, invitationMessage: nil)
        XCTAssertEqual(recorder.sent.filter { $0.name == "Calendar.invitationAnswered" }.count, 1, "the same again: nothing queued")
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

    /// The hairlines (above the notes, above the answers) are drawn, never an unnamed group VoiceOver stops on. In the
    /// Phone row, Tab and VoiceOver go as it reads: the number, its Copy, then More phone numbers.
    func testTheHairlinesAreNoStopAndThePhoneRowGoesInTheOrderItReads() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let call = EventCall(phones: [EventPhone(number: "+1 555-0134", dial: "+15550134,,601225430#", region: "US", pin: "601225430")],
                             morePhonesURL: "https://tel.meet.example.test/abc")
        XCTAssertTrue(try harness.environment.store.saveCalendarEventDetails(
            CalendarEventDetails(notes: EventNotes(text: "Agenda: the numbers."), call: call), eventID: event.id, version: nil,
            readAt: Support.today))
        let column = harness.controller.desk.column
        column.timeline.activate(.event(event.id))
        harness.spin { column.details.card?.model?.notes != nil }
        let card = try XCTUnwrap(column.details.card)
        let boxes = descendants(of: card).compactMap { $0 as? NSBox }
        XCTAssertGreaterThanOrEqual(boxes.count, 2)
        XCTAssertTrue(boxes.allSatisfy { !$0.isAccessibilityElement() }, "no hairline is a VoiceOver stop")

        let row = try XCTUnwrap(descendants(of: card).compactMap { $0 as? EventDetailsRowView }.first { $0.row.label == "Phone" })
        let names = row.controls.map { ($0 as? QuireButton)?.title ?? $0.accessibilityLabel() ?? "" }
        XCTAssertEqual(names, ["+1 555-0134", "Copy phone number", "More phone numbers"])
        let keys = card.keyViews.filter { row.controls.contains($0) }
        XCTAssertTrue(keys.elementsEqual(row.controls, by: ===), "Tab goes the same way")
        let spoken = (row.accessibilityChildren() ?? []).compactMap { $0 as? NSView }.filter { $0 is QuireControl }
        XCTAssertTrue(spoken.elementsEqual(row.controls, by: ===), "and VoiceOver")
    }

    /// The Mail row's face ends inside the scrolling middle, with room for its focus ring: nothing of it is cut.
    func testTheMailRowsFaceAndRingFitTheMiddle() throws {
        let harness = try self.harness()
        let conversation = harness.list.conversations[3].id
        let mail = try XCTUnwrap(try harness.environment.store.messages(in: conversation).max { $0.date < $1.date })
        let aside = Support.event("aside", title: mail.subject, start: Support.at(15), end: Support.at(15, 30), sourceMessage: mail.id)
        try Support.write([aside], to: harness.environment.store)
        let column = harness.controller.desk.column
        harness.spin { column.timeline.placed(withID: aside.id) != nil }
        column.timeline.activate(.event(aside.id))
        harness.spin { column.details.card?.model?.mail?.message != nil }
        let card = try XCTUnwrap(column.details.card)
        card.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(descendants(of: card).compactMap { $0 as? MailButton }.first)
        let clip = try XCTUnwrap(button.enclosingScrollView?.contentView)
        let face = clip.convert(button.bounds, from: button)
        let ring = QuireFocusRing.outset(gap: QuireFocusRing.gap, width: QuireFocusRing.width(increasedContrast: true))
        XCTAssertLessThanOrEqual(face.maxX + ring, clip.bounds.maxX, "the right side of the face and its ring stay in view")
        XCTAssertGreaterThanOrEqual(face.minX - ring, clip.bounds.minX)
    }
}
