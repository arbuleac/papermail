import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// Opening an event's details (docs/ARCHITECTURE.md, "Performance budgets"; spec §18): the model built and the card
/// built, laid out and drawn whole. The click's first frame has the row alone (from memory: no store read before it);
/// the details then land and the card is built again, here for a busy event: 200 guests (the 100 kept, grouped by
/// answer), notes at the stored cap of 4,000 units with 40 links, the call, the related mail and the overlap; folded, and
/// with Show all and Show more opened, where every guest and every line is laid. Gated:
///
///     PAPER_PERF=1 swift test --filter EventDetailsPerformanceTests
@MainActor
final class EventDetailsPerformanceTests: XCTestCase {
    private typealias Support = CalendarTestSupport
    private let runs = 31

    func testOpeningTheCardOnABusyEventStaysWithinBudget() throws {
        guard ProcessInfo.processInfo.environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("set PAPER_PERF=1 to run the event details benchmark")
        }
        let inputs = busyEvent()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 900))
        window.contentView = host
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))

        var fromMemory = inputs
        fromMemory.details = nil
        fromMemory.related = nil
        var opened = inputs
        opened.guestsExpanded = true
        opened.notesExpanded = true
        let variants: [(label: String, inputs: EventDetailsModel.Inputs, median: Double, p95: Double)] = [
            ("the click's first frame, the row alone", fromMemory, 16, 16),
            ("a busy event's details landed, folded", inputs, 25, 33),
            ("a busy event, Show all and Show more opened", opened, 25, 33),
        ]
        for (label, variant, medianBudget, p95Budget) in variants {
            let expanded = variant.notesExpanded
            var models: [Double] = [], cards: [Double] = [], wholes: [Double] = []
            for _ in 0..<runs {
                let start = DispatchTime.now()
                let model = EventDetailsModel(variant)
                let built = DispatchTime.now()
                let card = EventDetailsCardView()
                card.notesExpanded = expanded
                card.maxHeight = Quire.Layout.CalendarPane.detailsMaxHeight
                card.apply(model)
                card.setFrameOrigin(NSPoint(x: 24, y: 24))
                host.addSubview(card)
                host.layoutSubtreeIfNeeded()
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let end = DispatchTime.now()
                models.append(milliseconds(start, built))
                cards.append(milliseconds(built, end))
                wholes.append(milliseconds(start, end))
                card.removeFromSuperview()
            }
            print("PAPER_PERF event details, \(label): the model median \(format(percentile(models, 0.5))) ms; the card built, laid "
                  + "out and drawn median \(format(percentile(cards, 0.5))) ms; the whole open median \(format(percentile(wholes, 0.5))) ms, "
                  + "p95 \(format(percentile(wholes, 0.95))) ms")
            // Debug, M4 Pro, 26 November 2026 (see docs/ARCHITECTURE.md, "Performance budgets").
            XCTAssertLessThan(percentile(wholes, 0.5), medianBudget, "event details budget: \(label)")
            XCTAssertLessThan(percentile(wholes, 0.95), p95Budget, "event details budget at p95: \(label)")
        }
    }

    // MARK: Fixtures

    private func busyEvent() -> EventDetailsModel.Inputs {
        var event = Support.event("busy", title: "All hands: the plan for next year", start: Support.at(15), end: Support.at(16, 30),
                                  response: .needsAction, joinURL: "https://teams.microsoft.com/l/meetup-join/all-hands",
                                  location: "Main hall, Level 1", invitationUID: "uid-all-hands", webURL: "https://outlook.office.test/item")
        event.seriesID = "all-hands"
        event.timeZone = "America/Los_Angeles"
        event.callService = .teams
        event.organizer = "Rachel Kim"
        let answers: [InvitationResponse?] = [.accepted, .accepted, .tentative, .declined, .needsAction, nil]
        let guests = (0..<200).map { index in
            EventGuest(name: "Guest Number \(index) Lastname", address: "guest\(index)@example.test", response: answers[index % answers.count],
                       isSelf: index == 0)
        }
        var text = ""
        var links: [EventNotes.Link] = []
        var line = 0
        while text.utf16.count < EventNotes.maxLength - 120 {
            if line.isMultiple(of: 3), links.count < 40 {
                let url = "https://docs.example.test/agenda/\(line)"
                links.append(EventNotes.Link(location: text.utf16.count, length: url.utf16.count, url: url))
                text += url + "\n"
            } else {
                text += "Line \(line) of the agenda: what we did, what we learned, and what we will do next quarter.\n"
            }
            line += 1
        }
        let details = CalendarEventDetails(
            organizer: EmailAddress(name: "Rachel Kim", address: "rachel@example.test"),
            guests: Array(guests.prefix(CalendarEventDetails.maxGuests)), guestCount: guests.count, answersKnown: true,
            notes: EventNotes(text: text, links: links),
            call: EventCall(meetingID: "284 113 905 771", passcode: "Qx7bTe",
                            phones: [EventPhone(number: "+1 555-0134", dial: "+15550134,,601225430#", region: "US", pin: "601225430")],
                            pinLabel: .conferenceID, morePhonesURL: "https://dialin.example.test/more"),
            repeats: "Every week on Thursday, 12 times")
        let message = MessageMetadata(id: MessageID(accountID: Support.accountA.id, providerID: "m1"),
                                      conversationID: ConversationID(accountID: Support.accountA.id, providerID: "c1"),
                                      subject: "Invitation: All hands", snippet: "", from: EmailAddress(name: "Rachel Kim", address: "rachel@example.test"),
                                      to: [], date: Support.at(9, on: Support.day(12)), roles: [.inbox], isRead: true, isStarred: false,
                                      hasAttachments: false)
        let invitation = CalendarInvitation(method: .request, uid: "uid-all-hands", title: "All hands", start: Support.at(15),
                                            end: Support.at(16, 30), organizer: .init(name: "Rachel Kim", address: "rachel@example.test"))
        return EventDetailsModel.Inputs(
            event: event, details: details, related: RelatedInvitation(message: message, invitation: invitation),
            accountName: "Demo Outlook", dot: .qInk2, kind: .microsoft, overlap: "Overlaps Roadmap sync with Elena, 15:30 - 16:00",
            text: CalendarText(calendar: Support.calendar), now: Support.at(11, 40))
    }

    // MARK: Timing

    private func milliseconds(_ start: DispatchTime, _ end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
