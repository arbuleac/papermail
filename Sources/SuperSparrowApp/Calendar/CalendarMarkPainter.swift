import AppKit
import SSCore
import SSDesign

/// Draws the marks of a timeline (spec §5.54, “Marks”), its folds, the now line and a drop's ghost, in `draw(_:)`.
@MainActor
enum CalendarMarkPainter {
    typealias Pane = Quire.Layout.CalendarPane

    // MARK: Marks

    /// The chip's words: the subject for Later and Send Later, “From this mail · 15:00” for a mail's time.
    static func chipText(for mark: CalendarMark, text: CalendarText) -> NSAttributedString {
        switch mark.kind {
        case .mailTime:
            return QuireFont.attributedString("From this mail · " + text.time(mark.start), role: .metaStrong, color: .qAccent)
        case .later, .sendLater:
            return QuireFont.attributedString(mark.title.isEmpty ? "No subject" : mark.title, role: .meta, color: .qInk2)
        }
    }

    static func glyph(for mark: CalendarMark) -> String {
        switch mark.kind {
        case .later: return Quire.Icon.later
        case .sendLater: return Quire.Icon.send
        case .mailTime: return Quire.Icon.fromThisMail
        }
    }

    /// The keycap a mail's time ends in: B sets the time aside there.
    static let blockKey = "B"

    static func chipWidth(for mark: CalendarMark, text: CalendarText) -> CGFloat {
        var width = Pane.markChipPadLeading + Pane.eventGlyph + Pane.markChipGap + CalendarType.width(of: chipText(for: mark, text: text))
        if mark.isMailTime {
            width += Pane.markChipGap + QuireKeycap.size(for: blockKey, style: .inField).width
        }
        return width + Pane.markChipPadTrailing
    }

