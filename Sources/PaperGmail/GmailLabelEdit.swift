import Foundation
import PaperCore

/// The label edit that makes Gmail converge to `applying(_:to:)` for one `MetadataChange`.
///
/// Gmail has no archive or trash verbs, only labels, so every user action becomes an add/remove pair
/// that `messages.batchModify` applies idempotently.
struct GmailLabelEdit: Equatable, Sendable {
    var add: [String]
    var remove: [String]

    init(_ change: MetadataChange) {
        switch change {
        case .archive:
            add = []
            remove = ["INBOX"]
        case .moveToInbox:
            add = ["INBOX"]
            remove = ["TRASH", "SPAM"]
        case .setRead(let read):
            add = read ? [] : ["UNREAD"]
            remove = read ? ["UNREAD"] : []
        case .setStarred(let starred):
            add = starred ? ["STARRED"] : []
            remove = starred ? [] : ["STARRED"]
        case .trash:
            add = ["TRASH"]
            remove = ["INBOX"]
        case .restoreFromTrash:
            add = ["INBOX"]
            remove = ["TRASH"]
        case .markSpam:
            // Gmail's Report spam: the message leaves the Inbox, and the Trash, which never holds it beside Spam.
            add = ["SPAM"]
            remove = ["INBOX", "TRASH"]
        case .markNotSpam:
            add = ["INBOX"]
            remove = ["SPAM"]
        case .unsubscribe:
            // Not a label change: the engine sends the request itself, and `apply` sends nothing for an empty edit.
            add = []
            remove = []
        case .answerInvitation:
            // Answered by mail and through the Calendar API (`GmailProvider.answer`), never with labels.
            add = []
            remove = []
        }
    }
}
