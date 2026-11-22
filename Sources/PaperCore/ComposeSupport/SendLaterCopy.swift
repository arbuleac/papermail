import Foundation

/// Send Later's words (spec §5.23, §4.13), in one place so the row, the sheet, the toast and the menu say the same thing.
/// Times are written as Later writes its own (`DateFormatting.dueTime`): “09:00” today, “Mon 09:00” this week, the date
/// beyond.
public enum SendLaterCopy {
    /// The command's name (title case): the drop-down's heading, Message › Send Later…, Edit › Undo's “Undo Send Later”.
    public static let command = "Send Later"
    /// The drop-down's last item, which opens the date and time sheet.
    public static let pickTime = "Pick a Time…"
    /// The reader's link that takes the schedule back, leaving the draft.
    public static let cancel = "Cancel"
    /// What keeps it honest: nothing sends while Paper is closed.
    public static let whileOpen = "while Paper is open"

    /// A Drafts row's time slot and the draft sheet's date line: “Sends Mon 09:00”, “Not sent” (its time passed while
    /// Paper was closed), “Sending…”.
    public static func status(_ state: SendLaterState, formatter: DateFormatting, reference: DateFormatting.Reference) -> String {
        switch state {
        case .waiting(let date): return sends(formatter.dueTime(for: date, reference: reference))
        case .missed: return "Not sent"
        case .sending: return "Sending\u{2026}"
        }
    }

    /// What VoiceOver hears for the row's state, which also says the condition the slot has no room for.
    public static func spoken(_ state: SendLaterState, formatter: DateFormatting, reference: DateFormatting.Reference) -> String {
        switch state {
        case .waiting(let date): return sends(formatter.dueTime(for: date, reference: reference)) + ", " + whileOpen
        case .missed(let date): return "Not sent, was due " + formatter.dueTime(for: date, reference: reference)
        case .sending: return "Sending"
        }
    }

    /// “Sends Tue 09:00”: the toast when a message is scheduled, and the row's slot.
    public static func sends(_ time: String) -> String {
        "Sends " + time
    }

    /// The tooltip on a menu item's or a sheet's time: when it sends, and on what condition.
    public static func help(_ time: String) -> String {
        "Sends \(time) \(whileOpen)"
    }
}
