import Foundation

/// The words feedback uses for mail actions (spec §4.13, §5.30): the toast's past tense, its coalesced form,
/// the command's menu name that an undo confirms itself with, and the failure line of an operation the
/// provider gave up on.
public enum MailActionCopy {
    /// “Archived”, or coalesced “Archived 3 conversations” / “Marked 3 as unread”.
    public static func toast(for change: MetadataChange, count: Int = 1) -> String {
        let n = count.formatted(.number.grouping(.automatic))
        switch change {
        case .archive: return count > 1 ? "Archived \(n) conversations" : "Archived"
        case .trash: return count > 1 ? "Moved \(n) conversations to Trash" : "Moved to Trash"
        case .moveToInbox, .restoreFromTrash: return count > 1 ? "Moved \(n) conversations to Inbox" : "Moved to Inbox"
        case .setRead(true): return count > 1 ? "Marked \(n) as read" : "Marked as read"
        case .setRead(false): return count > 1 ? "Marked \(n) as unread" : "Marked as unread"
        case .setStarred(true): return count > 1 ? "Starred \(n) conversations" : "Starred"
        case .setStarred(false): return count > 1 ? "Unstarred \(n) conversations" : "Unstarred"
        case .unsubscribe: return "Unsubscribe sent"
        // The invitation card shows the answer itself; no toast names it.
        case .answerInvitation: return "Answered"
        }
    }

    /// The toast an unsubscribe leaves (spec §5.30): what became of the request, then the archive, which is what the
    /// toast's Undo takes back (the request cannot be). “Unsubscribe sent · Archived” for a one-click or mailto
    /// request, “Opened in browser · Archived” for a page opened in the browser; without the archive (the
    /// conversation was already out of the Inbox) the first half alone, with nothing to undo.
    public static func unsubscribeToast(for method: UnsubscribeMethod, archived: Bool) -> String {
        let request = method.isRequest ? "Unsubscribe sent" : "Opened in browser"
        return archived ? request + " \u{00B7} " + toast(for: .archive) : request
    }

    /// What an unsubscribe's Undo confirms itself with (spec §5.30): the archive it took back and, for a request, that
    /// the request was not, which the undoable toast before it has no room to say. “Undid Archive · Unsubscribe stays
    /// sent”; “Undid Archive” after a page, which sent nothing.
    public static func unsubscribeUndoConfirmation(for method: UnsubscribeMethod) -> String {
        let undone = undoConfirmation(for: .archive)
        return method.isRequest ? undone + " \u{00B7} Unsubscribe stays sent" : undone
    }

    /// The command as the menus name it, which Edit › Undo and the confirmation toast repeat.
    public static func commandName(for change: MetadataChange) -> String {
        switch change {
        case .archive: return "Archive"
        case .trash: return "Move to Trash"
        case .moveToInbox, .restoreFromTrash: return "Move to Inbox"
        case .setRead(true): return "Mark as Read"
        case .setRead(false): return "Mark as Unread"
        case .setStarred(true): return "Star"
        case .setStarred(false): return "Unstar"
        case .unsubscribe: return "Unsubscribe"
        case .answerInvitation: return "Answer Invitation"
        }
    }

    /// Later's command as Edit › Undo and the undo confirmation name it: the menu item is “Later…”, the act is a snooze
    /// (“Snoozed until Tue 09:00”, the sheet's “Snooze” button), so the undo is “Undo Snooze” and “Undid Snooze”.
    public static let snoozeCommand = "Snooze"

    /// “Snoozed until Tue 09:00”, however many were snoozed (§5.45). The time is what the toast tells, and beside Undo
    /// and Z in the default list a count does not leave room for it: “Snoozed 3 until May 26 9:00 AM” already cuts
    /// the time off. `time` is written by `DateFormatting.dueTime(for:reference:)`.
    public static func snoozed(until time: String) -> String {
        "Snoozed until \(time)"
    }

    /// The snooze toast's words: `snoozed(until:)`, or “Until 20 May 2027 09:00” where `fits` says that would be cut
    /// off beside Undo and Z (a date with a 12-hour time in a list of the default width, one eleven months ahead or more,
    /// a narrowed list). The time is what the toast tells, so it is never what truncates.
    public static func snoozed(until time: String, fits: (String) -> Bool) -> String {
        let sentence = snoozed(until: time)
        return fits(sentence) ? sentence : "Until \(time)"
    }

    /// M's command as Message › Mute and Edit › Undo name it: “Mute”, or “Unmute” for a selection that is all muted.
    public static func muteCommand(muting: Bool) -> String {
        muting ? "Mute" : "Unmute"
    }

