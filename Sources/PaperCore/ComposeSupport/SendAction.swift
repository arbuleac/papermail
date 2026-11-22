import Foundation

/// What the Send button and ⌘↩ do (spec §5.23). Send and Archive, the default, sends and then archives the conversation
/// the message answers, as E would; Send only sends. ⇧⌘↩ sends and archives whichever is chosen. A new message answers
/// no conversation, so it only sends. The user picks one in the Send button's drop-down and it is kept as a preference;
/// pure, so its words are tested without AppKit.
public enum SendAction: String, CaseIterable, Sendable {
    case sendAndArchive
    case send

    /// What a fresh install does.
    public static let `default`: SendAction = .sendAndArchive

    /// The command's name as menus say it (title case, §4.13): the drop-down's items, Message › Send and Archive.
    public var title: String {
        switch self {
        case .sendAndArchive: return "Send and Archive"
        case .send: return "Send"
        }
    }

    /// Whether the conversation the message answers is archived once the send is queued.
    public var archives: Bool { self == .sendAndArchive }

    /// The Send button's tooltip while a click and ⌘↩ do this: “Send and Archive  ⌘↩” (§5.34).
    public var tooltip: String { title + "  ⌘↩" }

    /// The key that does this action while `current` is Send's choice (§5.23), as the drop-down shows it beside the
    /// action: ⌘↩ for the checked choice, since ⌘↩ and Send do it; ⇧⌘↩ for Send and Archive while Send is the choice,
    /// since ⇧⌘↩ always sends and archives; none for Send while Send and Archive is the choice, since no key only sends
    /// then. Never a key that does something else.
    public func key(whenChosen current: SendAction) -> SendKey? {
        if self == current { return .commandReturn }
        return self == .sendAndArchive ? .shiftCommandReturn : nil
    }

    /// What a send queued with this action does to a message that does (`answers`) or does not answer a conversation:
    /// a new message has none to archive, so it only sends, and its Send button says so.
    public func effective(answers: Bool) -> SendAction {
        answers ? self : .send
    }

    /// Edit › Undo's title while a send can still be cancelled: “Undo Send and Archive” when it archived its
    /// conversation, which the undo puts back too, else “Undo Send” (§6.1).
    public static func undoMenuTitle(archived: Bool) -> String {
        "Undo " + (archived ? SendAction.sendAndArchive : .send).title
    }
}
