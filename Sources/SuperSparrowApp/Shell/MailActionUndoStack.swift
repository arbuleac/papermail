import SSCore

/// One mail action as the user saw it ("Archived"), plus the exact operations that undo it.
///
/// The inverse is computed per message from the state before the action, so undoing an archive puts back only
/// the messages that were in the inbox, and undoing "mark read" leaves already-read messages read.
struct MailActionRecord {
    struct Step {
        var change: MetadataChange
        var targets: [MessageID]
    }

    var title: String
    var change: MetadataChange
    var targets: [MessageID]
    var inverse: [Step]
    var conversation: ConversationID?

    /// The messages the action actually changes and the steps that restore them, or nil when it changes nothing.
    static func make(_ change: MetadataChange, on messages: [MessageMetadata], conversation: ConversationID?) -> MailActionRecord? {
        let changed = messages.filter { applying(change, to: $0) != $0 }
        guard !changed.isEmpty else { return nil }
        let ids = changed.map(\.id)
        var inverse: [Step] = []
        let title: String
        switch change {
        case .archive:
            title = "Archived"
            inverse = [Step(change: .moveToInbox, targets: ids)]
        case .moveToInbox:
            title = "Moved to Inbox"
            inverse = [Step(change: .archive, targets: ids)]
        case .trash:
            title = "Moved to Trash"
            inverse = [Step(change: .restoreFromTrash, targets: ids)]
            // restoreFromTrash lands everything in the inbox; messages that were archived go back to the archive.
            let archived = changed.filter { !$0.roles.contains(.inbox) }.map(\.id)
            if !archived.isEmpty { inverse.append(Step(change: .archive, targets: archived)) }
        case .restoreFromTrash:
            title = "Restored"
            inverse = [Step(change: .trash, targets: ids)]
        case .setRead(let read):
            title = read ? "Marked as read" : "Marked as unread"
            inverse = [Step(change: .setRead(!read), targets: ids)]
        case .setStarred(let starred):
            title = starred ? "Starred" : "Unstarred"
            inverse = [Step(change: .setStarred(!starred), targets: ids)]
        }
        return MailActionRecord(title: title, change: change, targets: ids, inverse: inverse, conversation: conversation)
    }
}

/// The last few mail actions, newest last. `z` and ⌘Z pop one and apply its inverse.
struct MailActionUndoStack {
    static let capacity = 20

    private(set) var records: [MailActionRecord] = []

    var isEmpty: Bool { records.isEmpty }
    var last: MailActionRecord? { records.last }

    mutating func push(_ record: MailActionRecord) {
        records.append(record)
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
    }

    mutating func pop() -> MailActionRecord? {
        records.popLast()
    }

    mutating func removeAll() {
        records.removeAll()
    }
}
