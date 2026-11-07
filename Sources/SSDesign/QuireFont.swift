import AppKit
import CoreText

/// Quire's typography runtime (spec §4.4, §8.2): fonts, exact line heights and the New York coverage test.
/// Every font comes from a `Role`; nothing asks for a bare size or weight.
///
/// The Font setting (`QuireEnvironment.typeface`) is applied here, once, for every caller: under SF Pro a New
/// York role is replaced by its sans twin before anything is looked up. The caches are keyed by the role
/// actually set, never by the role asked for, so after a switch no cache can hand back the other face.
public enum QuireFont {
    private struct FontKey: Hashable {
        let role: Role
        let unread: Bool
    }

    private struct MonogramKey: Hashable {
        let role: Role
        let size: CGFloat
    }

    private static let fonts = LockedCache<FontKey, NSFont>()
    private static let styles = LockedCache<Role, NSParagraphStyle>()
    private static let offsets = LockedCache<FontKey, CGFloat>()
    private static let monograms = LockedCache<MonogramKey, NSFont>()

    // MARK: Fonts

    /// The role's font under the Font setting, cached. `unread` switches to the role's `unreadWeight` where it
    /// has one.
    public static func font(_ role: Role, unread: Bool = false) -> NSFont {
        font(setIn: resolvedRole(role), unread: unread)
    }

    /// The font for `text` in `role`: the role's sans twin under the SF Pro font, or when New York cannot set
    /// every letter of it (spec §4.4, script fallback). Twins keep the line height, so metrics never change.
    public static func font(_ role: Role, for text: String, unread: Bool = false) -> NSFont {
        font(setIn: resolvedRole(role, for: text), unread: unread)
    }

    /// Exactly `role`'s font: the typeface has already been applied.
    private static func font(setIn role: Role, unread: Bool) -> NSFont {
        let unread = unread && role.spec.unreadWeight != nil
        return fonts.value(for: FontKey(role: role, unread: unread)) {
            let spec = role.spec
            return make(spec, size: spec.pointSize, weight: unread ? spec.unreadWeight! : spec.weight)
        }
    }

    /// The role `role` is set in under the current Font setting: its sans twin under SF Pro when it is a New
    /// York role, otherwise `role` itself.
    public static func resolvedRole(_ role: Role) -> Role {
        resolvedRole(role, typeface: QuireEnvironment.typeface)
    }

    /// `resolvedRole(_:)` for a given typeface, for views that track the setting themselves (SwiftUI).
    public static func resolvedRole(_ role: Role, typeface: Typeface) -> Role {
        guard typeface == .sfPro, role.spec.family == .serif, let twin = role.spec.twin else { return role }
        return twin
    }

    /// `role`, or its twin under the SF Pro font or when `text` has letters New York does not cover.
    public static func resolvedRole(_ role: Role, for text: String) -> Role {
        guard role.spec.family == .serif, let twin = role.spec.twin else { return role }
        if QuireEnvironment.typeface == .sfPro || !newYorkCovers(text) { return twin }
        return role
    }

    /// Initials for an avatar or rail face of `diameter` points: New York Semibold at 0.42 × the diameter, or
    /// under the SF Pro font `monogramSans` at its own ratio, rounded to the half point, never below the
    /// role's minimum (spec §4.3, §5.29).
    public static func monogramFont(diameter: CGFloat, typeface: Typeface = QuireEnvironment.typeface) -> NSFont {
        let role = resolvedRole(.monogram, typeface: typeface)
        return monogramFont(role, size: monogramSize(diameter: diameter, role: role))
    }

    public static func monogramSize(diameter: CGFloat, typeface: Typeface = QuireEnvironment.typeface) -> CGFloat {
        monogramSize(diameter: diameter, role: resolvedRole(.monogram, typeface: typeface))
    }

    private static func monogramSize(diameter: CGFloat, role: Role) -> CGFloat {
        let spec = role.spec
        let ratio = spec.sizeRatio ?? 0.42
        return max(spec.minSize ?? 0, (diameter * ratio * 2).rounded() / 2)
    }

    /// A monogram size the layout names for New York (the rail's 14 / 12 pt, the quick reply's 11 / 10 pt) in
    /// the current face: under SF Pro scaled by the twin's ratio to the serif's, to the half point and never
    /// below the twin's minimum, so the letters keep their optical size (spec §5.29).
    public static func monogramSize(named size: CGFloat, typeface: Typeface = QuireEnvironment.typeface) -> CGFloat {
        let role = resolvedRole(.monogram, typeface: typeface)
        guard role != .monogram, let serif = Role.monogram.spec.sizeRatio, let ratio = role.spec.sizeRatio, serif > 0 else { return size }
        return max(role.spec.minSize ?? 0, (size * ratio / serif * 2).rounded() / 2)
    }

    /// The monogram face at `size` points, for account faces whose sizes come from the layout.
    public static func monogramFont(size: CGFloat, typeface: Typeface = QuireEnvironment.typeface) -> NSFont {
        monogramFont(resolvedRole(.monogram, typeface: typeface), size: size)
    }

    private static func monogramFont(_ role: Role, size: CGFloat) -> NSFont {
        monograms.value(for: MonogramKey(role: role, size: size)) {
            make(role.spec, size: size, weight: role.spec.weight)
        }
    }

