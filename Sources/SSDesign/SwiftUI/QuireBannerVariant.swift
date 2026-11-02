import SwiftUI

/// The semantic banner variants of spec §5.38: a wash, a glyph colour and a default glyph each.
public enum QuireBannerVariant: String, CaseIterable, Sendable {
    /// `fill`, glyph `ink2`: neutral information (remote images hidden).
    case neutral
    /// `infoWash`, glyph `info`: guidance (the OAuth notice, demo mode, seven accounts).
    case info
    /// `successWash`, glyph `success`.
    case success
    /// `warningWash`, glyph `warning`.
    case warning
    /// `dangerWash`, glyph `danger`: failures (couldn't add the account, couldn't save).
    case danger

    /// The banner's face. `fill` is a wash over the surface beneath; the others are opaque.
    public var face: QuireFill {
        switch self {
        case .neutral: return QuireFill(wash: .fill)
        case .info: return QuireFill(.infoWash)
        case .success: return QuireFill(.successWash)
        case .warning: return QuireFill(.warningWash)
        case .danger: return QuireFill(.dangerWash)
        }
    }

    public var glyphColor: QuireColorToken {
        switch self {
        case .neutral: return .ink2
        case .info: return .info
        case .success: return .success
        case .warning: return .warning
        case .danger: return .danger
        }
    }

    /// The glyph a banner of this kind shows unless it names its own; semantic colours always arrive with a
    /// glyph and words (spec §4.1).
    public var defaultGlyph: String {
        switch self {
        case .neutral, .info: return Quire.Icon.info
        case .success: return Quire.Icon.success
        case .warning: return Quire.Icon.warning
        case .danger: return Quire.Icon.error
        }
    }
}
