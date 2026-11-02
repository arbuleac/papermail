import SwiftUI

/// An edge drawn inside a control's outline: the 1 pt `ruleStrong` edge, the `ink3` hover edge, the 1.5 pt
/// `danger` error edge (spec §4.7). Inset, so the edge never changes the control's size.
public struct QuireStroke: Equatable, Sendable {
    public var token: QuireColorToken
    public var width: CGFloat

    public init(_ token: QuireColorToken, width: CGFloat = Quire.Border.Strong.width) {
        self.token = token
        self.width = width
    }

    /// The state-bearing 1 pt edge (fields, checkbox, toggle-off track, secondary buttons, popups, tags).
    public static let strong = QuireStroke(.ruleStrong)
    /// The error edge of a field.
    public static let error = QuireStroke(.danger, width: Quire.Border.Error.width)
}
