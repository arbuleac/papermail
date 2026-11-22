import PaperCore

/// The quick-reply text parked under each conversation, shared by every reader of one mailbox: the main window's and
/// each reader window's (spec §5.49). A reader window takes its conversation's text with it when it closes, and its
/// controller goes with the window, so the text has to be kept where the next reader to show that conversation (the
/// window opened again by an undo, or the main window's) finds it.
@MainActor
final class QuickReplyDraftShelf {
    var drafts = QuickReplyDrafts()
}
