import SwiftUI

/// The outline a focus ring follows (spec §4.1, §8.3): the ring is `width` in `focus`, outside the control,
/// `gap` away from it; its inner edge follows the control's corner radius plus the gap, as the reader's
/// `box-shadow` rings do (§8.3 states it as a stroke outset by gap + width / 2, the same ring).
public enum QuireFocusRingShape: Equatable, Sendable {
    case roundedRectangle(cornerRadius: CGFloat)
    /// Different radii on the leading and trailing corners: one half of a joined button pair (+/−).
    case unevenRoundedRectangle(leading: CGFloat, trailing: CGFloat)
    case capsule
    case circle
}
