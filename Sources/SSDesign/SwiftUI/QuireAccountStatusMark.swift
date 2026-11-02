import SwiftUI

/// What leads an account's status words (spec §5.40, Account status).
public enum QuireAccountStatusMark: Equatable, Sendable {
    case none
    /// A 12 pt glyph (`settings.statusGlyph`) from `Quire.Icon` in a colour token.
    case glyph(String, QuireColorToken)
    /// A 12 pt `ink3` spinner.
    case spinner
}
