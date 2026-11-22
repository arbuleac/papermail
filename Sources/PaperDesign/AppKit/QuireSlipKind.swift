extension QuireSlipView {
    /// The toast variants of spec §5.30.
    public enum Kind: Sendable {
        /// Past tense plus Undo and its keycap (“Archived · Undo Z”), with the contrail over its life.
        case undoable
        /// An undo confirming itself (“Undid Archive”): `arrow.uturn.backward`, no action, no divider, no contrail.
        case confirmation
        /// `exclamationmark.triangle.fill` in `onSlip2` (“Couldn't archive. Restored.”), an optional action
        /// (“Details”, “Open draft”) that is never Undo; the contrail only when it has an action.
        case error
        /// Something finished that has nothing to undo (“Saved 3 attachments to Downloads”), with an optional action
        /// that is never Undo and has no keycap (“Show in Finder”); the contrail only when it has an action.
        case notice

        /// The glyph shown unless the slip names its own (an undoable toast shows its action's symbol).
        public var defaultSymbol: String {
            switch self {
            case .undoable, .confirmation: return Quire.Icon.undone
            case .error: return Quire.Icon.error
            case .notice: return Quire.Icon.success
            }
        }
    }
}
