import AppKit
import SSCore

/// A message the composer or the quick reply scheduled with Send Later (spec §5.23): posted as `didSchedule` so the main
/// window shows “Sends Tue 09:00 · Undo”, whose Undo calls `undo` (the schedule cancelled, the message back where it was
/// written).
@MainActor
final class SendLaterScheduled: NSObject {
    static let didSchedule = Notification.Name("SendLaterScheduled")
    static let userInfoKey = "scheduled"

    let sendID: String
    let date: Date
    private let undoAction: @MainActor () -> Bool

    /// `undo` takes the schedule back and says whether it could: a message already on its way (⌘Z reaches the step
    /// long after, §6.1) stays sent.
    init(sendID: String, date: Date, undo: @escaping @MainActor () -> Bool) {
        self.sendID = sendID
        self.date = date
        undoAction = undo
    }

    /// Takes the schedule back; false when the message had gone already.
    @discardableResult
    func undo() -> Bool {
        undoAction()
    }

    /// `source` is the reader whose quick reply scheduled it, so a reader window's step toasts in that window; nil from a
    /// composer.
    func post(from source: AnyObject? = nil) {
        NotificationCenter.default.post(name: Self.didSchedule, object: source, userInfo: [Self.userInfoKey: self])
    }
}

/// Pick a Time… (spec §5.23): the date and time sheet on `window`, calling back with the time chosen or nil. Replaceable,
/// since a sheet's run cannot be answered from a test.
@MainActor
enum SendLaterPicker {
    static var present: (NSWindow?, @escaping @MainActor (Date?) -> Void) -> Void = { window, completion in
        LaterDatePicker(purpose: .sendLater).present(on: window, completion: completion)
    }
}
