import SwiftUI

/// The margin-rule selection (spec §2, §3.4, §5.40): a wash plus a 3 pt rule flush with the leading edge,
/// `selWash` + `selRule` while the window is key and `selWashIdle` + `selRuleIdle` when it is not. The rule is
/// always drawn, so selection never rests on a faint colour. Rows take no hover or pressed wash.
public struct QuireSelectionAppearance: Equatable, Sendable {
    /// The row's fill; nil for an unselected row, which shows its group's `sheet`.
    public var wash: QuireColorToken?
    /// The margin rule; nil for an unselected row.
    public var rule: QuireColorToken?

    public init(wash: QuireColorToken?, rule: QuireColorToken?) {
        self.wash = wash
        self.rule = rule
    }

    public static func resolve(isSelected: Bool, isWindowKey: Bool) -> QuireSelectionAppearance {
        guard isSelected else { return QuireSelectionAppearance(wash: nil, rule: nil) }
        return isWindowKey
            ? QuireSelectionAppearance(wash: .selWash, rule: .selRule)
            : QuireSelectionAppearance(wash: .selWashIdle, rule: .selRuleIdle)
    }
}
