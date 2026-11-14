import AppKit
import SSCore
import SSDesign

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
            alert.informativeText = "It sends at this time while SuperSparrow is open. Until then it waits in Drafts."
            confirm = "Schedule"
        }
        alert.alertStyle = .informational
        let snooze = alert.addButton(withTitle: confirm)
        snooze.keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel")

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
