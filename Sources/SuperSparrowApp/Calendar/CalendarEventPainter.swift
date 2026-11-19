import AppKit
import SSCore
import SSDesign

/// Which timeline an event is drawn in: the column says more on a short event (its start time) and adds a place line;
/// the week, with seven days across, keeps to the title.
enum CalendarTimelineStyle: Sendable {
    case column
    case week

    var gutter: CGFloat {
        self == .column ? Quire.Layout.CalendarPane.hourGutterColumn : Quire.Layout.CalendarPane.hourGutterWeek
    }

    var trailingPad: CGFloat {
        self == .column ? Quire.Layout.CalendarPane.trailingPadColumn : Quire.Layout.CalendarPane.trailingPadWeek
    }
}

/// How one event's face looks now (spec §5.54, “Events” and the state table).
struct CalendarEventLook {
    enum Interaction { case rest, hover, pressed }

    var event: CalendarEvent
    var face: NSRect
    /// The slot's height (the face's and the 1 pt above and below): what decides one line or several.
    var slotHeight: CGFloat
    /// Not answered: the provider's invitation the user has not answered, or the selected mail's drawn from the mail.
    var isPencilled: Bool
    /// The selected conversation's: the margin rule in place of the edge.
    var isSelected: Bool
    var isWindowKey: Bool
    var interaction: Interaction
    /// The overlap's bands, in the view's coordinates (y and height).
    var hatches: [(y: CGFloat, height: CGFloat)]
    var ink: NSColor
    /// Alone across its slot: room for the place line in the column.
    var isAlone: Bool
    var moreCount: Int
    /// The width Join takes at the face's top-trailing corner; 0 without it.
    var joinWidth: CGFloat
    var style: CalendarTimelineStyle
    var timeText: String
    var startText: String
    var place: (glyph: String, text: String)?
}

/// Draws an event's face, edge, hatch, outline and words in `draw(_:)`, where every token resolves in the view's
/// appearance. Shared by the column and the week, so the two never drift apart.
@MainActor
enum CalendarEventPainter {
    typealias Pane = Quire.Layout.CalendarPane

