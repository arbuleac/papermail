import SwiftUI

/// The three button sizes of spec §5.24 (`layout.button`). Settings uses `.small`.
public enum QuireButtonSize: String, CaseIterable, Sendable {
    case small
    case regular
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

    public var radius: CGFloat {
        switch self {
        case .small: return Quire.Layout.Button.Small.radius
        case .regular: return Quire.Layout.Button.Regular.radius
        case .large: return Quire.Layout.Button.Large.radius
        }
    }

    /// The label role of secondary, ghost and link buttons.
    public var font: QuireFont.Role {
        switch self {
        case .small: return QuireButtonSize.role(Quire.Layout.Button.Small.font)
        case .regular: return QuireButtonSize.role(Quire.Layout.Button.Regular.font)
        case .large: return QuireButtonSize.role(Quire.Layout.Button.Large.font)
        }
    }

    /// The label role of primary and destructive buttons.
    public var fontStrong: QuireFont.Role {
        switch self {
        case .small: return QuireButtonSize.role(Quire.Layout.Button.Small.fontStrong)
        case .regular: return QuireButtonSize.role(Quire.Layout.Button.Regular.fontStrong)
        case .large: return QuireButtonSize.role(Quire.Layout.Button.Large.fontStrong)
        }
    }

    /// The glyph inside a text button.
    public var glyph: CGFloat {
        switch self {
        case .small: return Quire.Layout.Button.Small.glyph
        case .regular: return Quire.Layout.Button.Regular.glyph
        case .large: return Quire.Layout.Button.Large.glyph
        }
    }

    /// The side of an icon button of this size (`button.icon`: 22 / 24 / 28).
    public var iconSide: CGFloat { Quire.Layout.Button.icon[index] }

    /// The corner radius of an icon button of this size (`button.iconRadius`: 5 / 5 / 6).
    public var iconRadius: CGFloat { Quire.Layout.Button.iconRadius[index] }

    private var index: Int {
        switch self {
        case .small: return 0
        case .regular: return 1
        case .large: return 2
        }
    }

    /// tokens.json names button roles by string; the generator guarantees each names a typography role, and
    /// `ButtonStyleTests` asserts every one resolves.
    static func role(_ name: String) -> QuireFont.Role {
        QuireFont.Role(rawValue: name) ?? .body
    }
}
