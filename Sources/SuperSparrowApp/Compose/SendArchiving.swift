import Foundation
import SSCore

/// Archives the conversation a send answers, for Send and Archive (spec §5.23): the main window, which owns E's rules
/// (the messages in the Inbox, a snooze ended instead, a return mark kept for the undo).
@MainActor
protocol SendArchiving: AnyObject {
    /// Archives the conversation `original` belongs to as E would, right after a send answering it was queued through
    /// `client`; nil when it changes nothing (already out of the Inbox and not snoozed, gone, or not this window's mail).
    func archiveConversation(answering original: MessageID, client: MailClient) -> SendArchive?
}
