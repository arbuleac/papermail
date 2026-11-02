import CoreGraphics

extension QuireButton {
    /// Button sizes (`layout.button.small / regular / large`, spec §5.24).
    public enum Size: String, CaseIterable, Sendable {
        /// 22 pt, padding 9, radius 5, `label` / `labelStrong`, 12 pt glyph.
        case small
        /// 28 pt, padding 12, radius 6, `bodyMedium` / `bodyStrong`, 14 pt glyph.
        case regular
        /// 36 pt, padding 16, radius 8, `buttonLarge` / `buttonLargeStrong`, 18 pt glyph.
        case large

        public var height: CGFloat {
            switch self {
            case .small: return Quire.Layout.Button.Small.height
            case .regular: return Quire.Layout.Button.Regular.height
            case .large: return Quire.Layout.Button.Large.height
            }
        }

        public var padX: CGFloat {
            switch self {
            case .small: return Quire.Layout.Button.Small.padX
            case .regular: return Quire.Layout.Button.Regular.padX
            case .large: return Quire.Layout.Button.Large.padX
            }
        }

        public var cornerRadius: CGFloat {
            switch self {
            case .small: return Quire.Layout.Button.Small.radius
            case .regular: return Quire.Layout.Button.Regular.radius
            case .large: return Quire.Layout.Button.Large.radius
            }
        }

        public var glyph: CGFloat {
            switch self {
            case .small: return Quire.Layout.Button.Small.glyph
            case .regular: return Quire.Layout.Button.Regular.glyph
            case .large: return Quire.Layout.Button.Large.glyph
            }
        }

        /// The label role (secondary, ghost, link).
        public var role: QuireFont.Role {
            switch self {
            case .small: return QuireButton.role(named: Quire.Layout.Button.Small.font)
            case .regular: return QuireButton.role(named: Quire.Layout.Button.Regular.font)
            case .large: return QuireButton.role(named: Quire.Layout.Button.Large.font)
            }
        }

        /// The strong label role (primary, destructive).
        public var strongRole: QuireFont.Role {
            switch self {
            case .small: return QuireButton.role(named: Quire.Layout.Button.Small.fontStrong)
            case .regular: return QuireButton.role(named: Quire.Layout.Button.Regular.fontStrong)
            case .large: return QuireButton.role(named: Quire.Layout.Button.Large.fontStrong)
            }
        }
    }
}
