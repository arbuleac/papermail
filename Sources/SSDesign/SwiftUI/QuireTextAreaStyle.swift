import SwiftUI

/// The Quire text-field container around content that lays out several lines of its own (spec §5.25, §5.40
/// Signature): the same `sheet` face, radius 6, 1 pt `ruleStrong` inset edge (`ink3` hovered) and Quire focus ring
/// outside a 1 pt gap as `QuireFieldStyle`, with the 8 pt side padding, at a fixed height. Unlike `QuireFieldStyle`
/// it sets no font and no line limit, and it does not track focus itself: the content is usually an AppKit text view
/// (the composer's editor in the Settings signature field), whose focus SwiftUI cannot see, so the caller passes it.
///
///     SignatureField(…)
///         .quireTextAreaStyle(height: Quire.Layout.Settings.signatureFieldHeight, isFocused: isEditing)
public struct QuireTextAreaStyle: ViewModifier {
    public let height: CGFloat
    public let isFocused: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced
    @State private var isHovered = false

    public init(height: CGFloat, isFocused: Bool) {
        self.height = height
        self.isFocused = isFocused
    }

    public func body(content: Content) -> some View {
        let f = Quire.Layout.TextField.self
        let state = QuireControlState(isHovered: isHovered, isFocused: isFocused, isEnabled: isEnabled,
                                      isWindowKey: activeState != .inactive).forcing(forced.subtracting(.pressed))
        let a = QuireFieldAppearance.resolve(hasError: false, state: state)
        let shape = RoundedRectangle(cornerRadius: f.radius, style: .circular)
        content
            .padding(.horizontal, f.padX)
            .frame(height: height)
            .background { QuireFace(shape: shape, fill: a.face, edge: a.edge) }
            .clipShape(shape)
            .overlay {
                if let gap = a.ringGap {
                    QuireFocusRingView(shape: .roundedRectangle(cornerRadius: f.radius), gap: gap).allowsHitTesting(false)
                }
            }
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Wraps this multi-line content in the Quire field container (see `QuireTextAreaStyle`).
    public func quireTextAreaStyle(height: CGFloat, isFocused: Bool) -> some View {
        modifier(QuireTextAreaStyle(height: height, isFocused: isFocused))
    }
}
