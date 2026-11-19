import AppKit
import SSCore

/// What VoiceOver reads for the calendar (spec §5.54, “VoiceOver”).
@MainActor
enum CalendarAccessibility {
    /// An event: its title, its times with “to”, its account and its place, then what applies: “Roadmap review, 13:00
    /// to 14:00, Northwind, Bay 4, not answered, overlaps Hiring sync”.
    static func label(for event: CalendarEvent, content: CalendarContent, state: CalendarState) -> String {
        var parts = [event.title.isEmpty ? CalendarText.noTitle : event.title]
        parts.append(event.isAllDay ? "All day" : state.text.spokenRange(event.start, event.end))
        let account = state.accountName(event.accountID)
        if !account.isEmpty { parts.append(account) }
        if let location = event.location, !location.isEmpty { parts.append(location) }
        if CalendarFit.isPencil(event) || event.response == .needsAction { parts.append("not answered") }
        if event.response == .tentative { parts.append("tentative") }
        if event.isSetAside { parts.append("set aside for a mail") }
        switch event.sync {
        case .creating:
            parts.append("waiting to reach " + CalendarText.providerCalendarName(state.providerKind(event.accountID)))
        case .failed:
            parts.append("couldn't be added")
        case .synced, .deleting:
            break
        }
        if content.selectedEventIDs.contains(event.id) { parts.append("from the selected mail") }
        if let titles = content.overlapTitles[event.id], !titles.isEmpty {
            parts.append("overlaps " + titles.joined(separator: ", "))
        }
        if event.joinURL != nil { parts.append("has a call") }
        return parts.joined(separator: ", ")
    }

    /// A mark: “Comes back from Later at 17:00: Lease renewal”, “Sends at 16:00 while SuperSparrow is open:
    /// Follow-up”, “From this mail, Friday 20 November at 15:00. Block 30 minutes, B”.
    static func label(for mark: CalendarMark, text: CalendarText) -> String {
        let title = mark.title.isEmpty ? "No subject" : mark.title
        switch mark.kind {
        case .later: return "Comes back from Later at " + text.time(mark.start) + ": " + title
        case .sendLater: return "Sends at " + text.time(mark.start) + " while SuperSparrow is open: " + title
        case .mailTime:
            return "From this mail, " + text.longDay(mark.start) + " at " + text.time(mark.start) + ". Block 30 minutes, B"
        }
    }
}

/// One event in a timeline's accessibility list: its frame follows the face, and a press opens its details (or
/// selects the conversation of the mail's pencil), as ↩ does.
@MainActor
final class CalendarEventAccessibilityElement: NSAccessibilityElement {
    weak var timeline: CalendarTimelineView?
    let eventID: String

    init(timeline: CalendarTimelineView, eventID: String, label: String) {
        self.timeline = timeline
        self.eventID = eventID
        super.init()
        setAccessibilityParent(timeline)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    override func accessibilityFrame() -> NSRect {
        guard let timeline, let placed = timeline.placed(withID: eventID), let window = timeline.window else { return .zero }
        return window.convertToScreen(timeline.convert(placed.face, to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let timeline else { return false }
        timeline.activate(.event(eventID), fromKeyboard: true)
        return true
    }

    override func isAccessibilityFocused() -> Bool {
        timeline?.focusedEventID == eventID
    }
}

/// A mark for VoiceOver, a button: a press opens a Later or Send Later mark's details, and sets 30 minutes aside at the
/// mail's time, as B does.
@MainActor
final class CalendarMarkAccessibilityElement: NSAccessibilityElement {
    weak var timeline: CalendarTimelineView?
    let markID: String

    init(timeline: CalendarTimelineView, markID: String, label: String) {
        self.timeline = timeline
        self.markID = markID
        super.init()
        setAccessibilityParent(timeline)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    override func accessibilityFrame() -> NSRect {
        guard let timeline, let mark = timeline.placedMark(withID: markID), let window = timeline.window else { return .zero }
        return window.convertToScreen(timeline.convert(mark.chip, to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard let timeline else { return false }
        timeline.activate(.mark(markID), fromKeyboard: true)
        return true
    }
}

/// A day of the week for VoiceOver: a column named by its day.
@MainActor
final class CalendarWeekColumnAccessibilityElement: NSAccessibilityElement {
    weak var timeline: CalendarTimelineView?
    let dayIndex: Int

    init(timeline: CalendarTimelineView, dayIndex: Int, label: String) {
        self.timeline = timeline
        self.dayIndex = dayIndex
        super.init()
        setAccessibilityParent(timeline)
        setAccessibilityRole(.column)
        setAccessibilityLabel(label)
    }

    override func accessibilityFrame() -> NSRect {
        guard let timeline, let window = timeline.window else { return .zero }
        let rect = NSRect(x: timeline.dayX(dayIndex), y: 0, width: timeline.dayWidth(dayIndex), height: timeline.bounds.height)
        return window.convertToScreen(timeline.convert(rect, to: nil))
    }
}

/// A day's heading in the week for VoiceOver: a button that shows that day in the column.
@MainActor
final class CalendarWeekHeadingAccessibilityElement: NSAccessibilityElement {
    weak var headings: WeekHeadingsView?
    let index: Int

    init(headings: WeekHeadingsView, index: Int, label: String) {
        self.headings = headings
        self.index = index
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityHelp("Shows this day in the day column")
    }

    override func accessibilityFrame() -> NSRect {
        guard let headings, let window = headings.window else { return .zero }
        return window.convertToScreen(headings.convert(headings.rect(index), to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        headings?.open(index)
        return true
    }
}
