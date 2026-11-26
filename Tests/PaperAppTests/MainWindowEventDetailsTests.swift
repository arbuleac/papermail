import AppKit
import ObjectiveC
import OSLog
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
        // Time set aside has the Mail row alone in its middle: its first part and its last.
        XCTAssertGreaterThanOrEqual(face.minY - ring, clip.bounds.minY, "the ring fits above it, at the middle's top")
        XCTAssertLessThanOrEqual(face.maxY + ring, clip.bounds.maxY, "and below it, at the middle's bottom")
        let middleTop = card.convert(button.bounds, from: button).minY
        let covers = descendants(of: card).compactMap { $0 as? EdgeCover }
        XCTAssertEqual(covers.count, 2)
        XCTAssertTrue(covers.allSatisfy(\.isHidden), "nothing is cut, so no hairline and no cover")
        XCTAssertEqual(covers.map { $0.frame.maxY - 1 }.min() ?? 0, middleTop, accuracy: 0.5,
                       "the top hairline would sit on the middle's edge, where the face starts")
    }

    // MARK: The span menu, Outlook's decline, the permission

    /// On a repeating event an answer asks This Event or All Events in a menu under it. Opened from the keyboard (↩ on the
    /// answer), it holds the two and no key equivalents, so its own arrows and ↩ choose; nothing is queued until one is
    /// chosen, and each answers its span.
    func testTheSpanMenuOpensFromTheKeyboardAndAnswersTheOccurrenceOrTheSeries() throws {
        let harness = try self.harness()
        var event = try invitation(harness)
        event.seriesID = "series-planning"
        event.originalStart = event.start
        var next = event
        next.id = CalendarEvent.localID(accountID: event.accountID, providerID: "evt-next")
        next.providerID = "evt-next"
        next.start = event.start.addingTimeInterval(7 * 86_400)
        next.end = event.end.addingTimeInterval(7 * 86_400)
        next.originalStart = next.start
        try Support.write([event, next], to: harness.environment.store)
        let store = harness.environment.store
        let column = harness.controller.desk.column
        let window = try XCTUnwrap(harness.controller.window)
        var menus: [(menu: NSMenu, under: QuireButton)] = []
        column.details.presentSpanMenu = { menu, button in menus.append((menu, button)) }
        harness.spin { harness.controller.calendarState.events.contains { $0.id == event.id && $0.seriesID != nil } }
        column.timeline.activate(.event(event.id), fromKeyboard: true)
        harness.spin { column.details.card?.model?.answers?.asksSpan == true }
        let card = try XCTUnwrap(column.details.card)
        XCTAssertEqual(card.model?.answers?.asksSpan, true)

        let accept = try XCTUnwrap(card.answerButtons[.accepted])
        XCTAssertTrue(window.makeFirstResponder(accept))
        try press("\r", keyCode: 36, in: window)
        let first = try XCTUnwrap(menus.last)
        XCTAssertTrue(first.under === accept, "under the answer pressed")
        XCTAssertEqual(first.menu.items.map(\.title), ["This Event", "All Events"])
        XCTAssertTrue(first.menu.items.allSatisfy { $0.keyEquivalent.isEmpty && $0.isEnabled }, "chosen by the menu's own keys")
        XCTAssertTrue(try store.pendingOperations(accountID: event.accountID, limit: 10).isEmpty, "nothing until a choice (Esc chooses none)")
        first.menu.performActionForItem(at: 0)
        XCTAssertEqual(try store.calendarEvent(id: event.id)?.response, .accepted, "This Event: the occurrence")
        XCTAssertEqual(try store.calendarEvent(id: next.id)?.response, .needsAction)

        harness.spin { column.details.card?.model?.answers?.chosen == .accepted }
        let tentative = try XCTUnwrap(column.details.card?.answerButtons[.tentative])
        XCTAssertTrue(window.makeFirstResponder(tentative))
        try press(" ", keyCode: 49, in: window)
        let second = try XCTUnwrap(menus.last)
        XCTAssertEqual(menus.count, 2, "Space opens it too")
        second.menu.performActionForItem(at: 1)
        XCTAssertEqual(try store.calendarEvent(id: event.id)?.response, .tentative, "All Events: every occurrence")
        XCTAssertEqual(try store.calendarEvent(id: next.id)?.response, .tentative)
        XCTAssertNotNil(column.details.card, "the card stays open")
    }

    /// Decline on Outlook says Outlook takes the event off the calendar, and the card closes when the read that follows
    /// sweeps the row.
    func testOutlooksDeclineLineAndTheCardClosesWhenTheReadSweepsTheRow() throws {
        let harness = try self.harness()
        let store = harness.environment.store
        let event = Support.event("ol", account: Support.accountB, title: "Vendor sync", start: Support.at(15), end: Support.at(16),
                                  response: .needsAction, invitationUID: "uid-vendor", webURL: "https://outlook.office.test/item")
        try Support.write([event], to: store)
        let column = harness.controller.desk.column
        harness.spin { column.timeline.placed(withID: event.id) != nil }
        column.timeline.activate(.event(event.id))
        try XCTUnwrap(column.details.card?.answerButtons[.declined]).performClick(nil)
        harness.spin { column.details.card?.model?.answerLine == .outlookDecline }
        let card = try XCTUnwrap(column.details.card)
        XCTAssertEqual(card.model?.answerLine, .outlookDecline)
        let words = descendants(of: card).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(words.contains("Outlook takes declined events off your calendar."))

        let sent = try XCTUnwrap(try store.pendingOperations(accountID: event.accountID, limit: 10).first)
        try store.confirmOperation(id: sent.id)
        try Support.write([], to: store)
        harness.spin { column.details.card == nil }
        XCTAssertNil(column.details.card, "gone from the calendar, the card goes with it")
    }

    /// While an answer waits for the calendar's permission, the card says so and Reconnect asks for it, for that account.
    func testThePermissionBannerAsksToReconnectWhileAnAnswerWaitsForIt() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let controller = harness.controller
        var asked: [AccountID] = []
        controller.onConnectCalendar = { account, _ in asked.append(account.id) }
        let column = controller.desk.column
        column.timeline.activate(.event(event.id))
        try XCTUnwrap(column.details.card?.answerButtons[.accepted]).performClick(nil)
        harness.spin { column.details.card?.model?.answers?.waiting == true }
        XCTAssertNil(column.details.card?.keyed.first { $0.key == "answer.reconnect" }, "no banner while nothing waits for it")

        controller.calendarState.statusesChanged([AccountSyncStatus(accountID: event.accountID, phase: .idle, permissionsNeeded: [.calendar],
                                                                    calendar: .current(Support.at(11)))])
        harness.spin { column.details.card?.model?.answerLine == .permission(event.accountID) }
        let card = try XCTUnwrap(column.details.card)
        let banner = try XCTUnwrap(descendants(of: card).compactMap { $0 as? QuireBannerView }.first)
        XCTAssertFalse(banner.isHidden)
        let reconnect = try XCTUnwrap(card.keyed.first { $0.key == "answer.reconnect" }?.view as? QuireButton)
        XCTAssertEqual(reconnect.title, "Reconnect")
        reconnect.performClick(nil)
        XCTAssertEqual(asked, [event.accountID], "that account's permission asked for")

        controller.calendarState.statusesChanged([AccountSyncStatus(accountID: event.accountID, phase: .idle,
                                                                    calendar: .current(Support.at(11)))])
        harness.spin { column.details.card?.model?.answerLine == nil }
        XCTAssertNil(column.details.card?.model?.answerLine, "granted: the banner goes")
    }

    /// Show the mail of time set aside for a mail now in the Trash: the list turns to the Trash, which alone lists it.
    func testShowTheMailInTheTrashTurnsTheListToTheTrash() throws {
        let harness = try self.harness()
        let store = harness.environment.store
        let conversation = harness.list.conversations[4].id
        let messages = try store.messages(in: conversation)
        try store.upsertMessages(messages.map { message in
            var trashed = message
            trashed.roles = [.trash]
            return trashed
        })
        let mail = try XCTUnwrap(messages.max { $0.date < $1.date })
        let aside = Support.event("aside", title: mail.subject, start: Support.at(15), end: Support.at(15, 30), sourceMessage: mail.id)
        try Support.write([aside], to: store)
        let column = harness.controller.desk.column
        harness.spin { column.timeline.placed(withID: aside.id) != nil }
        column.timeline.activate(.event(aside.id))
        harness.spin { column.details.card?.model?.mail?.message != nil }
        let card = try XCTUnwrap(column.details.card)
        XCTAssertTrue(card.model?.mail?.meta.hasSuffix("In the Trash") == true, card.model?.mail?.meta ?? "")
        try XCTUnwrap(descendants(of: card).compactMap { $0 as? MailButton }.first).performClick(nil)
        XCTAssertEqual(harness.controller.listView, .trash)
        XCTAssertEqual(harness.list.selectedConversationID, conversation)
        XCTAssertNil(column.details.card, "the card closes on Show the mail")
    }

    /// A re-read of the selected conversation (a body arrived, its times found) keeps the card open; another
    /// conversation selected closes it.
    func testAReReadOfTheSelectedConversationKeepsTheCardAndAnotherClosesIt() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let controller = harness.controller
        let state = controller.calendarState
        let selected = harness.list.conversations[0].id
        controller.showConversation(selected)
        harness.spin { state.selectedConversation == selected && state.selection != nil }
        let column = controller.desk.column
        column.timeline.activate(.event(event.id))
        let card = try XCTUnwrap(column.details.card)

        let mail = try XCTUnwrap(try harness.environment.store.messages(in: selected).first)
        try harness.environment.store.saveMailTimes([MailTime(messageID: mail.id, start: Support.at(17), phrase: "5pm")], for: mail.id)
        state.reloadSelection()
        harness.spin { state.selection?.mailTimes.isEmpty == false }
        XCTAssertEqual(state.selection?.mailTimes.count, 1, "read again")
        XCTAssertTrue(column.details.card === card, "the same card stays open")

        controller.showConversation(harness.list.conversations[1].id)
        harness.spin { column.details.card == nil }
        XCTAssertNil(column.details.card, "another conversation closes it")
    }

    // MARK: Privacy

    /// No title, place, note, name, address, link or number of an event reaches the log at info or above along the
    /// card's paths: opened by click and by key, a copy and a refused one, an answer, a link opened and one refused,
    /// Esc.
    func testNothingOfAnEventReachesTheLogAboveDebug() throws {
        let start = Date()
        let harness = try self.harness()
        let store = harness.environment.store
        let secrets = ["Zebra Quorum Ninefold", "Larkspur Wharf 9", "ochre folder", "Quentin Vasquez", "quentin@larkspur.test",
                       "Imogen Thackeray", "zq9-join", "555-0177", "731 204 556", "Pq4Lm"]
        var event = Support.event("secret", title: secrets[0], start: Support.at(15), end: Support.at(16), response: .needsAction,
                                  joinURL: "https://teams.microsoft.com/l/zq9-join", location: secrets[1], invitationUID: "uid-secret",
                                  webURL: "https://calendar.google.com/event?eid=zq9")
        event.organizer = secrets[3]
        try Support.write([event], to: store)
        let details = CalendarEventDetails(
            organizer: EmailAddress(name: secrets[3], address: secrets[4]),
            guests: [EventGuest(name: secrets[5], address: "imogen@larkspur.test", response: .accepted)], guestCount: 1, answersKnown: true,
            notes: EventNotes(text: "Bring the ochre folder: https://docs.larkspur.test/zq9",
                              links: [EventNotes.Link(location: 30, length: 26, url: "https://docs.larkspur.test/zq9")]),
            call: EventCall(meetingID: secrets[8], passcode: secrets[9],
                            phones: [EventPhone(number: "+1 555-0177", dial: "+15550177,,731204556#", region: "US", pin: "731204556")]))
        XCTAssertTrue(try store.saveCalendarEventDetails(details, eventID: event.id, version: nil, readAt: Support.today))
        let column = harness.controller.desk.column
        harness.spin { column.timeline.placed(withID: event.id) != nil }

        column.timeline.activate(.event(event.id), fromKeyboard: true)
        harness.spin { column.details.card?.model?.notes != nil }
        let card = try XCTUnwrap(column.details.card)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        column.details.pasteboard = board
        for copy in card.keyViews.compactMap({ $0 as? QuireIconButton }) { copy.performClick(nil) }
        // AppKit hands pasteboards out from a factory, so the board takes a refusing subclass's class for the write.
        object_setClass(board, RefusingPasteboard.self)
        card.keyViews.compactMap { $0 as? QuireIconButton }.first?.performClick(nil)
        object_setClass(board, NSPasteboard.self)
        try XCTUnwrap(card.answerButtons[.tentative]).performClick(nil)
        XCTAssertTrue(harness.controller.openEventLink(URL(string: "https://docs.larkspur.test/zq9")!))
        XCTAssertFalse(harness.controller.openEventLink(URL(string: "http://docs.larkspur.test/zq9")!))
        card.cancelOperation(nil)
        column.timeline.activate(.event(event.id))
        XCTAssertNotNil(column.details.card)
        // A line the capture must find, so an empty capture never passes for a clean one.
        let sentinel = "event log check \(UUID().uuidString)"
        CalendarSignposts.log.notice("\(sentinel, privacy: .public)")
        // The store hands lines over late while the whole suite logs: read it again until the sentinel is there.
        var loud: [OSLogEntryLog] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            ListTestSupport.spin(for: 0.25)
            let logs = try OSLogStore(scope: .currentProcessIdentifier)
            loud = try logs.getEntries(at: logs.position(date: start.addingTimeInterval(-1)),
                                       matching: NSPredicate(format: "subsystem == %@", AppIdentity.bundleIdentifier))
                .compactMap { $0 as? OSLogEntryLog }.filter { $0.level != .debug && $0.level != .undefined }
        } while !loud.contains(where: { $0.composedMessage == sentinel }) && Date() < deadline
        XCTAssertTrue(loud.contains { $0.composedMessage == sentinel }, "the capture sees this process's lines")
        XCTAssertTrue(loud.contains { $0.composedMessage == "copying an event detail failed" }, "the refused copy said so, and only so")
        let leaks = loud.map(\.composedMessage).filter { line in secrets.contains { line.contains($0) } || line.contains("larkspur") }
        XCTAssertEqual(leaks, [], "nothing of the event at info or above")
    }

    // MARK: Overlap

    /// The card counts what the reader's card counts (§5.14): every account's busy events, the meeting's own copies left
    /// out wherever they are, so a copy in the other account is no overlap and that account's other invitation is one.
    func testTheCardsOverlapLeavesOutTheMeetingsCopiesAndCountsEveryAccount() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let copyThere = Support.event("copy-there", account: Support.accountB, title: "Quarterly planning", start: Support.at(15),
                                      end: Support.at(16, 30), response: .accepted, invitationUID: "uid-planning")
        let vendor = Support.event("vendor", account: Support.accountB, title: "Vendor call", start: Support.at(16),
                                   end: Support.at(17), response: .needsAction, invitationUID: "uid-vendor")
        try Support.write([event, copyThere, vendor], to: harness.environment.store)
        let column = harness.controller.desk.column
        harness.spin { column.timeline.placed(withID: vendor.id) != nil }
        column.timeline.activate(.event(event.id))
        harness.spin { column.details.card?.model?.overlap != nil }
        XCTAssertEqual(column.details.card?.model?.overlap, "Overlaps Vendor call, 16:00 - 16:30")
    }

    // MARK: One edge

    /// Where a view's words (or its glyph, or its face) start, in the card: a label's its cell's inset in from its frame,
    /// a link's its padding in from its face, the Mail row's glyph its padding in.
    private func wordsX(_ view: NSView, in card: NSView) -> CGFloat {
        let frame = card.convert(view.bounds, from: view)
        switch view {
        case is NSTextField:
            return frame.minX + EventDetailsText.wordsInset
        case let button as QuireButton:
            let face = card.convert(button.alignmentRect(forFrame: button.frame), from: button.superview)
            return button.variant == .link ? face.minX + Quire.Layout.Button.linkPadX : face.minX
        case is MailButton:
            return frame.minX + Quire.Layout.CalendarPane.detailsMailPadX
        default:
            return frame.minX
        }
    }

    /// The first inked column of a bitmap, in pixels.
    private func firstInk(_ bitmap: NSBitmapImageRep) -> Int? {
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { return x }
        }
        return nil
    }

    /// `wordsInset` is what a card label's cell really draws with: the same words drawn at x = 0 and through the label
    /// first ink that far apart.
    func testTheLabelsInsetIsTheOneItsCellDrawsWith() throws {
        let field = EventDetailsText.label("Hl", role: .snippet, color: .black)
        field.frame = NSRect(x: 0, y: 0, width: 80, height: QuireFont.Role.snippet.lineHeight + 4)
        let fieldBitmap = try XCTUnwrap(field.bitmapImageRepForCachingDisplay(in: field.bounds))
        field.cacheDisplay(in: field.bounds, to: fieldBitmap)
        let scale = CGFloat(fieldBitmap.pixelsWide) / field.bounds.width

        let plain = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: fieldBitmap.pixelsWide,
                                                   pixelsHigh: fieldBitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                                   bitsPerPixel: 0))
        plain.size = field.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: plain)
        field.attributedStringValue.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        let inField = try XCTUnwrap(firstInk(fieldBitmap)), drawn = try XCTUnwrap(firstInk(plain))
        XCTAssertEqual(CGFloat(inField - drawn) / scale, EventDetailsText.wordsInset, accuracy: 0.5)
    }

    /// Every text in the card starts on one edge, the content's: the kicker, the title, the time, the overlap's glyph, each
    /// row's label, the Mail row's, the notes, Show more, the answers and the actions; a row's values start on the value
    /// column, where its links' words and the Mail row's glyph do.
    func testEveryTextInTheCardStartsOnOneEdge() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        var overlapping = Support.event("busy", title: "Budget review", start: Support.at(15, 30), end: Support.at(16))
        overlapping.response = .accepted
        let conversation = harness.list.conversations[3].id
        let mail = try XCTUnwrap(try harness.environment.store.messages(in: conversation).max { $0.date < $1.date })
        let aside = Support.event("aside", title: mail.subject, start: Support.at(17), end: Support.at(17, 30), sourceMessage: mail.id)
        try Support.write([event, overlapping, aside], to: harness.environment.store)
        let notes = (1...12).map { "Agenda line \($0): the numbers, then the plan." }.joined(separator: "\n")
        let call = EventCall(phones: [EventPhone(number: "+1 555-0134", dial: "+15550134,,601225430#", region: "US", pin: "601225430")],
                             morePhonesURL: "https://tel.meet.example.test/abc")
        let details = CalendarEventDetails(
            organizer: EmailAddress(name: "Elena Rossi", address: "elena@example.test"),
            guests: [EventGuest(name: "Tom Hughes", address: "tom@example.test", response: .accepted),
                     EventGuest(name: "Rachel Kim", address: "rachel@example.test", response: .declined)],
            guestCount: 2, answersKnown: true, notes: EventNotes(text: notes), call: call)
        XCTAssertTrue(try harness.environment.store.saveCalendarEventDetails(details, eventID: event.id, version: nil, readAt: Support.today))
        let column = harness.controller.desk.column
        harness.spin { column.timeline.placed(withID: aside.id) != nil && column.timeline.placed(withID: overlapping.id) != nil }

        let edge = Quire.Layout.CalendarPane.detailsPadX
        let valueColumn = edge + Quire.Layout.Invitation.labelColumn
        func check(_ card: EventDetailsCardView, _ name: String, atLeast: (edge: Int, values: Int)) {
            card.layoutSubtreeIfNeeded()
            let views = descendants(of: card)
            var atEdge: [(String, NSView)] = []
            var atValues: [(String, NSView)] = []
            for view in views {
                switch view {
                case let kicker as KickerView: atEdge.append(("kicker", kicker))
                case let line as GlyphLine: atEdge.append(("glyph line", line))
                case let notes as EventNotesTextView: atEdge.append(("notes", notes))
                case let row as EventDetailsRowView:
                    guard let label = row.subviews.first else { continue }
                    atEdge.append(("\(row.row.label) label", label))
                    // The first piece of each line, which starts on the value column.
                    let pieces = row.subviews.dropFirst().filter { $0 !== row.copyButton }
                    let starts = Dictionary(grouping: pieces) { card.convert($0.bounds, from: $0).midY.rounded() }
                    for (_, line) in starts {
                        if let first = line.min(by: { wordsX($0, in: card) < wordsX($1, in: card) }) {
                            atValues.append(("\(row.row.label) value", first))
                        }
                    }
                case let mailRow as MailRowView:
                    if let label = mailRow.subviews.first { atEdge.append(("Mail label", label)) }
                    if let button = mailRow.button { atValues.append(("Mail glyph", button)) }
                default:
                    break
                }
            }
            for field in views.compactMap({ $0 as? NSTextField }) where field.superview is CardStack {
                atEdge.append(("\(field.stringValue.prefix(12))", field))
            }
            if let more = card.buttons.first(where: { $0.title == "Show more" }) { atEdge.append(("Show more", more)) }
            if let first = card.answerButtons[.accepted] { atEdge.append(("Accept", first)) }
            if let first = card.keyed.first(where: { $0.key.hasPrefix("footer.") })?.view { atEdge.append(("first action", first)) }
            XCTAssertGreaterThanOrEqual(atEdge.count, atLeast.edge, name)
            XCTAssertGreaterThanOrEqual(atValues.count, atLeast.values, name)
            for (what, view) in atEdge {
                XCTAssertEqual(wordsX(view, in: card), edge, accuracy: 0.5, "\(name): \(what) starts on the content's edge")
            }
            for (what, view) in atValues {
                XCTAssertEqual(wordsX(view, in: card), valueColumn, accuracy: 0.5, "\(name): \(what) starts on the value column")
            }
        }

        column.timeline.activate(.event(event.id))
        harness.spin { column.details.card?.model?.notes != nil && column.details.card?.model?.overlap != nil }
        check(try XCTUnwrap(column.details.card), "an invitation", atLeast: (12, 4))

        column.timeline.activate(.event(aside.id))
        harness.spin { column.details.card?.model?.mail?.message != nil }
        check(try XCTUnwrap(column.details.card), "time set aside", atLeast: (5, 1))
    }

    /// Show more under clamped notes is the middle's last part: scrolled to the end, its ring is drawn whole; the top
    /// hairline sits on the middle's edge and its cover hides what scrolled past it.
    func testShowMoresRingFitsTheBottomOfAScrolledMiddle() throws {
        let harness = try self.harness()
        let event = try invitation(harness)
        let notes = (1...30).map { "Line \($0) of the agenda, long enough to wrap once or twice in the card." }.joined(separator: "\n")
        XCTAssertTrue(try harness.environment.store.saveCalendarEventDetails(
            CalendarEventDetails(notes: EventNotes(text: notes)), eventID: event.id, version: nil, readAt: Support.today))
        let column = harness.controller.desk.column
        column.timeline.activate(.event(event.id))
        harness.spin { column.details.card?.model?.notes != nil }
        let card = try XCTUnwrap(column.details.card)
        card.maxHeight = 220
        card.apply(try XCTUnwrap(card.model))
        XCTAssertTrue(card.middleScrolls)
        let more = try XCTUnwrap(card.buttons.first { $0.title == "Show more" })
        let scroll = try XCTUnwrap(more.enclosingScrollView)
        let clip = scroll.contentView
        let document = try XCTUnwrap(scroll.documentView)
        clip.scroll(to: NSPoint(x: 0, y: document.frame.height - clip.bounds.height))
        scroll.reflectScrolledClipView(clip)
        card.layoutSubtreeIfNeeded()

        let face = clip.convert(more.alignmentRect(forFrame: more.frame), from: more.superview)
        let ring = QuireFocusRing.outset(gap: QuireFocusRing.gap, width: QuireFocusRing.width(increasedContrast: true))
        XCTAssertLessThanOrEqual(face.maxY + ring, clip.bounds.maxY, "the ring fits below Show more, at the middle's bottom")
        let covers = descendants(of: card).compactMap { $0 as? EdgeCover }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(covers.map(\.isHidden), [false, true], "cut at the top only")
        let topCover = try XCTUnwrap(covers.first)
        XCTAssertEqual(topCover.frame.minY, scroll.frame.minY, accuracy: 0.5, "the cover hides the clip's room above the edge")
        XCTAssertEqual(topCover.frame.width, scroll.frame.width, accuracy: 0.5)
        let middleTop = scroll.frame.minY + EventDetailsCardView.middleRingRoom
        XCTAssertEqual(topCover.frame.maxY - 1, middleTop, accuracy: 0.5, "its hairline on the middle's edge")

        // At the top again, the first part sits on that edge, and nothing is covered.
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
        let firstTop = descendants(of: document).filter { $0.superview === document }.map { card.convert($0.bounds, from: $0).minY }.min()
        XCTAssertEqual(firstTop ?? 0, middleTop, accuracy: 0.5)
        XCTAssertEqual(covers.map(\.isHidden), [true, false], "cut at the bottom only")
    }
}

/// A pasteboard that refuses every write.
private final class RefusingPasteboard: NSPasteboard {
    override func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool { false }
}
