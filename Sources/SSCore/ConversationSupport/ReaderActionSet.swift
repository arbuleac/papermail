import Foundation

/// The reader header's actions for a reader state (spec §5.12): which buttons show, in which group, which are
/// disabled, and whether Star is on. Pure, so every row of the spec's table is tested without AppKit.
///
/// Groups are drawn from the trailing edge with a gap between them; hidden actions close up and never leave gaps.
public struct ReaderActionSet: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case star
        case archive
        case moveToInbox
        case trash
        case reply
        case replyAll
        case forward
        case continueEditing
        case discardDraft
    }

    /// What the reader shows. `view` is the mailbox the selection came from.
    public enum Context: Equatable, Sendable {
        case nothing
        /// One conversation. `inTrash` is true in the Trash view or when the whole conversation is trashed;
        /// `emptied` when its last message left while it was open; `replyAllAvailable` false with one other
        /// participant.
        case one(view: MailboxView, inTrash: Bool, emptied: Bool, starred: Bool, replyAllAvailable: Bool)
        /// Two or more conversations; `allStarred` only when every one is starred.
        case several(count: Int, view: MailboxView, allStarred: Bool)
    }

    /// The first group (Star · Archive · Trash, or the draft actions).
    public var primary: [Action]
    /// The reply group, after the gap.
    public var replies: [Action]
    public var disabled: Set<Action>
    /// Star draws `star.fill` in `star`: the conversation is starred, or every selected one is.
    public var starOn: Bool

    public init(primary: [Action], replies: [Action], disabled: Set<Action> = [], starOn: Bool = false) {
        self.primary = primary
        self.replies = replies
        self.disabled = disabled
        self.starOn = starOn
    }

    public var all: [Action] { primary + replies }

    public func isEnabled(_ action: Action) -> Bool {
        all.contains(action) && !disabled.contains(action)
    }

    private static let replyGroup: [Action] = [.reply, .replyAll, .forward]

    public static func make(_ context: Context) -> ReaderActionSet {
        switch context {
        case .nothing:
            let set = ReaderActionSet(primary: [.star, .archive, .trash], replies: replyGroup)
            return ReaderActionSet(primary: set.primary, replies: set.replies, disabled: Set(set.all))
        case let .one(view, inTrash, emptied, starred, replyAllAvailable):
            if view == .drafts {
                let set = ReaderActionSet(primary: [.continueEditing, .discardDraft], replies: [])
                return emptied ? ReaderActionSet(primary: set.primary, replies: [], disabled: Set(set.all)) : set
            }
            var set: ReaderActionSet
            if inTrash || view == .trash {
                // The conversation is already in the Trash and v1 has no Delete Forever (§9): Trash goes.
                set = ReaderActionSet(primary: [.star, .moveToInbox], replies: replyGroup, starOn: starred)
            } else {
                set = ReaderActionSet(primary: [.star, .archive, .trash], replies: replyGroup, starOn: starred)
            }
            if !replyAllAvailable { set.disabled.insert(.replyAll) }
            if emptied {
                set.disabled = Set(set.all.filter { $0 != .trash })
            }
            return set
        case let .several(_, view, allStarred):
            switch view {
            case .drafts:
                return ReaderActionSet(primary: [.discardDraft], replies: [])
            case .trash:
                return ReaderActionSet(primary: [.star, .moveToInbox], replies: [], starOn: allStarred)
            default:
                return ReaderActionSet(primary: [.star, .archive, .trash], replies: [], starOn: allStarred)
            }
        }
    }
}
