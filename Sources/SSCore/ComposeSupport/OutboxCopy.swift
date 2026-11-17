import Foundation

/// The Outbox's words (spec §5.53, §4.13), in one place so the row, its sheet and VoiceOver say the same thing. A Send
/// Later message waiting or missed reads as its Drafts row does (`SendLaterCopy`), and a send going now as a quick reply's
/// sheet does: “Sending…”, with the real ellipsis.
public enum OutboxCopy {
    /// The view's name: the masthead, View › Outbox and the HUD's row.
    public static let title = "Outbox"
    /// A send put back to go again (a throttle, no connection yet): the runner tries again within a minute, or as soon
    /// as the network is back, as the sync line's “Retrying shortly” says of a lane.
    public static let retrying = "Retrying shortly"
    /// A failed send's time slot, set in `danger`: the words its composer's banner starts with, as a row says a failed
    /// operation (“Couldn't archive”).
    public static let failed = "Couldn't send"

    /// The row's time slot: “Sends Mon 09:00”, “Not sent”, “Sending…”, “Retrying shortly”, “Couldn't send”.
    public static func status(_ state: OutboxState, formatter: DateFormatting, reference: DateFormatting.Reference) -> String {
        switch state {
        case .sending: return SendLaterCopy.status(.sending, formatter: formatter, reference: reference)
        case .waiting(let date): return SendLaterCopy.status(.waiting(until: date), formatter: formatter, reference: reference)
        case .missed(let date): return SendLaterCopy.status(.missed(date), formatter: formatter, reference: reference)
        case .retrying: return retrying
        case .failed: return failed
        }
    }

    /// The sheet's date line, where there is room for the reason: “Couldn't send: Gmail didn't accept the message.”, as
    /// the banner of the draft a failed send leaves says it (`SendFailureWording`). Every other state reads as its row.
    public static func sheetStatus(_ state: OutboxState, provider: ProviderKind?, formatter: DateFormatting,
                                   reference: DateFormatting.Reference) -> String {
        if case .failed(let lastError) = state, let provider {
            return failed + ": " + SendFailureWording.reason(lastError: lastError, provider: provider)
        }
        return status(state, formatter: formatter, reference: reference)
    }

    /// What VoiceOver hears for the row's state, which also says what the slot has no room for.
    public static func spoken(_ state: OutboxState, formatter: DateFormatting, reference: DateFormatting.Reference) -> String {
        switch state {
        case .sending: return SendLaterCopy.spoken(.sending, formatter: formatter, reference: reference)
        case .waiting(let date): return SendLaterCopy.spoken(.waiting(until: date), formatter: formatter, reference: reference)
        case .missed(let date): return SendLaterCopy.spoken(.missed(date), formatter: formatter, reference: reference)
        case .retrying: return "Not sent yet, " + retrying.lowercased()
        case .failed: return failed
        }
    }

    /// The time's tooltip: a waiting message's condition, as in Drafts; nil for every other state.
    public static func help(_ state: OutboxState, formatter: DateFormatting, reference: DateFormatting.Reference) -> String? {
        guard case .waiting(let date) = state else { return nil }
        return SendLaterCopy.help(formatter.dueTime(for: date, reference: reference))
    }
}
