import AppKit
import SwiftUI

extension Font {
    /// A Quire role for SwiftUI (Settings, spec §8.3). Built from the same cached `NSFont`, so SwiftUI and AppKit
    /// set identical type, the Font setting included (a New York role is its sans twin under SF Pro). The
    /// setting is read when the view's body runs: a view that must follow a switch while on screen re-renders on
    /// `QuireEnvironment.didChangeNotification` (`quireRefreshesOnEnvironmentChange()`, or its own state as
    /// `QuireAvatarView` does). SwiftUI has no line-height control; Settings rows lay out on their own grid.
    public static func quire(_ role: QuireFont.Role, unread: Bool = false) -> Font {
        Font(QuireFont.font(role, unread: unread) as CTFont)
    }
}
