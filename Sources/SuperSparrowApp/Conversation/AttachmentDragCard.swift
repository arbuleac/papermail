import AppKit
import SSCore
import SSDesign
import UniformTypeIdentifiers

/// The picture a dragged attachment shows under the pointer (spec §5.17, Dragging out): a Quire file card
/// (`layout.dragCard`). `sheet`, radius 8, a hairline `rule` edge (1 pt `ruleStrong` in Increase Contrast) and `e2`,
/// which the image holds in a margin of its own; inside, the system's icon for the file's type at 32 pt, then the name
/// (`label` `ink`, middle-truncated, the extension kept) over the meta (`meta` `ink3`, “PDF · 240 KB”), as on the chip.
///
/// Drawn once per card as the drag starts, into a bitmap at the window's scale and in its appearance: a drawing handler
/// would run later, under whatever appearance is current then.
@MainActor
enum AttachmentDragCard {
    struct Content: Equatable {
        let name: String
        let meta: String
        let type: UTType
    }

    private static var m: Quire.Layout.DragCard.Type { Quire.Layout.DragCard.self }

    /// What the card says for an attachment: its name and the chip's own meta line (`RenderPayloadBuilder`).
    static func content(for info: AttachmentInfo) -> Content {
        let kind = FileMark(filename: info.filename, mimeType: info.mimeType).kind
        let size = RenderPayloadBuilder.sizeString(bytes: info.sizeBytes)
        return Content(name: info.filename.isEmpty ? "Attachment" : info.filename, meta: kind + " · " + size,
                       type: AttachmentFilePromise.fileType(filename: info.filename, mimeType: info.mimeType))
    }

    /// The room the `e2` shadow takes around the card inside the image.
    static var margin: NSEdgeInsets {
        NSEdgeInsets(top: m.shadowMarginTop, left: m.shadowMarginX, bottom: m.shadowMarginBottom, right: m.shadowMarginX)
    }

    /// The card's own size: as wide as its words need, between the chip's minimum and maximum widths.
    static func cardSize(for content: Content) -> NSSize {
        let words = max(ceil(name(content.name).size().width), ceil(meta(content.meta).size().width))
        let width = m.padLeft + m.icon + m.gap + words + m.padRight
        return NSSize(width: min(m.maxWidth, max(m.minWidth, width)), height: m.height)
    }

    /// The image's size: the card and its shadow's margin.
    static func imageSize(for content: Content) -> NSSize {
        let card = cardSize(for: content)
        return NSSize(width: card.width + margin.left + margin.right, height: card.height + margin.top + margin.bottom)
    }

    /// The card at `scale` pixels a point in `mode`, its top-left corner at (`margin.left`, `margin.top`) of the image.
    static func image(for content: Content, mode: QuireMode, scale: CGFloat) -> NSImage {
        let size = imageSize(for: content)
        let image = NSImage(size: size)
        guard let rep = bitmap(content, size: size, mode: mode, scale: scale) else { return image }
        image.addRepresentation(rep)
        return image
    }

