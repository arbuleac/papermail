import SwiftUI

/// The line at the foot of a `QuireRuleSheet`, leading on Done's row (spec §5.52, the Senders sheet): `meta` `ink3` words
/// about the list as a whole that are not rows of it (“12 other filters in Gmail”), an optional `accent` link after them
/// (“Open Gmail Settings”), and a 12 pt `ink3` spinner before the words while the list is being read (“Reading Gmail
/// filters…”).
public struct QuireRuleSheetFoot {
    public var words: String?
    public var isWorking: Bool
    public var link: (title: String, action: () -> Void)?

    public init(words: String? = nil, isWorking: Bool = false, link: (title: String, action: () -> Void)? = nil) {
        self.words = words
        self.isWorking = isWorking
        self.link = link
    }
}
