import Foundation
import PaperCore
import os

/// Who keeps the draft of a send that fails (spec §5.53, `FailedSend`): the undo-send panel or the quick reply that sent
/// it, while it watches the send, else the main window's `SendLaterOutbox`, which settles every failed send nobody answers
/// for. A send is claimed in the same turn of the main actor that queues it, before the outbox's observation can deliver
/// anything about it, so that observation, which may see a row fail before its owner has read it, never keeps a second
/// draft of a send its owner keeps. The owner lets go once the draft is on disk and the row cleared (`keepFailed`), or when
/// it stops watching (its panel dismissed before the outcome, its reader gone), and the window's settler then looks again
/// (`didRelease`), since nothing in the outbox changed to tell it.
///
/// Counted, not a set: a quick reply's countdown moving to an undo-send panel is claimed by the panel before the bar lets go.
@MainActor
enum SendOwnership {
    private static let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "send")
    private static var claims: [String: Int] = [:]

    /// Posted on the main thread when a send's last owner let go of it; `object` is nil. Observers look on the next turn.
    static let didRelease = Notification.Name("SendOwnership.didRelease")

    static func claim(_ sendID: String) {
        claims[sendID, default: 0] += 1
    }

    static func release(_ sendID: String) {
        guard let count = claims[sendID] else { return }
        if count > 1 {
            claims[sendID] = count - 1
            return
        }
        claims[sendID] = nil
        NotificationCenter.default.post(name: didRelease, object: nil)
    }

    /// A live panel or quick reply answers for `sendID`: the app leaves its failure to it.
    static func isOwned(_ sendID: String) -> Bool {
        claims[sendID] != nil
    }

    /// Keeps a failed send's draft, `draft` (carrying its reason, under `FailedSend.draftID`), off the main thread, and only
    /// once it is on disk clears the send's outbox row, so the message is never lost; then lets go of the send when the
    /// caller owned it (`releasing`). A draft that could not be written leaves the row failed, for the window's settler to
    /// try again from the message once the send is let go. `draftStore` defaults to the shared one.
    static func keepFailed(_ draft: ComposeDraft, sendID: String, store: MailStoring, releasing: Bool,
                           draftStore: ComposeDraftStore? = nil) {
        (draftStore ?? .shared).save(draft) { saved in
            if saved {
                do {
                    try store.deleteSend(id: sendID)
                } catch {
                    log.error("clearing a failed send's row failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                log.error("keeping a failed send as a draft failed")
            }
            if releasing { release(sendID) }
        }
    }
}
