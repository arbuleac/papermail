extension QuireButton {
    /// The button variants of spec §5.24. Icon-only buttons are `QuireIconButton`.
    public enum Variant: String, CaseIterable, Sendable {
        /// `accentFill`, `onAccent` label in the size's strong role. One per window or sheet; drawn as
        /// secondary while its window is not key (§3.4).
        case primary
        /// `raised` with a 1 pt `ruleStrong` inset edge, `ink` label.
        case secondary
        /// No fill, `ink2` label, optional leading glyph (tertiary).
        case ghost
        /// `dangerFill`, `onDanger` label in the strong role. Never the default button.
        case destructive
        /// No fill ever, `accent` label: hover and press show in the underline and the label colour, because
        /// link buttons sit on washes where a further wash would pull `accent` under 4.5:1.
        case link
        /// Small only: one of a set of answers (an invitation's Accept · Tentative · Decline). Off, the secondary look;
        /// on (`isOn`), `accentWash` with a leading check (`onSymbol` overrides it) and an `accent` label in the strong
        /// role, no edge. A click on the chosen one does nothing (the arrow, not the hand); VoiceOver hears a toggle.
        case choice
    }
}