    /// “Muted”, or “Muted 3 conversations”; “Unmuted” likewise (spec, Mute (Q3.7)). Said when a row leaves the list
    /// (muting archives what is in the Inbox) or several change at once; otherwise the row's glyph says it.
    public static func muted(_ muting: Bool, count: Int = 1) -> String {
        let n = count.formatted(.number.grouping(.automatic))
        let word = muting ? "Muted" : "Unmuted"
        return count > 1 ? "\(word) \(n) conversations" : word
    }

    /// A sender rule's command as the menus name it (spec, Sender rules (Q4.2)), which Edit › Undo and the undo
    /// confirmation repeat.
    public static func senderRuleCommand(_ action: SenderRule.Action) -> String {
        switch action {
        case .archive: return "Always Archive Mail from This Sender"
        case .trash: return "Block Sender"
        }
    }

    /// The toast a new sender rule leaves (spec, Sender rules (Q4.2)): “Blocked deals@shop.example”, “Always archiving
    /// news@letter.example”. Always shown, since no row shows a rule, and naming the address the rule now holds, since
    /// the context menu's and the Message menu's items do not say whose mail in the conversation they take. The address
    /// goes last, so a long one loses its end to the slip's truncation and the verb stays.
    public static func senderRuleSet(_ action: SenderRule.Action, address: String) -> String {
        switch action {
        case .archive: return "Always archiving \(address)"
        case .trash: return "Blocked \(address)"
        }
    }

    /// What Settings › Accounts › Senders… says a rule does, beside its address (spec, Sender rules (Q4.2)).
    public static func senderRuleDescription(_ action: SenderRule.Action) -> String {
        switch action {
        case .archive: return "Always archived"
        case .trash: return "Blocked"
        }
    }

    /// “Undid Archive”: the action-less toast an undo confirms itself with.
    public static func undoConfirmation(for change: MetadataChange) -> String {
        "Undid \(commandName(for: change))"
    }

    /// Edit › Undo's title while `change` is the undo target: “Undo Archive”.
    public static func undoMenuTitle(for change: MetadataChange) -> String {
        "Undo \(commandName(for: change))"
    }

    /// Only actions that take a row out of the list, or change several rows at once, get a toast: starring or
    /// marking one conversation unread does not, because the row itself shows the change (§4.13). `view` is the view
    /// the list shows; while searching, the one the search looks through (All Mail, where only moving to the trash
    /// takes a result away, or the view an `in:` term picked), with `search` the search itself, whose other terms can
    /// take a result away too (unstarring in an `is:starred` search). Read state never does: the list keeps the open
    /// conversation in an `is:unread` search (`ConversationQuery.openConversationID`).
    public static func wantsToast(for change: MetadataChange, in view: MailboxView, search: SearchQuery? = nil, count: Int = 1) -> Bool {
        if count > 1 { return true }
        if takesAway(change, from: view) { return true }
        for term in search?.terms ?? [] {
            switch (term.kind, term.negated) {
            case (.mailbox(let other), false):
                if takesAway(change, from: other) { return true }
            case (.mailbox(.inbox), true):
                if change == .moveToInbox || change == .restoreFromTrash { return true }
            case (.starred, false):
                if change == .setStarred(false) { return true }
            case (.starred, true):
                if change == .setStarred(true) { return true }
            default:
                continue
            }
        }
        return false
    }

    private static func takesAway(_ change: MetadataChange, from view: MailboxView) -> Bool {
        switch change {
        case .archive: return view == .inbox
        case .trash: return view != .trash
        // Out of Later too: back in the Inbox, a conversation is no longer snoozed.
        case .moveToInbox, .restoreFromTrash: return view == .trash || view == .later
        case .setStarred(false): return view == .starred
        case .setStarred(true), .setRead: return false
        // The request goes somewhere the row cannot show, so it is always said.
        case .unsubscribe: return true
        // The card shows the answer as chosen, so nothing leaves the view.
        case .answerInvitation: return false
        }
    }

    /// “Couldn't archive. Restored.”: the toast for an operation the provider refused, whose change the store
    /// has already put back.
    public static func failure(for kind: OperationKind) -> String {
        switch kind {
        case .archive: return "Couldn't archive. Restored."
        case .moveToInbox, .restoreFromTrash: return "Couldn't move to Inbox. Restored."
        case .markRead: return "Couldn't mark as read. Restored."
        case .markUnread: return "Couldn't mark as unread. Restored."
        case .star: return "Couldn't star. Restored."
        case .unstar: return "Couldn't unstar. Restored."
        case .trash: return "Couldn't move to Trash. Restored."
        case .unsubscribe: return "Couldn't unsubscribe."
        case .answerInvitation: return "Couldn't answer the invitation. Restored."
        }
    }
}
