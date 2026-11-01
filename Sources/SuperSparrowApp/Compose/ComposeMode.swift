import SSCore

/// What the composer opens with. Reply and forward prefill from the original message, fetched through
/// `MailClient.ensureBody` after the window is already on screen.
enum ComposeMode: Hashable, Sendable {
    case new
    case reply(MessageID, all: Bool)
    case forward(MessageID)

    var originalMessageID: MessageID? {
        switch self {
        case .new: return nil
        case .reply(let id, _): return id
        case .forward(let id): return id
        }
    }

    var isForward: Bool {
        if case .forward = self { return true }
        return false
    }
}
