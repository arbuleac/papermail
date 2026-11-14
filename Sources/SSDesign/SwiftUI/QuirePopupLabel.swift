import AppKit
import SwiftUI

/// The face of a Quire popup button (spec §5.27): 24 pt, radius 6, `raised` with a 1 pt `ruleStrong` edge,
/// padding 0 6 0 9, the value in `body` `ink`, and the 12 pt `chevron.up.chevron.down` in `ink2`, 8 pt after
/// it. An account swatch (the Settings Colour popup's 14 pt disc) sits on a 2 pt `raised` halo so that a
/// hovered or pressed face never puts its wash under the ink (§4.2).
///
/// Use it as the label of a `Menu` styled by `QuirePopup`, which reports the press (menu open) to it; on its
/// own it tracks hover, focus and enabled state from the environment, and `.quireForcedStates(_:)` forces any
/// of them.
public struct QuirePopupLabel: View {
    let value: String
    let swatch: Int?
    let width: CGFloat?
    let borderless: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced
    @Environment(\.quirePopupIsPressed) private var isPressed
    @State private var isHovered = false

    /// - Parameters:
    ///   - swatch: an account ink slot to show as a 14 pt swatch before the value.
    ///   - width: a fixed width (the Colour popup's 160 pt); the chevron then sits at the trailing edge.
    ///   - borderless: no face or edge until hovered (the composer's From popup).
    public init(_ value: String, swatch: Int? = nil, width: CGFloat? = nil, borderless: Bool = false) {
        self.value = value
        self.swatch = swatch
        self.width = width
        self.borderless = borderless
    }

    public var body: some View {
        let p = Quire.Layout.Popup.self
        let state = QuireControlState(isHovered: isHovered, isPressed: isPressed, isFocused: isFocused, isEnabled: isEnabled,
                                      isWindowKey: activeState != .inactive).forcing(forced)
        let a = QuirePopupAppearance.resolve(borderless: borderless, state: state)
        let shape = RoundedRectangle(cornerRadius: p.radius, style: .circular)
        HStack(spacing: p.gap) {
            if let swatch {
                QuirePopupSwatch(slot: swatch, halo: !borderless || !a.face.isClear)
            }
            Text(value)
                .quireFont(.body)
                .lineLimit(1)
                .foregroundStyle(a.label.style)
            if width != nil {
                Spacer(minLength: 0)
            }
            QuireSymbolImage(name: Quire.Icon.popup, size: .custom(p.chevron))
                .foregroundStyle(a.chevron.style)
        }
        .padding(.leading, p.padLeft)
        .padding(.trailing, p.padRight)
        .frame(width: width, height: p.height)
        .background { QuireFace(shape: shape, fill: a.face, edge: a.edge) }
        .overlay {
            if let gap = a.ringGap {
                QuireFocusRingView(shape: .roundedRectangle(cornerRadius: p.radius), gap: gap).allowsHitTesting(false)
            }
        }
        .contentShape(shape)
        .onHover { isHovered = $0 }
    }
}

/// An account swatch on its `raised` halo. The halo is drawn over the face's wash, which is the same as the
/// wash stopping at it: the ink always meets `raised`, its asserted surface.
struct QuirePopupSwatch: View {
    let slot: Int
    var halo: Bool = true

    var body: some View {
        let side = Quire.Layout.Settings.swatch
        Circle()
            .fill(Color.qAccount(slot))
            .frame(width: side, height: side)
            .background {
                if halo {
                    Circle().fill(.qRaised).padding(-Quire.Layout.Popup.inkHalo)
                }
            }
    }

    /// The swatch as a menu item image. Menu items are AppKit's, so the image resolves the dynamic ink when the
    /// menu draws it, in the menu's appearance; it is decorative there (the title names the ink, §5.27).
    static func menuImage(slot: Int) -> NSImage {
        let side = Quire.Layout.Settings.swatch
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.qAccount(slot).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private struct QuirePopupIsPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by `QuirePopup` while its button is pressed, which for a menu button is while the menu is open.
    var quirePopupIsPressed: Bool {
        get { self[QuirePopupIsPressedKey.self] }
        set { self[QuirePopupIsPressedKey.self] = newValue }
    }
}
