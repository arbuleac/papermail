import SwiftUI

/// The button variants of spec §5.24.
public enum QuireButtonVariant: String, CaseIterable, Sendable {
    /// `accentFill` with an `onAccent` label in the size's strong role. One per window or sheet; in a window
    /// that is not key it draws as `.secondary` (spec §3.4).
    case primary
    /// `raised` face, 1 pt `ruleStrong` edge, `ink` label.
    case secondary
    /// No face; `ink2` label that takes a `hover` / `pressed` wash and `ink`.
    case ghost
    /// `dangerFill` with an `onDanger` label in the strong role. Never the default button.
    case destructive
    /// An `accent` label with no face, ever: it sits on banners and washes where a further wash pulls `accent`
    /// under 4.5:1, so hover and press show as an underline and, pressed, an `ink2` label.
    case link
    /// A glyph-only square button: 22 / 24 / 28 pt for small / regular / large (`button.icon`).
    case icon
}
