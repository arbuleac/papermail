import Foundation

/// One warm-up of reader mode's text versions off the main thread (`ConversationViewController.warmReaderTexts`): the
/// reader cancels it when the selection names other neighbours, and it stops before its next conversation.
final class ReaderTextWarmUp: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
