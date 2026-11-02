import Foundation

/// Which undo-send panel ⌘Z cancels (spec §6.1, ⌘Z row 2): of the live targets, the most recent wins. A panel
/// still counting down is a target; an undoable toast that appeared after it takes ⌘Z while the toast is up,
/// and gives it back once the toast's life is over, because a live panel outranks a toast that has gone (row 2
/// before row 3). Several counting panels are cancelled newest first.
public enum UndoKeyPrecedence {
    public struct Panel: Equatable, Sendable {
        public var shownAt: Date
        public var isCounting: Bool

        public init(shownAt: Date, isCounting: Bool) {
            self.shownAt = shownAt
            self.isCounting = isCounting
        }
    }

    /// The index in `panels` of the one ⌘Z cancels now, or nil when none may (nothing counting, or a newer
    /// toast holds the key). `toastShownAt` is when the latest undoable toast appeared.
    public static func owner(of panels: [Panel], toastShownAt: Date?, toastLife: TimeInterval, now: Date) -> Int? {
        let toastIsUp = toastShownAt.map { now < $0.addingTimeInterval(toastLife) } ?? false
        return panels.indices
            .filter { panels[$0].isCounting }
            .filter { index in
                guard toastIsUp, let toastShownAt else { return true }
                return panels[index].shownAt > toastShownAt
            }
            .max { panels[$0].shownAt < panels[$1].shownAt }
    }
}
