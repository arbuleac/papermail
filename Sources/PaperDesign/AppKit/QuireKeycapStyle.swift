import AppKit

extension QuireKeycap {
    /// The keycap sizes and surfaces of spec §5.36 (`layout.kbd`).
    public enum Style: Hashable, Sendable {
        /// 18 pt, radius 3, `raised` with a `rule` edge and key depth: menus aside, every keycap in content.
        case standard
        /// 16 pt, inside the search field.
        case inField
        /// 24 pt, radius 5, 12 pt legend: the cheat sheet.
        case large
        /// 18 pt on a slip: no fill, an `onSlipEdge` outline, legend `onSlip2` (`onSlip` while its action is
        /// hovered or pressed).
        case onSlip

        /// The cap's height, which is also its minimum width.
        public var height: CGFloat {
            switch self {
            case .standard, .onSlip: return Quire.Layout.Kbd.height
            case .inField: return Quire.Layout.Kbd.inField
            case .large: return Quire.Layout.Kbd.largeHeight
            }
        }

        public var cornerRadius: CGFloat {
            self == .large ? Quire.Layout.Kbd.largeRadius : Quire.Layout.Kbd.radius
        }

        /// The legend font: the `kbd` role, at `kbd.largeFont` on a large cap.
        public var font: NSFont {
            let base = QuireFont.font(.kbd)
            guard self == .large else { return base }
            return NSFont(descriptor: base.fontDescriptor, size: Quire.Layout.Kbd.largeFont) ?? base
        }
    }
}
