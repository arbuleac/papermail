import SwiftUI

/// Quire's buttons for SwiftUI (spec §5.24, §8.3): `.primary`, `.secondary`, `.ghost`, `.destructive`, `.link`
/// and `.icon`, in `.small`, `.regular` and `.large`.
///
///     Button("Save") { … }.buttonStyle(.quire(.primary, size: .small)).keyboardShortcut(.defaultAction)
///
/// It is a `PrimitiveButtonStyle` so that it can wrap the real button and turn off its system focus effect;
/// the face, edge, label colour, underline and focus ring all come from `QuireButtonAppearance`. Hover is
/// tracked with `onHover`, focus from the button's `isFocused` environment, key state from
/// `controlActiveState`; `.quireForcedStates(_:)` forces hover, press and focus for a gallery. The label can be
/// any view; `QuireButtonLabel` adds the glyph and the loading state at this size's metrics.
public struct QuireButtonStyle: PrimitiveButtonStyle {
    public let variant: QuireButtonVariant
    public let size: QuireButtonSize

    public init(_ variant: QuireButtonVariant = .secondary, size: QuireButtonSize = .regular) {
        self.variant = variant
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(QuireButtonBody(variant: variant, size: size))
            .focusEffectDisabled()
    }
}

extension PrimitiveButtonStyle where Self == QuireButtonStyle {
    /// `QuireButtonStyle(variant, size: size)`.
    public static func quire(_ variant: QuireButtonVariant = .secondary, size: QuireButtonSize = .regular) -> QuireButtonStyle {
        QuireButtonStyle(variant, size: size)
    }
}

/// The inner style: it alone sees `isPressed`.
struct QuireButtonBody: ButtonStyle {
    let variant: QuireButtonVariant
    let size: QuireButtonSize

    func makeBody(configuration: Configuration) -> some View {
        QuireButtonChrome(variant: variant, size: size, isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

struct QuireButtonChrome<Label: View>: View {
    let variant: QuireButtonVariant
    let size: QuireButtonSize
    let isPressed: Bool
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced
    @Environment(\.quireUnderlinesLinksAtRest) private var underlinesLinksAtRest
    @State private var isHovered = false

    var body: some View {
        let state = QuireControlState(isHovered: isHovered, isPressed: isPressed, isFocused: isFocused,
                                      isEnabled: isEnabled, isWindowKey: activeState != .inactive,
                                      isGraphite: QuireEnvironment.isGraphite,
                                      underlinesLinksAtRest: underlinesLinksAtRest).forcing(forced)
        let a = QuireButtonAppearance.resolve(variant, size: size, state: state)
        let shape = RoundedRectangle(cornerRadius: a.cornerRadius, style: .circular)
        label()
            .quireFont(a.font)
            .lineLimit(1)
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                // The link underline as AppKit draws it (§5.24): 1 pt, its top 2 pt below the baseline. Text's
                // own underline takes the font's position and thickness, which crosses the descenders.
                if a.underline {
                    Rectangle()
                        .fill(a.label.style)
                        .frame(height: Quire.Layout.TextStyle.linkUnderline)
                        .alignmentGuide(.firstTextBaseline) { _ in -Quire.Layout.TextStyle.linkUnderlineOffset }
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(a.label.style)
            .environment(\.quireButtonSize, size)
            .padding(.horizontal, a.padX)
            .frame(width: a.width, height: a.height)
            .background { QuireFace(shape: shape, fill: a.fill, edge: a.edge) }
            .overlay {
                if let gap = a.ringGap {
                    QuireFocusRingView(shape: .roundedRectangle(cornerRadius: a.cornerRadius), gap: gap)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .quireMinimumHitArea(width: a.width, height: a.height)
            .quirePointer()
            .onHover { isHovered = $0 }
    }
}

private struct QuireButtonSizeKey: EnvironmentKey {
    static let defaultValue: QuireButtonSize = .regular
}

extension EnvironmentValues {
    /// The size of the Quire button around a label, so `QuireButtonLabel` sizes its glyph and gap to match.
    var quireButtonSize: QuireButtonSize {
        get { self[QuireButtonSizeKey.self] }
        set { self[QuireButtonSizeKey.self] = newValue }
    }
}
