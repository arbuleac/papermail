import PaperCore
import PaperDesign

extension QuireSwipeAction {
    /// The button for a change a swipe offers (`RowSwipe`): E's archive wears Archive's fill and icon, and U's read
    /// change the quiet fill with the envelope the menus show for it, so the two edges never look alike. A swipe offers
    /// no other change, so no other has a button.
    init?(_ change: MetadataChange) {
        switch change {
        case .archive: self = .archive
        case .setRead(true): self = .markRead
        case .setRead(false): self = .markUnread
        default: return nil
        }
    }
}
