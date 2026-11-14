import SwiftUI

/// The +/− pair under the Settings account group (spec §5.40): two joined 22 pt squares, `raised`, a 1 pt
/// `ruleStrong` edge with a shared middle edge, outer radius `r.sm`, glyphs 11 pt `ink2`. Hover washes the face
/// `hover` and the glyph goes `ink`; pressed washes it `pressed`; each half is its own Tab stop with its own
/// ring; a disabled half changes only its glyph, to `inkDisabled`. + opens the add-account menu under itself.
struct QuirePlusMinus<AddMenu: View>: View {
    enum Half: Hashable {
        case plus
        case minus
    }

    let isAddEnabled: Bool
    let isRemoveEnabled: Bool
    let onRemove: () -> Void
    @ViewBuilder let addMenu: () -> AddMenu

    @FocusState private var focusedHalf: Half?
    @Environment(\.quireForcedStates) private var forced

    var body: some View {
        let side = Quire.Layout.Settings.plusMinus
        // The halves overlap by the edge width, so their two inset edges become one shared middle edge.
        HStack(spacing: -Quire.Border.Strong.width) {
            Menu {
                addMenu()
            } label: {
                QuireSymbolImage(name: Quire.Icon.addAccount, size: .custom(Quire.Layout.Settings.plusMinusGlyph))
            }
            .menuStyle(.button)
            .buttonStyle(QuireJoinedButtonStyle(isLeading: true))
            .menuIndicator(.hidden)
            .focusEffectDisabled()
            .focused($focusedHalf, equals: .plus)
            .disabled(!isAddEnabled)
            .frame(width: side, height: side)
            // The focused half draws over its neighbour, so the shared edge never cuts its ring.
            .zIndex(focusedHalf == .plus || forced.contains(.focused) ? 1 : 0)
            .accessibilityLabel("Add Account")

            Button(action: onRemove) {
                QuireSymbolImage(name: Quire.Icon.removeAccount, size: .custom(Quire.Layout.Settings.plusMinusGlyph))
            }
            .buttonStyle(QuireJoinedButtonStyle(isLeading: false))
            // A forced focus shows on + only: one ring for the pair, as one Tab stop would have it.
            .transformEnvironment(\.quireForcedStates) { $0.remove(.focused) }
            .focusEffectDisabled()
            .focused($focusedHalf, equals: .minus)
            .disabled(!isRemoveEnabled)
            .zIndex(focusedHalf == .minus ? 1 : 0)
            .accessibilityLabel("Remove Account")
        }
        .fixedSize()
    }
}

/// What one half of the pair draws in one state.
struct QuireJoinedButtonAppearance: Equatable {
    var face: QuireFill
    var edge: QuireStroke
    var glyph: QuireColorToken
    var ringGap: CGFloat?

    static func resolve(state live: QuireControlState) -> QuireJoinedButtonAppearance {
        let state = live.interactive
        let wash: QuireColorToken? = state.isPressed ? .pressed : state.isHovered ? .hover : nil
        let glyph: QuireColorToken = !state.isEnabled ? .inkDisabled : (wash == nil ? .ink2 : .ink)
        return QuireJoinedButtonAppearance(face: QuireFill(.raised, wash: wash), edge: .strong, glyph: glyph,
                                           ringGap: state.showsFocusRing ? Quire.Border.FocusRing.gap : nil)
    }
}

/// One half of the joined pair; `isLeading` picks which outer corners round.
struct QuireJoinedButtonStyle: ButtonStyle {
    let isLeading: Bool

    func makeBody(configuration: Configuration) -> some View {
        QuireJoinedButtonChrome(isLeading: isLeading, isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

struct QuireJoinedButtonChrome<Label: View>: View {
    let isLeading: Bool
    let isPressed: Bool
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced
    @State private var isHovered = false

    var body: some View {
        let side = Quire.Layout.Settings.plusMinus
        let r = Quire.Radius.sm
        let state = QuireControlState(isHovered: isHovered, isPressed: isPressed, isFocused: isFocused, isEnabled: isEnabled,
                                      isWindowKey: activeState != .inactive).forcing(forced)
        let a = QuireJoinedButtonAppearance.resolve(state: state)
        let shape = UnevenRoundedRectangle(topLeadingRadius: isLeading ? r : 0, bottomLeadingRadius: isLeading ? r : 0,
                                           bottomTrailingRadius: isLeading ? 0 : r, topTrailingRadius: isLeading ? 0 : r,
                                           style: .circular)
        label()
            .foregroundStyle(a.glyph.style)
            .frame(width: side, height: side)
            .background { QuireFace(shape: shape, fill: a.face, edge: a.edge) }
            .overlay {
                if let gap = a.ringGap {
                    QuireFocusRingView(shape: .unevenRoundedRectangle(leading: isLeading ? r : 0, trailing: isLeading ? 0 : r),
                                       gap: gap)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .quireMinimumHitArea(width: side, height: side)
            .quirePointer()
            .onHover { isHovered = $0 }
    }
}
