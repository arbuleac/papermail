import SSCore
import SSDesign

extension QuireSwipeAction {
    /// The button for a change a swipe offers (`RowSwipe`): E's archive wears Archive's fill and U's read change the
    /// quiet one, so the two edges never look alike. A swipe offers no other change, so no other has a button.
    init?(_ change: MetadataChange) {
        switch change {
        case .archive: self = .archive
        case .setRead: self = .readState
        default: return nil
        }
    }
}
