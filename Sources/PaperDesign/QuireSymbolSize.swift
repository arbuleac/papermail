import AppKit

/// A symbol's point size and weight. The presets are the defaults of spec §4.11 (`layout.iconSize`); the
/// named exceptions (compose nib, masthead chevron, dismiss marks) use `custom` with their component metric.
public struct QuireSymbolSize: Equatable, Sendable {
    public let pointSize: CGFloat
    public let weight: NSFont.Weight

    public init(pointSize: CGFloat, weight: NSFont.Weight = .regular) {
        self.pointSize = pointSize
        self.weight = weight
    }

    /// Window-level icon buttons: reader header actions, the composer bar, the rail's Add and Settings.
    public static let window = QuireSymbolSize(pointSize: Quire.Layout.IconSize.window)
    /// Inside text buttons, chips, banners, tool rows and format toggles.
    public static let inText = QuireSymbolSize(pointSize: Quire.Layout.IconSize.inText)
    /// Rows and the sync line, Semibold so the small size holds up.
    public static let row = QuireSymbolSize(pointSize: Quire.Layout.IconSize.row, weight: .semibold)
    /// The rail's All Inboxes glyph.
    public static let rail = QuireSymbolSize(pointSize: Quire.Layout.IconSize.rail)

    public static func custom(_ pointSize: CGFloat, weight: NSFont.Weight = .regular) -> QuireSymbolSize {
        QuireSymbolSize(pointSize: pointSize, weight: weight)
    }
}
