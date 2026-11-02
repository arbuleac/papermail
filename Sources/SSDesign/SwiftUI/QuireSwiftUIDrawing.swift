import SwiftUI

// Drawing helpers shared by the SwiftUI styles. Internal: the public surface is the styles and views.

extension QuireColorToken {
    /// The token as a SwiftUI colour. SwiftUI resolves the dynamic provider for the view's appearance, so the
    /// same value serves every mode.
    var swiftUIColor: Color { Color(nsColor: color) }
}

/// A control face: base, wash and inset edge, in one shape.
struct QuireFace<S: InsettableShape>: View {
    let shape: S
    let fill: QuireFill
    var edge: QuireStroke?

    var body: some View {
        ZStack {
            if let base = fill.base { shape.fill(base.swiftUIColor) }
            if let wash = fill.wash { shape.fill(wash.swiftUIColor) }
            if let edge { shape.strokeBorder(edge.token.swiftUIColor, lineWidth: edge.width) }
        }
    }
}

struct QuireFocusRingView: View {
    let shape: QuireFocusRingShape
    let gap: CGFloat
    /// Drawn inside the control (the account group's selected row, inset 2 pt) instead of outside it.
    var insetBy: CGFloat?

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let width = QuireFocusRingMetrics.width(increasedContrast: contrast == .increased)
        if let insetBy {
            // An inset ring lies inside the bounds: its outer edge sits `insetBy` in from the control's edge.
            ring(outerOffset: -insetBy, width: width)
        } else {
            ring(outerOffset: gap + width, width: width)
        }
    }

    /// The ring as an inset stroke of a shape whose outer edge is `outerOffset` outside the control. Whole
    /// offsets, not the centre line's half points: SwiftUI rounds layout to the display's pixels, and at 1× a
    /// half-point outset would snap the ring onto the control's edge.
    @ViewBuilder
    private func ring(outerOffset: CGFloat, width: CGFloat) -> some View {
        let color = QuireColorToken.focus.swiftUIColor
        switch shape {
        case .roundedRectangle(let radius):
            RoundedRectangle(cornerRadius: max(0, radius + outerOffset), style: .circular)
                .strokeBorder(color, lineWidth: width)
                .padding(-outerOffset)
        case .unevenRoundedRectangle(let leading, let trailing):
            // A square corner stays square, as a CSS box-shadow ring keeps it.
            let l = leading > 0 ? max(0, leading + outerOffset) : 0
            let t = trailing > 0 ? max(0, trailing + outerOffset) : 0
            UnevenRoundedRectangle(topLeadingRadius: l, bottomLeadingRadius: l, bottomTrailingRadius: t, topTrailingRadius: t,
                                   style: .circular)
                .strokeBorder(color, lineWidth: width)
                .padding(-outerOffset)
        case .capsule:
            Capsule(style: .circular).strokeBorder(color, lineWidth: width).padding(-outerOffset)
        case .circle:
            Circle().strokeBorder(color, lineWidth: width).padding(-outerOffset)
        }
    }
}

enum QuireFocusRingMetrics {
    /// 2 pt, 3 pt under Increase Contrast. Both signals count: SwiftUI's contrast environment and the system
    /// flag or override in `QuireEnvironment`, which is how off-screen renders and tests ask for IC.
    static func width(increasedContrast: Bool) -> CGFloat {
        increasedContrast || QuireEnvironment.increaseContrast ? Quire.Border.FocusRing.widthHC : Quire.Border.FocusRing.width
    }
}

/// A decorative hairline: one device pixel in `rule`, 1 pt under Increase Contrast (spec §4.7).
struct QuireHairline: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let width = QuireHairline.width(displayScale: displayScale, increasedContrast: contrast == .increased)
        Rectangle()
            .fill(QuireColorToken.rule.swiftUIColor)
            .frame(width: axis == .vertical ? width : nil, height: axis == .horizontal ? width : nil)
    }

    static func width(displayScale: CGFloat, increasedContrast: Bool) -> CGFloat {
        if increasedContrast || QuireEnvironment.increaseContrast { return Quire.Border.Hairline.widthHC }
        return 1 / max(displayScale, 1)
    }
}

extension View {
    /// Sets `role`'s font and tracking. SwiftUI has no exact line height; single-line text takes the role's
    /// line height as its frame through `quireLine(_:)`, and wrapping text gets the difference as line spacing.
    func quireFont(_ role: QuireFont.Role, unread: Bool = false) -> some View {
        font(.quire(role, unread: unread))
            .tracking(role.tracking)
    }

    /// One line of `role`: its font, tracking, and exactly its line height.
    func quireLine(_ role: QuireFont.Role) -> some View {
        quireFont(role)
            .lineLimit(1)
            .frame(minHeight: role.lineHeight, maxHeight: role.lineHeight)
    }

    /// Wrapping text in `role`, n lines exactly n × `role.lineHeight` tall, as CSS line-height and the AppKit
    /// paragraph styles set them (spec §4.4). See `QuireParagraph`.
    func quireParagraph(_ role: QuireFont.Role) -> some View {
        modifier(QuireParagraph(role: role))
    }

    /// Enlarges the pointer target to `minimum` without changing layout (spec §4.14: every pointer target is at
    /// least 24 × 24 pt, enlarging the hit rect where the visual is smaller).
    func quireMinimumHitArea(width: CGFloat?, height: CGFloat, minimum: CGFloat = Quire.Layout.Button.minHit) -> some View {
        let dy = max(0, (minimum - height) / 2)
        let dx = width.map { max(0, (minimum - $0) / 2) } ?? 0
        return contentShape(.interaction, Rectangle().inset(by: -max(dx, dy)))
    }
}

/// Exact line height for wrapping SwiftUI text. SwiftUI spaces lines by its own line height for the font
/// plus `lineSpacing`, and that height is not the AppKit one: it rounds ascent and descent to the display's
/// pixels (meta measures 14 pt at 1×, where NSLayoutManager says 13). So the modifier measures SwiftUI's
/// height for one line of the role, in place, with a hidden sample, and spaces lines by the difference to the
/// role's line height, half of it above the first line and half below the last. Until the first measurement
/// it uses the AppKit value, which is at most a point off.
struct QuireParagraph: ViewModifier {
    let role: QuireFont.Role

    @State private var naturalLine: CGFloat?

    func body(content: Content) -> some View {
        let natural = naturalLine ?? (role.lineHeight - 2 * QuireFont.baselineOffset(role))
        let leading = max(0, role.lineHeight - natural)
        content
            .quireFont(role)
            .lineSpacing(leading)
            .padding(.vertical, leading / 2)
            .background(alignment: .topLeading) {
                Text(verbatim: "Hg")
                    .quireFont(role)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalLine = $0 }
                    .accessibilityHidden(true)
            }
    }
}

/// A symbol from `Quire.Icon` at a Quire size, tinted by the foreground style. SF Symbols and `ss.` glyphs go
/// through `QuireSymbol`, so SwiftUI draws exactly the images AppKit does.
struct QuireSymbolImage: View {
    let name: String
    var size: QuireSymbolSize = .inText

    var body: some View {
        if let image = QuireSymbol.image(name, size: size) {
            Image(nsImage: image)
                .renderingMode(.template)
                .accessibilityHidden(true)
        }
    }
}

/// Arrow-key stepping through a row of choices or a stack of rows: clamped at both ends (native radio groups
/// and source lists do not wrap); from no selection, the first step lands on the first or last item.
enum QuireStep {
    static func index(after current: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return offset >= 0 ? 0 : count - 1 }
        return min(max(current + offset, 0), count - 1)
    }
}
