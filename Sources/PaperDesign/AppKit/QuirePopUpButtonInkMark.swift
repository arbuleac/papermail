import CoreGraphics

extension QuirePopUpButton {
    /// An account ink in the popup's label (spec §5.27), drawn on a 2 pt `raised` halo so the face's hover or
    /// pressed wash stops short of it and the ink always meets `raised`, its asserted surface.
    public enum InkMark: Equatable, Sendable {
        /// The composer From popup's 7 pt dot (`composer.fromDot`) for an account ink slot.
        case dot(slot: Int)
        /// The Settings Colour popup's 14 pt swatch (`settings.swatch`).
        case swatch(slot: Int)

        public var slot: Int {
            switch self {
            case .dot(let slot), .swatch(let slot): return slot
            }
        }

        public var diameter: CGFloat {
            switch self {
            case .dot: return Quire.Layout.Composer.fromDot
            case .swatch: return Quire.Layout.Settings.swatch
            }
        }
    }
}
