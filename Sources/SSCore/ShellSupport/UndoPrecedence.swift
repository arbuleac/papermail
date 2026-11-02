import Foundation

/// Who Z and ⌘Z reach in the main window (spec §6.1). Several surfaces answer them: the focused text's own
/// undo, undo-send panels and the quick reply's countdown (sends still inside their undo window), and the
/// undo history's groups (a toast's action while the toast shows and for 10000 ms after). Pure, so the order
/// is tested without windows; the shell gathers the inputs and acts on the answer.
public enum UndoPrecedence {
    public enum Target: Equatable, Sendable {
        /// Row 1: the focused text view or field undoes typing (“Undo Typing”).
        case typing
        /// Row 2: cancel this send, still inside its undo window (“Undo Send”).
        case send(String)
        /// Rows 2–3: revert this undo-history group (“Undo Archive”).
        case group(Int)
        /// Row 4: “Can't Undo”.
        case nothing
    }

    /// A send that can still be cancelled: a composer's undo-send panel counting down, or the quick reply's
    /// countdown (in its strip, or moved to a panel).
    public struct LiveSend: Equatable, Sendable {
        public var id: String
        public var startedAt: Date

        public init(id: String, startedAt: Date) {
            self.id = id
            self.startedAt = startedAt
        }
    }

    /// The undo-history group a visible toast offers, and when its action last happened.
    public struct ToastGroup: Equatable, Sendable {
        public var groupID: Int
        public var actedAt: Date

        public init(groupID: Int, actedAt: Date) {
            self.groupID = groupID
            self.actedAt = actedAt
        }
    }

    /// ⌘Z (and Edit › Undo): typing first; then the most recent of the live sends and the visible toast's
    /// group; then the group still within its grace; else nothing. Several live sends go newest first.
    public static func commandZ(textCanUndo: Bool, sends: [LiveSend], toast: ToastGroup?, graceGroup: Int?) -> Target {
        if textCanUndo { return .typing }
        let newestSend = sends.max { $0.startedAt < $1.startedAt }
        switch (newestSend, toast) {
        case let (send?, toast?):
            // Ties go to the send: it is a promise with a deadline, the toast's group stays reachable after.
            return toast.actedAt > send.startedAt ? .group(toast.groupID) : .send(send.id)
        case let (send?, nil):
            return .send(send.id)
        case let (nil, toast?):
            return .group(toast.groupID)
        case (nil, nil):
            return graceGroup.map(Target.group) ?? .nothing
        }
    }

    /// Z (single key, no text focused): only ever the latest toast's action, rows 2–3 restricted to toasts;
    /// it never cancels a send.
    public static func z(toast: ToastGroup?, graceGroup: Int?) -> Target {
        if let toast { return .group(toast.groupID) }
        return graceGroup.map(Target.group) ?? .nothing
    }

    /// The live send ⌘Z would cancel with no text in the way, if any: the undo-send panel that shows its
    /// “⌘Z” keycap (§5.31) is this one.
    public static func sendOwningCommandZ(sends: [LiveSend], toast: ToastGroup?) -> String? {
        if case .send(let id) = commandZ(textCanUndo: false, sends: sends, toast: toast, graceGroup: nil) { return id }
        return nil
    }
}
