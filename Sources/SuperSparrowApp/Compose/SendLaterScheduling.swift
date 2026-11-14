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
    private let undoAction: @MainActor () -> Void

    init(sendID: String, date: Date, undo: @escaping @MainActor () -> Void) {
        self.sendID = sendID
        self.date = date
        undoAction = undo
    }

    func undo() {
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