    static func bitmap(_ content: Content, size: NSSize, mode: QuireMode, scale: CGFloat) -> NSBitmapImageRep? {
        let wide = Int((size.width * scale).rounded(.up))
        let high = Int((size.height * scale).rounded(.up))
        // An sRGB context of its own: the tokens are sRGB values, and a context AppKit makes for a bitmap may draw in the
        // display's space instead.
        guard wide > 0, high > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Points to pixels, and flipped, as every Quire view draws.
        cg.scaleBy(x: CGFloat(wide) / size.width, y: CGFloat(high) / size.height)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        mode.performAsCurrent {
            draw(content, in: NSRect(origin: NSPoint(x: margin.left, y: margin.top), size: cardSize(for: content)), mode: mode,
                 scale: scale)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = cg.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        return rep
    }

    /// Draws the card filling `card`, in the current (flipped) context.
    static func draw(_ content: Content, in card: NSRect, mode: QuireMode, scale: CGFloat) {
        let radius = m.radius
        drawShadow(under: card, mode: mode, scale: scale)
        QuireDraw.fill(card, radius: radius, .qSheet)
        let edge = QuireHairline.width(backingScale: scale, increasedContrast: mode.isIncreasedContrast)
        QuireDraw.strokeInside(card, radius: radius, width: edge, mode.isIncreasedContrast ? .qRuleStrong : .qRule)

        let icon = NSWorkspace.shared.icon(for: content.type)
        let iconRect = NSRect(x: card.minX + m.padLeft, y: (card.midY - m.icon / 2).rounded(), width: m.icon, height: m.icon)
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        let label = QuireFont.Role.label
        let metaRole = QuireFont.Role.meta
        let textX = iconRect.maxX + m.gap
        let textWidth = max(0, card.maxX - m.padRight - textX)
        let top = (card.midY - (label.lineHeight + metaRole.lineHeight) / 2).rounded()
        name(content.name).draw(with: NSRect(x: textX, y: top, width: textWidth, height: label.lineHeight),
                                options: QuireFont.drawingOptions, context: nil)
        meta(content.meta).draw(with: NSRect(x: textX, y: top + label.lineHeight, width: textWidth, height: metaRole.lineHeight),
                                options: QuireFont.drawingOptions, context: nil)
    }

    // MARK: The shadow

    /// Blurring `e2` is most of a card's cost (about 1.2 ms of 1.5), and twenty cards dragged together must still start in
    /// a frame. Every card is the same height and its shadow the same along its length away from the corners, so the shadow
    /// is blurred once per mode and scale, under a card just wide enough to hold both rounded ends and the blur beyond
    /// them, and drawn under each card in three parts: the two ends as they are, the middle column stretched between them.
    private static var shadows: [String: CGImage] = [:]

    /// From a card's vertical edge inward, where the shadow still changes along the card: the corner and three times the
    /// widest blur's spread.
    private static var shadowEnd: CGFloat { m.radius + 40 }

    private static func drawShadow(under card: NSRect, mode: QuireMode, scale: CGFloat) {
        guard let template = shadowTemplate(mode: mode, scale: scale) else { return }
        let end = margin.left + shadowEnd
        let endPixels = Int((end * scale).rounded())
        let full = NSRect(x: card.minX - margin.left, y: card.minY - margin.top, width: card.width + margin.left + margin.right,
                          height: card.height + margin.top + margin.bottom)
        let height = template.height
        let parts: [(source: CGRect, target: NSRect)] = [
            (CGRect(x: 0, y: 0, width: endPixels, height: height), NSRect(x: full.minX, y: full.minY, width: end, height: full.height)),
            (CGRect(x: endPixels, y: 0, width: 1, height: height),
             NSRect(x: full.minX + end, y: full.minY, width: max(0, full.width - 2 * end), height: full.height)),
            (CGRect(x: template.width - endPixels, y: 0, width: endPixels, height: height),
             NSRect(x: full.maxX - end, y: full.minY, width: end, height: full.height)),
        ]
        for part in parts where part.target.width > 0 {
            guard let slice = template.cropping(to: part.source) else { continue }
            NSImage(cgImage: slice, size: part.target.size).draw(in: part.target, from: .zero, operation: .sourceOver, fraction: 1,
                                                                respectFlipped: true, hints: nil)
        }
    }

    /// `e2` under the narrowest card the three parts need, blurred once per mode and scale.
    private static func shadowTemplate(mode: QuireMode, scale: CGFloat) -> CGImage? {
        // The theme too: the template is filled with its `sheet`, which the card then covers, but its edge's anti-aliasing shows.
        let key = "\(QuireEnvironment.theme.rawValue) \(mode.rawValue)@\(scale)"
        if let cached = shadows[key] { return cached }
        let card = NSRect(x: margin.left, y: margin.top, width: 2 * shadowEnd + 2, height: m.height)
        let size = NSSize(width: card.width + margin.left + margin.right, height: card.height + margin.top + margin.bottom)
        let wide = Int((size.width * scale).rounded(.up))
        let high = Int((size.height * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.scaleBy(x: CGFloat(wide) / size.width, y: CGFloat(high) / size.height)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        mode.performAsCurrent {
            NSGraphicsContext.saveGraphicsState()
            for layer in Quire.Elevation.e2.layers(for: mode) {
                let shadow = NSShadow()
                shadow.shadowColor = layer.color
                shadow.shadowBlurRadius = layer.blur
                // Shadow offsets live in the base space, where y grows upward: the shadow falls below the card.
                shadow.shadowOffset = NSSize(width: layer.x, height: -layer.y)
                shadow.set()
                QuireDraw.fill(card, radius: m.radius, .qSheet)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = cg.makeImage()
        shadows[key] = image
        return image
    }

    // MARK: Words

    /// The name, middle-truncated so the extension stays (spec §4.4).
    private static func name(_ text: String) -> NSAttributedString {
        let string = NSMutableAttributedString(attributedString: QuireFont.attributedString(text, role: .label, color: .qInk))
        if let style = (string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.lineBreakMode = .byTruncatingMiddle
            string.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: string.length))
        }
        return string
    }

    private static func meta(_ text: String) -> NSAttributedString {
        let string = NSMutableAttributedString(attributedString: QuireFont.attributedString(text, role: .meta, color: .qInk3))
        if let style = (string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.lineBreakMode = .byTruncatingTail
            string.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: string.length))
        }
        return string
    }
}
