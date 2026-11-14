import AppKit
import SSCore
import SSDesign

/// The app's undo history and its one toast (spec §5.19a, §5.30, §6.1). The main window and every reader window it opened
/// record their steps here, so Z and ⌘Z reach the latest step from any of them, one toast shows at a time across them,
/// and each step remembers the window it was taken in, so its toast and its undo land there. How a step is put back is
/// the main window's (`revertGroup`): it takes every mail action, a reader window's included, and knows Later, the snoozes
/// and the return marks. One per mailbox on screen: the demo's and the user's never share a history, since a step's
/// revert writes through the engine it was taken with.
@MainActor
final class MailUndoCenter: UndoKeyArbiter {
    var history = MailActionUndoHistory(grace: Quire.Motion.undoKeyGrace, coalesceWindow: Quire.Motion.toastCoalesce)
    /// The one toast, shown in whichever window's host a step names.
    let toasts: ToastPresenter
    /// Every reader whose quick reply may hold a send ⌘Z can still cancel: the main window's and each reader window's.
    var readers: () -> [ConversationViewController] = { [] }
    /// Reverts the group with this id (Z, ⌘Z, a toast's Undo).
    var revertGroup: ((Int) -> Void)?

    /// Where each group was taken, by group id; a group not listed was taken in the main window.
    private var places: [Int: UndoPlace] = [:]

    init(toasts: ToastPresenter) {
        self.toasts = toasts
        // A toast stopped being visible: Z and ⌘Z reach its action for the grace period more (§6.1), and an undo-send
        // panel it outranked takes ⌘Z back.
        toasts.onEnd = { [weak self] id, _ in
            self?.history.toastEnded(id, at: Date())
            UndoSendPanel.refreshUndoKeyOwner()
        }
    }

    // MARK: Places

    /// Records that group `id` was taken in `place`, and forgets the places of groups that fell out of the history.
    func remember(_ place: UndoPlace, for id: Int) {
        let live = Set(history.groups.map(\.id))
        places = places.filter { live.contains($0.key) }
        if case .reader = place { places[id] = place }
    }

    func place(of id: Int) -> UndoPlace {
        places[id] ?? .main
    }

    /// The toast a step taken in `place` may coalesce into: the visible one, while the latest group was taken in the same
    /// window. Steps from different windows never coalesce, so one Undo never reaches into two windows (§5.19a).
    func coalescingToastID(in place: UndoPlace) -> Int? {
        guard let last = history.groups.last, self.place(of: last.id) == place else { return nil }
        return toasts.visibleID
    }

    // MARK: Undo order (§6.1)

    /// The group the visible toast offers, wherever it shows: one toast across the app, so Z reaches it from any window.
    var visibleToastGroup: UndoPrecedence.ToastGroup? {
        history.toastGroup(visibleToastID: toasts.visibleID).map { .init(groupID: $0.id, actedAt: $0.lastActionAt) }
    }

    /// Every send ⌘Z can still cancel: the composers' panels counting down and every reader's quick-reply countdown.
    var liveSends: [UndoPrecedence.LiveSend] {
        UndoSendPanel.liveSends + readers().compactMap(\.liveQuickSend)
    }

    /// ⌘Z and Edit › Undo: typing, then the newest live send or toast, then a toast's action in its grace.
    func commandZTarget(textCanUndo: Bool) -> UndoPrecedence.Target {
        UndoPrecedence.commandZ(textCanUndo: textCanUndo, sends: liveSends, toast: visibleToastGroup,
                                graceGroup: history.graceGroup(at: Date())?.id)
    }

    /// Z and Message › Undo: only ever the latest toast's action.
    var zTarget: UndoPrecedence.Target {
        UndoPrecedence.z(toast: visibleToastGroup, graceGroup: history.graceGroup(at: Date())?.id)
    }

    func sendOwningCommandZ() -> String? {
        UndoPrecedence.sendOwningCommandZ(sends: liveSends, toast: visibleToastGroup)
    }

    /// Edit › Undo's title for `target`: “Undo Typing” (from `typing`, the key window's own undo manager), “Undo Send”
    /// (“Undo Send and Archive” when the send archived its conversation, which the undo brings back too), “Undo Archive”,
    /// “Can't Undo”.
    func undoMenuTitle(for target: UndoPrecedence.Target, typing: UndoManager?) -> String {
        switch target {
        case .typing: return typing?.undoMenuItemTitle ?? "Undo"
        case .send(let id):
            if let reader = reader(holdingSend: id) { return reader.liveQuickSendUndoTitle }
            return UndoSendPanel.panel(sendID: id)?.undoMenuTitle ?? SendAction.undoMenuTitle(archived: false)
        case .group(let id):
            guard let group = history.groups.last(where: { $0.id == id }) else { return "Can't Undo" }
            if let change = group.change { return MailActionCopy.undoMenuTitle(for: change) }
            return "Undo " + (group.externalCommand ?? "")
        case .nothing: return "Can't Undo"
        }
    }

    /// Undoes `target`; `typing` is the key window's undo manager, which row 1 belongs to.
    func perform(_ target: UndoPrecedence.Target, typing: UndoManager?) {
        switch target {
        case .typing:
            typing?.undo()
        case .send(let id):
            if let reader = reader(holdingSend: id) {
                _ = reader.cancelQuickSend()
            } else if let panel = UndoSendPanel.panel(sendID: id) {
                panel.undo()
            }
        case .group(let id):
            if let revertGroup { revertGroup(id) } else { NSSound.beep() }
        case .nothing:
            NSSound.beep()
        }
    }

    private func reader(holdingSend id: String) -> ConversationViewController? {
        readers().first { $0.liveQuickSend?.id == id }
    }
}

/// Where an undoable step was taken (spec §5.19a): the main window, or a reader window. Its toast shows there and its undo
/// confirms itself there.
enum UndoPlace: Equatable {
    case main
    case reader(ReaderWindowPlace)

    static func == (lhs: UndoPlace, rhs: UndoPlace) -> Bool {
        switch (lhs, rhs) {
        case (.main, .main): return true
        case let (.reader(a), .reader(b)): return a === b
        default: return false
        }
    }

    var reader: ReaderWindowPlace? {
        if case .reader(let place) = self { return place }
        return nil
    }
}

/// A reader window as its steps remember it (spec §5.19a). It outlives the window: a step that closed the window (E, #, L,
/// Unsubscribe) keeps it in the undo history, and the step's undo opens the window again from it, where it was.
@MainActor
final class ReaderWindowPlace {
    let conversation: ConversationID
    /// The view the conversation was opened from, which its keys and header treat it as a row of; Move to Inbox makes it
    /// the Inbox.
    var view: MailboxView
    /// When the conversation came back from Later, as its row said when the window opened: an Archive or Move to Trash
    /// taken here puts the mark back on undo, as from the list, even once the row has left the list (§5.45).
    var returnedAt: Date?
    /// The window while it is open.
    weak var window: ReaderWindowController?
    /// Where the window was when a step closed it; nil while it is open, or once the user closed it.
    var closedFrame: NSRect?
    /// Set while a step that takes the conversation off the desk is being taken: its toast goes to the main window.
    var isClosing = false
    /// Whether the step being taken changed anything (it joined the undo history), so the window closes after it.
    var tookStep = false
    /// The view each Move to Inbox taken here moved the conversation out of, by group id: its undo puts it back.
    var viewsBeforeMove: [Int: MailboxView] = [:]

    init(conversation: ConversationID, view: MailboxView) {
        self.conversation = conversation
        self.view = view
    }
}
