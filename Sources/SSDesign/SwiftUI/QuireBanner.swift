import SwiftUI

/// A Quire semantic banner (spec §5.38): 32 pt, radius 6, padding 0 6 0 10, gap 8; a 14 pt glyph in the
/// variant's colour, the words in `snippet` `ink`, an optional trailing link button and an optional dismiss
/// button (`xmark` 9 pt `ink2`, 24 pt hit).
///
/// Words that do not fit wrap rather than truncate (Settings notices, sign-in errors): the banner grows from
/// 32 pt with 8 pt above and below, the glyph stays on the first line, and the link follows the words on
/// their last line. Pass `wraps: false` for the single-line banners that truncate.
///
///     QuireBanner(.info, "Demo mode: these mailboxes are made up and live only on this Mac.",
///                 link: ("Leave demo…", { leaveDemo() }))
public struct QuireBanner: View {
    let variant: QuireBannerVariant
    let message: String
    let glyph: String?
    let glyphColor: QuireColorToken?
    let link: (title: String, action: () -> Void)?
    let wraps: Bool
    let onDismiss: (() -> Void)?

    /// - Parameters:
    ///   - glyph: a name from `Quire.Icon`; the variant's default otherwise (`info.circle`, …).
    ///   - glyphColor: the glyph's colour; the variant's otherwise. A neutral banner reporting a partial failure
    ///     keeps its `fill` face and draws the triangle in `.warning` (§5.16).
    ///   - link: the link button's words (sentence case, spec §4.13) and its action.
    ///   - onDismiss: shows the dismiss button.
    public init(_ variant: QuireBannerVariant, _ message: String, glyph: String? = nil, glyphColor: QuireColorToken? = nil,
                link: (title: String, action: () -> Void)? = nil, wraps: Bool = true, onDismiss: (() -> Void)? = nil) {
        self.variant = variant
        self.message = message
        self.glyph = glyph
        self.glyphColor = glyphColor
        self.link = link
        self.wraps = wraps
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Group {
            if wraps {
                ViewThatFits(in: .horizontal) {
                    singleLine(fixed: true)
                    multiLine
                }
            } else {
                singleLine(fixed: false)
            }
        }
        .background {
            QuireFace(shape: RoundedRectangle(cornerRadius: Quire.Layout.Banner.radius, style: .circular), fill: variant.face)
        }
        .accessibilityElement(children: .contain)
    }

    private var glyphView: some View {
        QuireSymbolImage(name: glyph ?? variant.defaultGlyph, size: .custom(Quire.Layout.Banner.glyph))
            .foregroundStyle((glyphColor ?? variant.glyphColor).swiftUIColor)
    }

    /// The one-line banner. `fixed` keeps the words at their full width so `ViewThatFits` can tell when they
    /// no longer fit; unfixed they truncate.
    private func singleLine(fixed: Bool) -> some View {
        let b = Quire.Layout.Banner.self
        return HStack(spacing: b.gap) {
            glyphView
            Text(message)
                .quireLine(.snippet)
                .foregroundStyle(Color.qInk)
                .fixedSize(horizontal: fixed, vertical: false)
            Spacer(minLength: 0)
            if let link {
                Button(link.title, action: link.action)
                    .buttonStyle(.quire(.link, size: .small))
            }
            if let onDismiss {
                QuireBannerDismiss(action: onDismiss)
            }
        }
        .padding(.leading, b.padLeft)
        .padding(.trailing, trailingPadding)
        .frame(minHeight: b.height)
    }

    private var multiLine: some View {
        let b = Quire.Layout.Banner.self
        let line = QuireFont.Role.snippet.lineHeight
        return HStack(alignment: .top, spacing: b.gap) {
            glyphView
                .frame(height: line)
            QuireInlineLinkText(message, link: link, role: .snippet, linkRole: QuireButtonSize.small.font)
                .foregroundStyle(Color.qInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                QuireBannerDismiss(action: onDismiss)
                    .frame(height: line)
            }
        }
        .padding(.vertical, b.padY)
        .padding(.leading, b.padLeft)
        .padding(.trailing, trailingPadding)
        .frame(minHeight: b.height)
    }

    /// 6 pt when a link or the dismiss button ends the banner (their own boxes carry the rest of the space);
    /// the leading 10 pt when the words end it, so wrapped text never runs closer to the edge than it starts.
    private var trailingPadding: CGFloat {
        let b = Quire.Layout.Banner.self
        return (link != nil || onDismiss != nil) ? b.padRight : b.padLeft
    }
}

/// The banner's dismiss button: `xmark` 9 pt in `ink2` (`ink` hovered or pressed), a 16 pt box with a 24 pt
/// hit area.
struct QuireBannerDismiss: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            QuireSymbolImage(name: Quire.Icon.dismiss, size: .custom(Quire.Layout.Banner.dismissGlyph))
        }
        .buttonStyle(QuireBannerDismissStyle())
        .focusEffectDisabled()
        .accessibilityLabel("Dismiss")
    }
}

struct QuireBannerDismissStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuireBannerDismissChrome(isPressed: configuration.isPressed) { configuration.label }
    }
}

struct QuireBannerDismissChrome<Label: View>: View {
    let isPressed: Bool
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced
    @State private var isHovered = false

    var body: some View {
        let state = QuireControlState(isHovered: isHovered, isPressed: isPressed, isFocused: isFocused, isEnabled: isEnabled,
                                      isWindowKey: activeState != .inactive).forcing(forced).interactive
        // The specimen's 16 pt box (`.banner .bx`); the hit area grows to 24 pt.
        let side = Quire.Space.s6
        label()
            .foregroundStyle((state.isHovered || state.isPressed ? QuireColorToken.ink : .ink2).swiftUIColor)
            .frame(width: side, height: side)
            .overlay {
                if state.showsFocusRing {
                    QuireFocusRingView(shape: .roundedRectangle(cornerRadius: Quire.Radius.xs), gap: Quire.Border.FocusRing.gap)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .quireMinimumHitArea(width: side, height: side)
            .onHover { isHovered = $0 }
    }
}