    /// The §8.2 recipe: SF Pro at the weight, then the serif or rounded design, italic and tabular digits.
    static func make(_ spec: Spec, size: CGFloat, weight cssWeight: CGFloat) -> NSFont {
        let weight = fontWeight(cssWeight)
        if spec.family == .mono {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        var d = base.fontDescriptor
        switch spec.family {
        case .serif: d = d.withDesign(.serif) ?? d
        case .rounded: d = d.withDesign(.rounded) ?? d
        case .sf, .mono: break
        }
        if spec.italic {
            // Union, not replace: replacing the symbolic traits can drop the weight the system font carries.
            d = d.withSymbolicTraits(d.symbolicTraits.union(.italic))
        }
        if spec.tabular {
            d = d.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        }
        return NSFont(descriptor: d, size: size) ?? base
    }

    /// CSS weight to AppKit weight. Quire uses 400, 500 and 600; the rest of the ladder keeps the mapping total.
    public static func fontWeight(_ css: CGFloat) -> NSFont.Weight {
        switch css {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    // MARK: Paragraphs and attributes

    /// Exact line height, single line, tail truncation without tightening, natural writing direction with the
    /// UI's leading alignment (spec §4.4, §8.2). Shared and immutable, so it is cached per role.
    public static func paragraphStyle(_ role: Role) -> NSParagraphStyle {
        styles.value(for: role) {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = role.lineHeight
            style.maximumLineHeight = role.lineHeight
            style.lineBreakMode = .byTruncatingTail
            style.allowsDefaultTighteningForTruncation = false
            style.baseWritingDirection = .natural
            // Leading in the UI's direction, not the text's: an Arabic subject reads right to left but stays
            // flush with the column (spec §4.4, bidirectional text).
            style.alignment = uiIsRightToLeft ? .right : .left
            return style
        }
    }

    /// Centres the font's own line in the role's line box: (role line height − font line height) / 2, the
    /// font line height being what NSLayoutManager would give it (spec §4.4). The reader's CSS line-height
    /// centres the same way, so AppKit and the reader agree to the point.
    public static func baselineOffset(_ role: Role, unread: Bool = false) -> CGFloat {
        let role = resolvedRole(role)
        let unread = unread && role.spec.unreadWeight != nil
        return offsets.value(for: FontKey(role: role, unread: unread)) {
            baselineOffset(for: font(setIn: role, unread: unread), lineHeight: role.lineHeight)
        }
    }

    static func baselineOffset(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
        (lineHeight - NSLayoutManager().defaultLineHeight(for: font)) / 2
    }

    /// String attributes for `role` in `color`, under the Font setting (the twin's tracking with its font).
    /// Tracking is applied as `.kern` only when the role has one, because an explicit 0 kern turns off the
    /// font's own kerning.
    public static func attributes(_ role: Role, color: NSColor, unread: Bool = false) -> [NSAttributedString.Key: Any] {
        let role = resolvedRole(role)
        var a: [NSAttributedString.Key: Any] = [
            .font: font(setIn: role, unread: unread),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(role),
            .baselineOffset: baselineOffset(role, unread: unread),
        ]
        if role.tracking != 0 { a[.kern] = role.tracking }
        return a
    }

    /// `text` set in `role`: the twin under the SF Pro font or when New York cannot set it, uppercased for
    /// uppercase roles, with the role's attributes. This is the one call row and header builders need.
    public static func attributedString(_ text: String, role: Role, color: NSColor, unread: Bool = false,
                                        locale: Locale = .current) -> NSAttributedString {
        let used = resolvedRole(role, for: text)
        let string = used.uppercase ? text.uppercased(with: locale) : text
        return NSAttributedString(string: string, attributes: attributes(used, color: color, unread: unread))
    }

    // MARK: Laying out

    /// Prepares a TextKit 1 layout manager for Quire text. With `usesFontLeading` on (the default) TextKit adds
    /// the leading of a cascade font on top of the paragraph's maximum line height: Thai set through SF Pro
    /// falls back to Thonburi and grows every line by its 0.87 pt leading, so a row would no longer be 68 pt.
    /// String drawing, `NSTextField` and TextKit 2 already keep the line height; RowMetricsTests covers all.
    public static func configure(_ layoutManager: NSLayoutManager) {
        layoutManager.usesFontLeading = false
    }

    /// Options for `NSAttributedString.draw(with:options:)` and `boundingRect(with:options:)`: line-fragment
    /// geometry, tail truncation on the single line, and no font leading (see `configure(_:)`).
    public static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]

    // MARK: New York coverage

    /// The letters New York has glyphs for, read once from the system serif font (spec §4.4).
    private static let newYorkCharacters: CharacterSet = {
        let serif = make(Role.reading.spec, size: 15, weight: 400)
        return CTFontCopyCharacterSet(serif as CTFont) as CharacterSet
    }()

    /// True when every letter of `string` is in New York. Only letters count: digits, punctuation, symbols
    /// and emoji come from the cascade in either family, so they never force the twin.
    public static func newYorkCovers(_ string: String) -> Bool {
        for scalar in string.unicodeScalars where scalar.properties.isAlphabetic {
            if !newYorkCharacters.contains(scalar) { return false }
        }
        return true
    }

    private static let uiIsRightToLeft: Bool = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: language).characterDirection == .rightToLeft
    }()
}