    static func draw(_ look: CalendarEventLook) {
        let face = look.face
        guard face.width > 0, face.height > 0 else { return }
        let shape = QuireDraw.roundedRect(face, radius: Pane.eventRadius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // The face: the ink's tint over `sheet`, opaque; a pencilled one is `paper`. Hover and pressed washes go over it.
        if look.isPencilled {
            NSColor.qPaper.setFill()
            face.fill()
        } else {
            NSColor.qSheet.setFill()
            face.fill()
            look.ink.withAlphaComponent(Pane.eventTintAlpha).setFill()
            face.fill(using: .sourceOver)
        }
        switch look.interaction {
        case .hover:
            NSColor.qHover.setFill()
            face.fill(using: .sourceOver)
        case .pressed:
            NSColor.qPressed.setFill()
            face.fill(using: .sourceOver)
        case .rest:
            break
        }
        drawHatch(look)
        // The edge down the leading side, inside the radius: the margin rule for the selected conversation's.
        let edge = NSRect(x: face.minX, y: face.minY, width: Pane.eventEdge, height: face.height)
        if look.isSelected {
            (look.isWindowKey ? NSColor.qSelRule : NSColor.qSelRuleIdle).setFill()
            edge.fill()
        } else if !look.isPencilled {
            look.ink.setFill()
            edge.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        if look.isPencilled {
            dashedOutline(face, color: .qRuleStrong)
        } else if look.event.response == .tentative {
            dashedOutline(face, color: look.ink)
        }
        drawWords(look)
        if look.moreCount > 0 { drawMore(look.moreCount, in: face) }
    }

    /// Diagonal lines rising toward the trailing edge, 1 pt every 5 pt, over the time the invitation shares.
    private static func drawHatch(_ look: CalendarEventLook) {
        guard !look.hatches.isEmpty else { return }
        let face = look.face
        let pitch = Pane.hatchPitch
        NSColor.qWarning.setStroke()
        for band in look.hatches {
            let rect = NSRect(x: face.minX, y: band.y, width: face.width, height: band.height).intersection(face)
            guard !rect.isEmpty else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            let path = NSBezierPath()
            path.lineWidth = Pane.hatchLine
            // Flipped: a line from the bottom left to the top right rises toward the trailing edge.
            var x = rect.minX - rect.height
            while x < rect.maxX {
                path.move(to: NSPoint(x: x, y: rect.maxY))
                path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
                x += pitch
            }
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A 1 pt dashed outline inside the face (`pencilDash`).
    private static func dashedOutline(_ face: NSRect, color: NSColor) {
        let inset = face.insetBy(dx: 0.5, dy: 0.5)
        let path = QuireDraw.roundedRect(inset, radius: Pane.eventRadius - 0.5)
        path.lineWidth = 1
        path.setLineDash(Pane.pencilDash, count: Pane.pencilDash.count, phase: 0)
        color.setStroke()
        path.stroke()
    }

    /// The glyph before the title: being created, refused, or set aside for a mail.
    static func titleGlyph(for event: CalendarEvent) -> (name: String, color: NSColor?)? {
        switch event.sync {
        case .creating: return (Quire.Icon.pending, nil)
        case .failed: return (Quire.Icon.failed, .qDanger)
        case .synced, .deleting: break
        }
        return event.isSetAside ? (Quire.Icon.fromThisMail, nil) : nil
    }

    private static func drawWords(_ look: CalendarEventLook) {
        let face = look.face
        let lit = look.interaction != .rest
        let quiet: NSColor = lit ? .qInk : .qInk2
        let titleColor: NSColor = look.isPencilled ? (lit ? .qInk : .qInk2) : .qInk
        let title = look.event.title.isEmpty ? CalendarText.noTitle : look.event.title
        let left = face.minX + Pane.eventPadLeading
        var right = face.maxX - Pane.eventPadTrailing
        if look.joinWidth > 0 { right = face.maxX - look.joinWidth - Pane.eventGlyphGap }
        let width = right - left
        guard width > 4 else { return }
        let glyph = titleGlyph(for: look.event)
        let glyphRoom = glyph == nil ? 0 : Pane.eventGlyph + Pane.eventGlyphGap

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: face).addClip()
        // Two lines need the time's line and one of the title's under the top padding, in the slot's gap: the token, or
        // more where Text size makes the lines taller (§4.15). Below that the title would be clipped away entirely.
        let twoLines = Pane.eventPadTop + QuireFont.Role.meta.lineHeight + QuireFont.Role.label.lineHeight + Pane.eventGap
        if look.slotHeight < max(Pane.eventOneLineBelow, twoLines) {
            // One line: in the column the start time then the title; in the week the title alone.
            let lineRole = QuireFont.Role.metaMedium
            let lineHeight = lineRole.lineHeight
            let y = face.minY + max(0, ((face.height - lineHeight) / 2).rounded(.down))
            var x = left
            if look.style == .column {
                let time = QuireFont.attributedString(look.startText, role: .meta, color: quiet)
                let timeWidth = CalendarType.width(of: time)
                time.draw(with: NSRect(x: x, y: y, width: max(0, right - x), height: lineHeight),
                          options: QuireFont.drawingOptions, context: nil)
                x += timeWidth + Pane.eventGlyphGap
            }
            if let glyph, x + Pane.eventGlyph < right {
                QuireSymbol.draw(glyph.name, size: .custom(Pane.eventGlyph), color: glyph.color ?? quiet,
                                 centredIn: NSRect(x: x, y: y, width: Pane.eventGlyph, height: lineHeight))
                x += glyphRoom
            }
            if x < right {
                let text = CalendarType.line(title, role: lineRole, color: titleColor, italic: look.isPencilled)
                text.draw(with: NSRect(x: x, y: y, width: right - x, height: lineHeight), options: QuireFont.drawingOptions,
                          context: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        // Several lines: the time, the title wrapping, and in the column a place line for an event alone with room.
        var y = face.minY + Pane.eventPadTop
        let timeRole = QuireFont.Role.meta
        let time = QuireFont.attributedString(look.timeText, role: timeRole, color: quiet)
        time.draw(with: NSRect(x: left, y: y, width: width, height: timeRole.lineHeight), options: QuireFont.drawingOptions,
                  context: nil)
        y += timeRole.lineHeight
        let showsPlace = look.style == .column && look.isAlone && look.place != nil && look.slotHeight >= Pane.eventPlaceLineMin
        let placeHeight = showsPlace ? QuireFont.Role.meta.lineHeight : 0
        let titleRole = QuireFont.Role.label
        let lines = CalendarType.lines(of: titleRole, in: face.maxY - y - placeHeight)
        var titleBottom = y
        if lines > 0 {
            if let glyph {
                QuireSymbol.draw(glyph.name, size: .custom(Pane.eventGlyph), color: glyph.color ?? quiet,
                                 centredIn: NSRect(x: left, y: y, width: Pane.eventGlyph, height: titleRole.lineHeight))
            }
            let text = CalendarType.wrapping(title, role: titleRole, color: titleColor, italic: look.isPencilled,
                                             firstLineIndent: glyphRoom)
            let box = NSRect(x: left, y: y, width: width, height: CGFloat(lines) * titleRole.lineHeight)
            let used = text.boundingRect(with: box.size, options: QuireFont.drawingOptions, context: nil).height
            text.draw(with: box, options: QuireFont.drawingOptions, context: nil)
            titleBottom = y + min(box.height, ceil(used / titleRole.lineHeight) * titleRole.lineHeight)
        }
        if showsPlace, let place = look.place, titleBottom + placeHeight <= face.maxY {
            let lineHeight = QuireFont.Role.meta.lineHeight
            QuireSymbol.draw(place.glyph, size: .custom(Pane.eventGlyph), color: quiet,
                             centredIn: NSRect(x: left, y: titleBottom, width: Pane.eventGlyph, height: lineHeight))
            let x = left + Pane.eventGlyph + Pane.eventGlyphGap
            QuireFont.attributedString(place.text, role: .meta, color: quiet)
                .draw(with: NSRect(x: x, y: titleBottom, width: max(0, right - x), height: lineHeight),
                      options: QuireFont.drawingOptions, context: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The “+1” tag on the third event side by side: 16 pt, `raised`, a 1 pt `ruleStrong` edge, `tag` `ink`, 2 pt in
    /// from the face's top-trailing corner.
    static func moreTagRect(_ count: Int, in face: NSRect) -> NSRect {
        let text = QuireFont.attributedString("+\(count)", role: .tag, color: .qInk)
        let width = CalendarType.width(of: text) + 2 * Quire.Layout.Tag.padX
        let inset = Pane.eventInsetX
        return NSRect(x: face.maxX - inset - width, y: face.minY + inset, width: width, height: Quire.Layout.Tag.height)
    }

    private static func drawMore(_ count: Int, in face: NSRect) {
        let rect = moreTagRect(count, in: face)
        QuireDraw.fill(rect, radius: Quire.Radius.xs, .qRaised)
        QuireDraw.strokeInside(rect, radius: Quire.Radius.xs, width: 1, .qRuleStrong)
        let text = QuireFont.attributedString("+\(count)", role: .tag, color: .qInk)
        let lineHeight = QuireFont.Role.tag.lineHeight
        let width = CalendarType.width(of: text)
        text.draw(with: NSRect(x: rect.midX - width / 2, y: rect.minY + (rect.height - lineHeight) / 2, width: width + 1,
                               height: lineHeight), options: QuireFont.drawingOptions, context: nil)
    }
}
