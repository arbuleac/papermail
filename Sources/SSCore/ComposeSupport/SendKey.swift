import Foundation

/// The keys that send from a composer or the quick reply (spec §5.23, §6), as Send's tooltip and its drop-down show them.
/// Pure, so which row shows which key is tested without AppKit; the app turns it into a menu item's key equivalent.
public enum SendKey: Sendable, Equatable {
    /// ⌘↩: what Send does, the drop-down's checked choice.
    case commandReturn
    /// ⇧⌘↩: Send and Archive, whatever Send does.
    case shiftCommandReturn

    /// The key's legend as tooltips and menus write it (§5.34, §5.36).
    public var legend: String {
        switch self {
        case .commandReturn: return "⌘↩"
        case .shiftCommandReturn: return "⇧⌘↩"
        }
    }

    /// How VoiceOver says it, as the system says a menu's key equivalent.
    public var spoken: String {
        switch self {
        case .commandReturn: return "⌘Return"
        case .shiftCommandReturn: return "⇧⌘Return"
        }
    }
}
