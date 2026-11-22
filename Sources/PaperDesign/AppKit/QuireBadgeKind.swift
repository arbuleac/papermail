extension QuireBadge {
    /// The badges of spec §5.28.
    public enum Kind: Equatable, Sendable {
        /// Unread count on a rail tile: `accentFill` / `onAccent`, 16 pt pill, min 16, capped at “99+”.
        case unread(Int)
        /// Message count in a row: `fill` / `ink2`, 16 pt, min 18, the exact number.
        case messageCount(Int)
        /// An 8 pt `accent` dot.
        case dot
        /// Needs sign-in: a 16 pt `dangerFill` circle with `exclamationmark` 9 pt Semibold in `onDanger`.
        case attention

        var isMessageCount: Bool {
            if case .messageCount = self { return true }
            return false
        }
    }
}
