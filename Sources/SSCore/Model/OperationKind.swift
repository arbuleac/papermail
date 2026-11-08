import Foundation

/// What a queued operation did, without its payload, so a failure can be named (“Couldn't archive”) from the
/// conversation row alone. The raw values are stored in `conversations.failed_op_kind`; never rename them.
///
/// Read and star are split by direction because the copy differs (“Couldn't mark as unread”, “Couldn't unstar”).
public enum OperationKind: String, Codable, Sendable, CaseIterable {
    case archive
    case moveToInbox
    case markRead
    case markUnread
    case star
    case unstar
    case trash
    case restoreFromTrash
    /// Never stored as a mark: an unsubscribe request that cannot go is dropped quietly, never written as failed.
    case unsubscribe

    public init(_ change: MetadataChange) {
        switch change {
        case .archive: self = .archive
        case .moveToInbox: self = .moveToInbox
        case .setRead(let read): self = read ? .markRead : .markUnread
        case .setStarred(let starred): self = starred ? .star : .unstar
        case .trash: self = .trash
        case .restoreFromTrash: self = .restoreFromTrash
        case .unsubscribe: self = .unsubscribe
        }
    }
}

extension MetadataChange {
    public var kind: OperationKind { OperationKind(self) }
}
