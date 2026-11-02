#if DEBUG
import AppKit
import SSDesign

/// One card of the gallery, drawn like the specimen's `.card`: a 12 pt rounded surface with a 1 pt studio
/// outline, a New York title with its token path in mono, a meta caption, then the samples.
@MainActor
final class DesignGalleryCard: NSView {
    enum Surface {
        case paper
        case canvas
        case sheet
        /// The specimen's `--studio-card`, as it shows slips and the cheat sheet: they float over content, so they
        /// are read against a surface darker than paper, a tint apart from the desk the cards sit on.
        case studio

        @MainActor var color: NSColor {
            switch self {
            case .paper: return .qPaper
            case .canvas: return .qCanvas
            case .sheet: return .qSheet
            case .studio: return DesignGalleryStudio.card
            }
        }
    }

    static let padTop: CGFloat = 18
    static let padX: CGFloat = 20
    static let padBottom: CGFloat = 20
    static let radius: CGFloat = 12

    let span: Int
    let surface: Surface

    /// Builds the card at the width of `span` grid columns; `build` fills a block as wide as the card's inside.
    init(_ title: String, code: String?, caption: String?, span: Int, surface: Surface = .paper,
         build: (inout DesignGalleryBlock) -> Void) {
        self.span = span
        self.surface = surface
        let width = DesignGalleryStudio.width(span: span)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        let inner = width - 2 * Self.padX
        var y = Self.padTop

        // `.card h3`: 600 15/20 serif, the code in 10.5 pt mono `ink3`, baselines aligned 10 pt apart.
        let heading = NSMutableAttributedString(attributedString: DesignGalleryStudio.text(
            title, font: DesignGalleryStudio.serif(15), color: .qInk, lineHeight: 20))
        if let code {
            heading.append(DesignGalleryStudio.text("\u{2002}" + code, font: .monospacedSystemFont(ofSize: 10.5, weight: .regular),
                                                    color: .qInk3, lineHeight: 20))
        }
        let titleView = DesignGalleryText(heading, maxWidth: inner)
        titleView.setFrameOrigin(NSPoint(x: Self.padX, y: y))
        addSubview(titleView)
        y = titleView.frame.maxY + 4

        if let caption {
            let captionView = DesignGalleryText(caption, maxWidth: min(inner, 560))
            captionView.setFrameOrigin(NSPoint(x: Self.padX, y: y))
            addSubview(captionView)
            y = captionView.frame.maxY
        }
        y += 14

        var block = DesignGalleryBlock(width: inner)
        build(&block)
        let content = block.finish()
        content.setFrameOrigin(NSPoint(x: Self.padX, y: y))
        addSubview(content)
        setFrameSize(NSSize(width: width, height: ceil(content.frame.maxY + Self.padBottom)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // `box-shadow: 0 0 0 1px studio-rule`: a ring just outside the card, so the surface keeps its full size.
        let outline = NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius)
        DesignGalleryStudio.rule.setFill()
        outline.fill()
        surface.color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Self.radius - 1, yRadius: Self.radius - 1).fill()
    }
}
#endif
