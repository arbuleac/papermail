import AppKit
import SwiftUI

extension Font {
    /// A Quire role for SwiftUI (Settings, spec §8.3). Built from the same cached `NSFont`, so SwiftUI and AppKit
    /// set identical type. SwiftUI has no line-height control; Settings rows lay out on their own grid.
    public static func quire(_ role: QuireFont.Role, unread: Bool = false) -> Font {
        Font(QuireFont.font(role, unread: unread) as CTFont)
    }
}
