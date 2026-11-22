import AppKit
import PaperCore
import PaperDesign

/// Later's Pick a Date… (spec §5.45) and Send Later's Pick a Time… (§5.23): a system alert sheet on the window the action
/// started in, as every Quire sheet is (§5.33), whose accessory holds the system's graphical calendar and, below it, a
/// time field. It opens on tomorrow at 09:00; its default button (Snooze, or Schedule; ↩) is disabled while the chosen
/// time is not in the future, and Cancel (Esc) closes it.
@MainActor
final class LaterDatePicker: NSObject {
    /// What the sheet is for, which sets its words.
    enum Purpose {
        /// Later: `count` conversations come back at the time.
        case snooze(count: Int)
        /// Send Later: the message sends at the time.
        case sendLater
    }

    let alert: NSAlert
    let calendarPicker = NSDatePicker()
    let timePicker = NSDatePicker()
    private let calendar: Calendar
    private let now: () -> Date

    /// `count` is how many conversations it snoozes, for its words.
    convenience init(count: Int, now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.init(purpose: .snooze(count: count), now: now, calendar: calendar)
    }

    init(purpose: Purpose, now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
        self.now = now
        alert = NSAlert()
        super.init()
        let start = now()
        let initial = LaterPreset.tomorrowMorning(after: start, calendar: calendar) ?? start.addingTimeInterval(86_400)
        let confirm: String
        switch purpose {
        case .snooze(let count):
            alert.messageText = count > 1 ? "When should these \(count) come back?" : "When should this come back?"
            alert.informativeText = count > 1 ? "They return to the Inbox at this time, marked unread."
                : "It returns to the Inbox at this time, marked unread."
            confirm = "Snooze"
        case .sendLater:
            alert.messageText = "When should this send?"
            alert.informativeText = "It sends at this time while Paper is open. Until then it waits in Drafts."
            confirm = "Schedule"
        }
        alert.alertStyle = .informational
        let snooze = alert.addButton(withTitle: confirm)
        snooze.keyEquivalent = "\r"
        let cancel = alert.addButton(withTitle: "Cancel")
        // The hand over both buttons, from overlays since the buttons are AppKit's; Snooze's follows it as it is
        // enabled and disabled (§4.17).
        for button in [snooze, cancel] { QuirePointerOverlay.install(on: button) }

        for picker in [calendarPicker, timePicker] {
            picker.calendar = calendar
            picker.timeZone = calendar.timeZone
            picker.dateValue = initial
            picker.target = self
            picker.action = #selector(pickerChanged(_:))
        }
        calendarPicker.datePickerStyle = .clockAndCalendar
        calendarPicker.datePickerElements = .yearMonthDay
        calendarPicker.datePickerMode = .single
        // Days before today are greyed out; a time earlier today is caught by Snooze's own check.
        calendarPicker.minDate = calendar.startOfDay(for: start)
        calendarPicker.setAccessibilityLabel("Date")
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.setAccessibilityLabel("Time")
        calendarPicker.sizeToFit()
        timePicker.sizeToFit()

        // The calendar, then the time field centred under it, `s5` apart.
        let gap = Quire.Space.s5
        let width = max(calendarPicker.frame.width, timePicker.frame.width)
        let height = calendarPicker.frame.height + gap + timePicker.frame.height
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        calendarPicker.setFrameOrigin(NSPoint(x: ((width - calendarPicker.frame.width) / 2).rounded(), y: timePicker.frame.height + gap))
        timePicker.setFrameOrigin(NSPoint(x: ((width - timePicker.frame.width) / 2).rounded(), y: 0))
        accessory.addSubview(calendarPicker)
        accessory.addSubview(timePicker)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = calendarPicker
        // AppKit makes and draws both pickers, so the pointer comes from views laid over them (§4.17). A click on the
        // calendar picks a day or turns the month, and AppKit tells nothing of where its parts lie (its accessibility
        // gives the date area and three buttons with no frames, and its cell's hit test calls the whole calendar
        // trackable, caption and weekday letters included), so the hand covers the whole calendar as it would any
        // control's hit rect. The time field's digits are typed over, so they take the I-beam, and its stepper the hand.
        QuirePointerOverlay.install(on: calendarPicker)
        TimeFieldPointerArea.install(on: timePicker)
        updateSnoozeButton()
    }

    /// The day from the calendar at the time from the field.
    var chosenDate: Date? {
        LaterPreset.combine(day: calendarPicker.dateValue, time: timePicker.dateValue, calendar: calendar)
    }

    /// Snooze is offered only for a time still ahead.
    var canSnooze: Bool {
        guard let chosenDate else { return false }
        return chosenDate > now()
    }

    var snoozeButton: NSButton { alert.buttons[0] }

    @objc private func pickerChanged(_ sender: Any?) {
        updateSnoozeButton()
    }

    func updateSnoozeButton() {
        snoozeButton.isEnabled = canSnooze
    }

    /// Shows the sheet on `window` and calls back with the time chosen, or nil for Cancel. A time that has passed
    /// while the sheet was open snoozes nothing.
    func present(on window: NSWindow?, completion: @escaping @MainActor (Date?) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .alertFirstButtonReturn, canSnooze, let date = chosenDate else {
                if response == .alertFirstButtonReturn { NSSound.beep() }
                completion(nil)
                return
            }
            completion(date)
        }
        alert.layout()
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(alert.runModal())
        }
    }
}

/// The pointer over the time field (§4.17): the hand over its stepper, whose arrows a click steps, and the I-beam over the
/// time's digits, which a click chooses and typing replaces, as over any field's face; the arrow over both while the
/// picker is disabled. AppKit draws the stepper inside the picker and tells nothing of where, so its width is what it
/// adds to a picker of the same elements laid out without it, at the trailing edge.
@MainActor
private final class TimeFieldPointerArea: NSView, QuirePointerTarget {
    private weak var picker: NSDatePicker?
    private var enabledObservation: NSKeyValueObservation?
    private let stepperWidth: CGFloat

    @discardableResult
    static func install(on picker: NSDatePicker) -> TimeFieldPointerArea {
        let area = TimeFieldPointerArea(picker: picker)
        picker.addSubview(area)
        return area
    }

    private init(picker: NSDatePicker) {
        self.picker = picker
        let plain = NSDatePicker()
        plain.datePickerStyle = .textField
        plain.datePickerElements = picker.datePickerElements
        plain.font = picker.font
        plain.calendar = picker.calendar
        plain.locale = picker.locale
        plain.timeZone = picker.timeZone
        plain.dateValue = picker.dateValue
        plain.sizeToFit()
        stepperWidth = max(0, picker.fittingSize.width - plain.fittingSize.width)
        super.init(frame: picker.bounds)
        autoresizingMask = [.width, .height]
        enabledObservation = picker.observe(\.isEnabled) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pointerRegionsDidChange() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    var pointerRegions: [QuirePointerRegion] {
        guard let picker else { return [] }
        let width = min(stepperWidth, bounds.width)
        let stepper = NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
        let digits = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width - width, height: bounds.height)
        let field = QuirePointerRegion(digits, cursor: picker.isEnabled ? .iBeam : .arrow)
        return stepper.isEmpty ? [field] : [.control(stepper, acts: picker.isEnabled), field]
    }

    override func resetCursorRects() {
        addPointerRects()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }
}