    static func draw(_ mark: CalendarTimelineView.PlacedMark, text: CalendarText, hovered: Bool, pressed: Bool) {
        let isMail = mark.mark.isMailTime
        // The line across the day: 1 pt dashed `ink3`, or 2 pt dashed `accent` for a time the mail names.
        let path = NSBezierPath()
        let width = isMail ? Pane.mentionLine : Pane.markLine
        let y = mark.lineY + (isMail ? 0 : 0.5)
        path.move(to: NSPoint(x: mark.lineX.lowerBound, y: y))
        path.line(to: NSPoint(x: mark.lineX.upperBound, y: y))
        path.lineWidth = width
        path.setLineDash(Pane.markDash, count: Pane.markDash.count, phase: 0)
        (isMail ? NSColor.qAccent : NSColor.qInk3).setStroke()
        path.stroke()

        // The chip: a pill of `paper` with a 1 pt edge (`accent` for the mail's time), washed on hover and press.
        let chip = mark.chip
        guard chip.width > Pane.markChipPadLeading + Pane.eventGlyph else { return }
        let radius = chip.height / 2
        QuireDraw.fill(chip, radius: radius, .qPaper)
        if pressed { QuireDraw.fill(chip, radius: radius, .qPressed) } else if hovered { QuireDraw.fill(chip, radius: radius, .qHover) }
        QuireDraw.strokeInside(chip, radius: radius, width: 1, isMail ? .qAccent : .qRuleStrong)
        NSGraphicsContext.saveGraphicsState()
        QuireDraw.roundedRect(chip, radius: radius).addClip()
        var x = chip.minX + Pane.markChipPadLeading
        let lineHeight = QuireFont.Role.meta.lineHeight
        let glyphColor: NSColor = isMail ? .qAccent : (hovered || pressed ? .qInk : .qInk2)
        QuireSymbol.draw(glyph(for: mark.mark), size: .custom(Pane.eventGlyph), color: glyphColor,
                         centredIn: NSRect(x: x, y: chip.minY, width: Pane.eventGlyph, height: chip.height))
        x += Pane.eventGlyph + Pane.markChipGap
        let words = chipText(for: mark.mark, text: text)
        var end = chip.maxX - Pane.markChipPadTrailing
        if isMail {
            let key = QuireKeycap.size(for: blockKey, style: .inField)
            let keyRect = NSRect(x: end - key.width, y: chip.minY + (chip.height - key.height) / 2, width: key.width, height: key.height)
            if keyRect.minX > x { QuireKeycap.draw(blockKey, style: .inField, in: keyRect) }
            end = keyRect.minX - Pane.markChipGap
        }
        if end > x {
            words.draw(with: NSRect(x: x, y: chip.minY + (chip.height - lineHeight) / 2, width: end - x, height: lineHeight),
                       options: QuireFont.drawingOptions, context: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Title case, as tooltips are (spec §4.13).
    static func toolTip(for mark: CalendarMark, text: CalendarText) -> String {
        switch mark.kind {
        case .later: return "Comes Back from Later at " + text.time(mark.start)
        case .sendLater: return "Sends at " + text.time(mark.start) + " While SuperSparrow Is Open"
        case .mailTime: return "Block 30 Minutes for This Mail  B"
        }
    }

    // MARK: Folds

    /// A run of closed hours: a band of `canvas` and its range in `meta` `ink3`, no edges. The band alone says the hours
    /// are folded; dashed edges doubled the hairline over the timeline's top and every hour line beside a fold.
    static func drawFold(_ rect: NSRect, label: String, labelX: CGFloat) {
        NSColor.qCanvas.setFill()
        rect.fill()
        let lineHeight = QuireFont.Role.meta.lineHeight
        QuireFont.attributedString(label, role: .meta, color: .qInk3)
            .draw(with: NSRect(x: labelX, y: rect.midY - lineHeight / 2, width: max(0, rect.maxX - labelX), height: lineHeight),
                  options: QuireFont.drawingOptions, context: nil)
    }

    // MARK: Now

    /// A 2 pt `ink` line across today, an 8 pt dot on its leading end, and the time in the gutter on `paper`.
    static func drawNow(y: CGFloat, dayX: CGFloat, dayWidth: CGFloat, gutter: CGFloat, label: String) {
        NSColor.qInk.setFill()
        NSRect(x: dayX, y: y - Pane.nowLineWidth / 2, width: dayWidth, height: Pane.nowLineWidth).fill()
        QuireDraw.fillCircle(NSRect(x: dayX - Pane.nowDot / 2, y: y - Pane.nowDot / 2, width: Pane.nowDot, height: Pane.nowDot), .qInk)
        let text = QuireFont.attributedString(label, role: .metaStrong, color: .qInk)
        let width = CalendarType.width(of: text)
        let lineHeight = QuireFont.Role.metaStrong.lineHeight
        let rect = NSRect(x: gutter - Pane.hourLabelGap - width, y: y - lineHeight / 2, width: width + 1, height: lineHeight)
        NSColor.qPaper.setFill()
        rect.insetBy(dx: -2, dy: 0).fill()
        text.draw(with: rect, options: QuireFont.drawingOptions, context: nil)
    }

    // MARK: Ghost

    /// Where a dropped row would go: `accentWash`, a 2 pt dashed `focus` edge, “Thu 13:30 - 14:00” in `metaStrong`
    /// `accent`.
    static func drawGhost(_ face: NSRect, label: String) {
        QuireDraw.fill(face, radius: Pane.eventRadius, .qAccentWash)
        let inset = face.insetBy(dx: Pane.ghostEdge / 2, dy: Pane.ghostEdge / 2)
        let path = QuireDraw.roundedRect(inset, radius: Pane.eventRadius - Pane.ghostEdge / 2)
        path.lineWidth = Pane.ghostEdge
        path.setLineDash(Pane.dropDash, count: Pane.dropDash.count, phase: 0)
        NSColor.qFocus.setStroke()
        path.stroke()
        let lineHeight = QuireFont.Role.metaStrong.lineHeight
        QuireFont.attributedString(label, role: .metaStrong, color: .qAccent)
            .draw(with: NSRect(x: face.minX + Pane.eventPadLeading, y: face.minY + Pane.eventPadTop,
                               width: max(0, face.width - Pane.eventPadLeading - Pane.eventPadTrailing),
                               height: min(lineHeight, face.height)), options: QuireFont.drawingOptions, context: nil)
    }
}
