import SwiftUI

/// Measures wrapping content at a definite width even when SwiftUI asks for its ideal size.
///
/// `Grid` sizes its columns from each cell's ideal size, which for wrapping text is one unbroken line; the
/// cell is then laid out at the real column width, wraps to more lines than were measured, and the rows
/// around it are squeezed to make room (a two-line caption in the Settings grid cost the banner above it
/// 14 pt). Laid out through this, the content is measured at `min(proposed width, maxWidth)`, or at
/// `maxWidth` when no width is proposed, so measuring and laying out agree. The OAuth caption uses it; use it
/// on any wrapping text in a Settings grid row (the account detail's Last error).
public struct QuireWrapWidth: Layout {
    public let maxWidth: CGFloat

    public init(maxWidth: CGFloat) {
        self.maxWidth = maxWidth
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

extension View {
    /// Lays this wrapping content out through `QuireWrapWidth(maxWidth:)`.
    public func quireWrapWidth(_ maxWidth: CGFloat) -> some View {
        QuireWrapWidth(maxWidth: maxWidth) { self }
    }
}
