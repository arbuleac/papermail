#if DEBUG
import AppKit
import PaperDesign

/// Lays a card's samples out the way the specimen's `.st`, `.bmx` and `.rowline` grids do: a meta label column
/// on the left, samples in rows, and captions that name each state. Quire controls are placed by their visual
/// rect (their frame carries the focus ring's margin), so they line up with the specimen's boxes.
@MainActor
struct DesignGalleryBlock {
    let view = DesignGalleryFlippedView()
    let width: CGFloat
    /// The label column (`.st` 110 pt; the buttons grid uses 76, the fields grid 90).
    var labelWidth: CGFloat
    var labelGap: CGFloat = 14
    var rowGap: CGFloat = 10
    private(set) var y: CGFloat = 0

    init(width: CGFloat, labelWidth: CGFloat = 110) {
        self.width = width
        self.labelWidth = labelWidth
    }

    var contentX: CGFloat { labelWidth > 0 ? labelWidth + labelGap : 0 }
    var contentWidth: CGFloat { width - contentX }

    // MARK: Rows

    /// Column headings over a grid whose columns start at `xs` (relative to the content column).
    mutating func heads(_ titles: [String], at xs: [CGFloat]) {
        var height: CGFloat = 0
        for (title, x) in zip(titles, xs) {
            let text = DesignGalleryText(title)
            text.setFrameOrigin(NSPoint(x: contentX + x, y: y))
            view.addSubview(text)
            height = max(height, text.frame.height)
        }
        y += height + rowGap
    }

    /// One row: `label` in the label column, `samples` left to right (at `xs` when given, else 10 pt apart and
    /// wrapping), and an optional caption under them. The label centres on the whole row, caption included.
    /// `ann` joins the samples as the last item of the flow, as the specimen's inline `.ann` does.
    mutating func row(_ label: String?, _ samples: [NSView], at xs: [CGFloat]? = nil, gap: CGFloat = 10,
                      ann: String? = nil, annWidth: CGFloat? = nil, caption: String? = nil, captionGap: CGFloat = 6) {
        let top = y
        var samples = samples
        if let ann { samples.append(DesignGalleryText(ann, maxWidth: annWidth ?? contentWidth)) }
        var lines: [[(NSView, NSRect)]] = [[]]
        var x: CGFloat = 0
        for (index, sample) in samples.enumerated() {
            let visual = Self.visualSize(of: sample)
            if let xs {
                x = xs[min(index, xs.count - 1)]
            } else if x > 0, x + visual.width > contentWidth {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append((sample, NSRect(origin: NSPoint(x: x, y: 0), size: visual)))
            x += visual.width + gap
        }
        var lineTop = y
        for line in lines where !line.isEmpty {
            let height = line.map(\.1.height).max() ?? 0
            for (sample, rect) in line {
                let visual = NSRect(x: contentX + rect.minX, y: lineTop + ((height - rect.height) / 2).rounded(),
                                    width: rect.width, height: rect.height)
                Self.place(sample, visual: visual, in: view)
            }
            lineTop += height + rowGap
        }
        var bottom = lineTop - rowGap
        if let caption {
            let text = DesignGalleryText(caption, maxWidth: contentWidth)
            text.setFrameOrigin(NSPoint(x: contentX, y: bottom + captionGap))
            view.addSubview(text)
            bottom = text.frame.maxY
        }
        if let label, labelWidth > 0 {
            let text = DesignGalleryText(label, maxWidth: labelWidth)
            text.setFrameOrigin(NSPoint(x: 0, y: (top + (bottom - top - text.frame.height) / 2).rounded()))
            view.addSubview(text)
            bottom = max(bottom, text.frame.maxY)
        }
        y = bottom + rowGap
    }

    /// Samples with a caption centred under each, as the specimen's rail grid labels its tiles.
    mutating func captioned(_ label: String?, _ samples: [(NSView, String)], columnWidth: CGFloat, gap: CGFloat = 8) {
        let top = y
        let columns = max(1, Int((contentWidth + 0.5) / columnWidth))
        var bottom = y
        var lineTop = y
        for start in stride(from: 0, to: samples.count, by: columns) {
            let line = samples[start..<min(samples.count, start + columns)]
            let height = line.map { Self.visualSize(of: $0.0).height }.max() ?? 0
            var lineBottom = lineTop + height
            for (offset, (sample, caption)) in line.enumerated() {
                let visual = Self.visualSize(of: sample)
                let x = contentX + CGFloat(offset) * columnWidth
                Self.place(sample, visual: NSRect(x: (x + (columnWidth - visual.width) / 2).rounded(),
                                                  y: lineTop + ((height - visual.height) / 2).rounded(),
                                                  width: visual.width, height: visual.height), in: view)
                let text = DesignGalleryText(caption, maxWidth: columnWidth - 4, alignment: .center)
                text.setFrameOrigin(NSPoint(x: (x + (columnWidth - text.frame.width) / 2).rounded(), y: lineTop + height + gap))
                view.addSubview(text)
                lineBottom = max(lineBottom, text.frame.maxY)
            }
            bottom = lineBottom
            lineTop = lineBottom + 16
        }
        if let label, labelWidth > 0 {
            let text = DesignGalleryText(label, maxWidth: labelWidth)
            text.setFrameOrigin(NSPoint(x: 0, y: top))
            view.addSubview(text)
        }
        y = bottom + rowGap
    }

    /// A meta line spanning the block (the specimen's `.lbl`).
    mutating func note(_ text: String, top: CGFloat = 2, bottom: CGFloat = 6) {
        y += top
        let label = DesignGalleryText(text, maxWidth: width)
        label.setFrameOrigin(NSPoint(x: 0, y: y))
        view.addSubview(label)
        y = label.frame.maxY + bottom
    }

    /// A view at the block's leading edge, full width or its own.
    mutating func full(_ sample: NSView, x: CGFloat = 0) {
        let visual = Self.visualSize(of: sample)
        Self.place(sample, visual: NSRect(x: x, y: y, width: visual.width, height: visual.height), in: view)
        y += visual.height + rowGap
    }

    mutating func space(_ points: CGFloat) {
        y += points
    }

    /// The finished block, sized to its content.
    func finish() -> NSView {
        view.setFrameSize(NSSize(width: width, height: max(0, y - rowGap)))
        return view
    }

    // MARK: Geometry

    /// Samples keep the size they were given: Quire initialisers size themselves, and the cards resize the
    /// ones whose state changes their width.
    static func visualSize(of view: NSView) -> NSSize {
        view.alignmentRect(forFrame: view.frame).size
    }

    static func place(_ sample: NSView, visual: NSRect, in container: NSView) {
        sample.frame = sample.frame(forAlignmentRect: visual)
        container.addSubview(sample)
    }

    /// Column origins for a grid whose columns are as wide as their widest sample plus `gap` (CSS `auto`).
    static func columns(_ rows: [[NSView?]], gap: CGFloat) -> [CGFloat] {
        let count = rows.map(\.count).max() ?? 0
        var xs: [CGFloat] = []
        var x: CGFloat = 0
        for column in 0..<count {
            xs.append(x)
            let widest = rows.compactMap { column < $0.count ? $0[column] : nil }.map { visualSize(of: $0).width }.max() ?? 0
            x += widest + gap
        }
        return xs
    }
}

/// A container with a top-left origin, so gallery layout reads like the page it copies.
@MainActor
final class DesignGalleryFlippedView: NSView {
    var fill: NSColor?
    var cornerRadius: CGFloat = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
}
#endif
