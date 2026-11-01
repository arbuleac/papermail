import Foundation

/// One mail action as the user saw it ("Archived"), plus the exact operations that undo it.
///
/// The inverse is computed per message from the state before the action, so undoing an archive puts back only
/// the messages that were in the inbox, and undoing "mark read" leaves already-read messages read.
public struct MailActionRecord: Sendable {
    public struct Step: Equatable, Sendable {
        public var change: MetadataChange
        public var targets: [MessageID]

        public init(change: MetadataChange, targets: [MessageID]) {
            self.change = change
            self.targets = targets
        }
    }

    public var title: String
    public var change: MetadataChange
    public var targets: [MessageID]
    public var inverse: [Step]
    public var conversation: ConversationID?

    /// The messages of a conversation that a conversation-level action should touch.
    ///
    /// - Marking unread touches only the latest message, the way Gmail and Outlook do it.
    /// - Moving to the inbox from the trash brings back only what was trashed, not the archived rest.
    /// - On Microsoft accounts, trash and move-to-inbox leave the user's own sent messages and drafts in Sent
    ///   Items and Drafts. Graph keeps one folder per message and there is no change that moves a message back
    ///   to Sent Items, so once such a message left its folder an undo could only drop it in Inbox or Archive.
    ///   A conversation made only of the user's own messages is still acted on as a whole.
    public static func targets(for change: MetadataChange, in messages: [MessageMetadata], kind: ProviderKind) -> [MessageMetadata] {
        switch change {
        case .setRead(false):
            return messages.last.map { [$0] } ?? []
        case .trash, .moveToInbox, .restoreFromTrash:
            var candidates = messages
            if change != .trash {
                let trashed = messages.filter { $0.roles.contains(.trash) }
                if !trashed.isEmpty { candidates = trashed }
            }
            guard kind == .microsoft else { return candidates }
            let others = candidates.filter { !isOwnFolderCopy($0) }
            return others.isEmpty ? candidates : others
        default:
            return messages
        }
    }

    /// The messages the action actually changes and the steps that restore them, or nil when it changes nothing.
    public static func make(_ change: MetadataChange, on messages: [MessageMetadata], conversation: ConversationID?) -> MailActionRecord? {
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
            // Whatever came out of the trash goes back there; the rest goes back to the archive.
            let trashed = changed.filter { $0.roles.contains(.trash) }.map(\.id)
            let archived = changed.filter { !$0.roles.contains(.trash) }.map(\.id)
            if !trashed.isEmpty { inverse.append(Step(change: .trash, targets: trashed)) }
            if !archived.isEmpty { inverse.append(Step(change: .archive, targets: archived)) }
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

    private static func isOwnFolderCopy(_ message: MessageMetadata) -> Bool {
        !message.roles.contains(.inbox) && (message.roles.contains(.sent) || message.roles.contains(.drafts))
    }
}
