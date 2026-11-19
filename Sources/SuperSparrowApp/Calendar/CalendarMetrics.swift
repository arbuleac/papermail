import AppKit
import SSCore
import SSDesign

/// The calendar's geometry from `layout.calendarPane` (spec §5.54): the fit's constants and the parts both timelines
/// share. Nothing here is a number of its own; every one comes from the tokens.
enum CalendarMetrics {
    typealias Pane = Quire.Layout.CalendarPane

    /// The fit's constants. An all-day row is a chip and the gap under it; the band adds its top and bottom padding,
    /// less the last row's gap.
    static let fit = CalendarFit.Metrics(
        coreHours: Int(Pane.coreStartHour)..<Int(Pane.coreEndHour),
        foldHeight: Double(Pane.foldHeight),
        minHourHeight: Double(Pane.hourMin),
        maxHourHeight: Double(Pane.hourMax),
        minEventHeight: Double(Pane.eventMinHeight),
        maxColumns: Int(Pane.maxSideBySide),
        foldedDayWidth: Double(Pane.foldedDayWidth),
        allDayRowHeight: Double(Pane.allDayRowHeight + Pane.allDayRowGap),
        allDayBandPadding: Double(Pane.allDayPadTop + Pane.allDayPadBottom - Pane.allDayRowGap),
        maxAllDayRows: Int(Pane.allDayRowsMax)
    )

    /// The event being handled is a mouse-down: the window is asking whether a click may take focus, which a timeline
    /// and the day cells refuse (§5.54, “The list keeps the keyboard”), as Quire's controls do.
    static func isMouseDown(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
    }

    /// The top of the column's timeline: under the header and the day cells.
    static var columnTimelineTop: CGFloat { Pane.headerHeight + Pane.dayCellsHeight }

    /// The top of the week's timeline: under the header and the day headings.
    static var weekTimelineTop: CGFloat { Pane.headerHeight + Pane.weekHeadsHeight }

    /// The width the column's fit lays its day across: the column less its hour gutter and trailing pad.
    static var columnFitWidth: CGFloat { Pane.columnWidth - Pane.hourGutterColumn - Pane.trailingPadColumn }

    /// The x and width of item `column` of `count` side by side across a day at `x`, `width` wide: 2 pt in from the
    /// day's sides and 2 pt apart (`eventInsetX`, `eventGap`).
    static func slot(column: Int, of count: Int, dayX: CGFloat, dayWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let count = max(1, count)
        let inner = max(0, dayWidth - 2 * Pane.eventInsetX)
        let width = max(0, (inner - CGFloat(count - 1) * Pane.eventGap) / CGFloat(count))
        let index = CGFloat(min(column, count - 1))
        return (dayX + Pane.eventInsetX + index * (width + Pane.eventGap), width)
    }

    /// A slot's face: 1 pt less above and below (`eventInsetY`).
    static func face(x: CGFloat, width: CGFloat, top: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: x, y: top + Pane.eventInsetY, width: width, height: max(0, height - 2 * Pane.eventInsetY))
    }
}

/// Text roles in the calendar's own forms: a role's attributes that wrap (an event's title, a card's), and its italic
/// (a pencilled title).
@MainActor
enum CalendarType {
    /// `role` in `color`, wrapping onto as many lines as the rect it is drawn in holds, the last one tail-truncated.
    static func wrapping(_ text: String, role: QuireFont.Role, color: NSColor, italic: Bool = false,
                         firstLineIndent: CGFloat = 0) -> NSAttributedString {
        var attributes = QuireFont.attributes(role, color: color)
        let style = (QuireFont.paragraphStyle(role).mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.firstLineHeadIndent = firstLineIndent
        attributes[.paragraphStyle] = style
        if italic, let font = attributes[.font] as? NSFont { attributes[.font] = italicized(font) }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// One line of `role`, tail-truncated.
    static func line(_ text: String, role: QuireFont.Role, color: NSColor, italic: Bool = false) -> NSAttributedString {
        guard italic else { return QuireFont.attributedString(text, role: role, color: color) }
        var attributes = QuireFont.attributes(role, color: color)
        if let font = attributes[.font] as? NSFont { attributes[.font] = italicized(font) }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static var italics: [NSFont: NSFont] = [:]

    static func italicized(_ font: NSFont) -> NSFont {
        if let cached = italics[font] { return cached }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        let italic = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        italics[font] = italic
        return italic
    }

    /// Whole lines of `role` that fit `height`.
    static func lines(of role: QuireFont.Role, in height: CGFloat) -> Int {
        max(0, Int((height / role.lineHeight).rounded(.down)))
    }

    /// The width `text` takes on one line.
    static func width(of text: NSAttributedString) -> CGFloat {
        ceil(text.size().width)
    }
}
