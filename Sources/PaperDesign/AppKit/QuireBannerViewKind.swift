import AppKit

extension QuireBannerView {
    /// Banner variants (spec §5.38): a wash and a glyph colour, always with words.
    public enum Kind: String, CaseIterable, Sendable {
        /// `fill`, glyph `ink2`: the remote-images banner, the offline notice. Privacy is not a warning.
        case neutral
        /// `infoWash`, glyph `info`.
        case info
        /// `successWash`, glyph `success`.
        case success
        /// `warningWash`, glyph `warning`: the Original colors notice.
        case warning
        /// `dangerWash`, glyph `danger`: errors.
        case danger

        public var wash: NSColor {
            switch self {
            case .neutral: return .qFill
            case .info: return .qInfoWash
            case .success: return .qSuccessWash
            case .warning: return .qWarningWash
            case .danger: return .qDangerWash
            }
        }

        public var glyphColor: NSColor {
            switch self {
            case .neutral: return .qInk2
            case .info: return .qInfo
            case .success: return .qSuccess
            case .warning: return .qWarning
            case .danger: return .qDanger
            }
        }

        /// The glyph a banner of this kind shows unless it names its own.
        public var defaultSymbol: String {
            switch self {
            case .neutral: return Quire.Icon.info
            case .info: return Quire.Icon.info
            case .success: return Quire.Icon.success
            case .warning: return Quire.Icon.warning
            case .danger: return Quire.Icon.error
            }
        }
    }
}
