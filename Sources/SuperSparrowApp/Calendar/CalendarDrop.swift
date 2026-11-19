import AppKit
import SSCore

/// A list row dragged onto the calendar (spec §5.54, “Setting time aside”): the list's own pasteboard type, one
/// conversation at a time, from this copy of the app only (as the rail's folders take drops, §5.2).
@MainActor
enum CalendarDrop {
    /// The one conversation a drag carries, or nil: a drag of several rows drops nothing, and a drag from another app
    /// or another copy of this one (no dragging source here) could name another store's conversation.
    static func conversation(in info: NSDraggingInfo) -> ConversationID? {
        guard info.draggingSource != nil else { return nil }
        let ids = MessageListViewController.conversationIDs(on: info.draggingPasteboard)
        return ids.count == 1 ? ids[0] : nil
    }

    /// Time set aside copies nothing out of the list: the row stays where it is. ⌘ empties the mask and refuses it.
    static func operation(for info: NSDraggingInfo) -> NSDragOperation {
        let allowed = info.draggingSourceOperationMask
        return [NSDragOperation.copy, .move].first { allowed.contains($0) } ?? []
    }
}
