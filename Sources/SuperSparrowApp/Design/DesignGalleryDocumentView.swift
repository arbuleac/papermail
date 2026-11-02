import AppKit
import SSDesign

/// The gallery page: section headers and rows of cards on the studio desk, laid out on the specimen's
/// 12-column, 1280 pt grid so a render crops against section D of docs/design/specimen-*.png at the same
/// coordinates within a card.
@MainActor
final class DesignGalleryDocumentView: NSView {
    private static let margin = (DesignGalleryStudio.pageWidth - DesignGalleryStudio.contentWidth) / 2
    private var y: CGFloat = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: DesignGalleryStudio.pageWidth, height: 100))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The page itself takes first responder, so no sample field starts out editing: a field that did would
    /// draw its real focus ring over the rest state it is there to show.
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DesignGalleryStudio.background.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pinContrastCards(in: self)
    }

    private func pinContrastCards(in view: NSView) {
        for subview in view.subviews {
            if let contrast = subview as? DesignGalleryContrastView { contrast.pinAppearance() } else { pinContrastCards(in: subview) }
        }
    }

    private func build() {
        y = 24
        header(number: "D · Components", title: "Every component, every state",
               detail: "AppKit components from SSDesign, drawn live from the generated tokens. Labels name the state; "
                   + "numbers come from tokens.json.", first: true)
        cardRow([DesignGalleryCards.buttons(), DesignGalleryCards.fields()])
        cardRow([DesignGalleryCards.listHeader(), DesignGalleryCards.sheet(), DesignGalleryCards.slips()])
        cardRow([DesignGalleryCards.banners(), DesignGalleryCards.badges(), DesignGalleryCards.keycaps()])
        cardRow([DesignGalleryCards.avatars(), DesignGalleryCards.emptyStates(), DesignGalleryCards.progress()])
        cardRow([DesignGalleryCards.rules()])
        cardRow([DesignGalleryCards.increasedContrast()])
        header(number: "D · SwiftUI", title: "Settings controls, hosted",
               detail: "The SwiftUI counterparts (QuireButtonStyle, QuireToggleStyle, QuireFieldStyle, account rows and the "
                   + "settings grid) in an NSHostingView.", first: false)
        cardRow([DesignGallerySwiftUICard.make()])
        y += 72
        setFrameSize(NSSize(width: DesignGalleryStudio.pageWidth, height: ceil(y)))
        DesignGallerySamples.pinKeyWindow(in: self)
    }

    /// `.sh`: a studio rule, the section number in running-head caps, the New York title, a right-aligned note.
    private func header(number: String, title: String, detail: String, first: Bool) {
        y += first ? 0 : 64 - DesignGalleryStudio.gridGap
        let rule = DesignGalleryFlippedView(frame: NSRect(x: Self.margin, y: y, width: DesignGalleryStudio.contentWidth, height: 1))
        rule.fill = DesignGalleryStudio.rule
        addSubview(rule)
        y += 17
        let titleView = DesignGalleryText(DesignGalleryStudio.text(title, font: DesignGalleryStudio.serif(30), color: DesignGalleryStudio.ink,
                                                                   lineHeight: 36, tracking: -0.5))
        titleView.setFrameOrigin(NSPoint(x: Self.margin + 136, y: y))
        addSubview(titleView)
        // Baselines align (`align-items: baseline`): the 14 pt running head sits on the title's baseline.
        let numberView = DesignGalleryText(number, role: .runningHead, color: DesignGalleryStudio.ink2)
        numberView.setFrameOrigin(NSPoint(x: Self.margin, y: y + 15))
        addSubview(numberView)
        let detailView = DesignGalleryText(DesignGalleryStudio.text(detail, font: .systemFont(ofSize: 13), color: DesignGalleryStudio.ink2,
                                                                    lineHeight: 18, alignment: .right), maxWidth: 520)
        detailView.setFrameOrigin(NSPoint(x: Self.margin + DesignGalleryStudio.contentWidth - detailView.frame.width, y: y + 9))
        addSubview(detailView)
        y += max(36, detailView.frame.maxY - y) + 22
    }

    /// One grid row: cards left to right by span, stretched to the tallest, as CSS grid rows stretch.
    private func cardRow(_ cards: [NSView]) {
        let height = cards.map(\.frame.height).max() ?? 0
        var x = Self.margin
        for card in cards {
            card.frame = NSRect(x: x, y: y, width: card.frame.width, height: height)
            addSubview(card)
            x += card.frame.width + DesignGalleryStudio.gridGap
        }
        y += height + DesignGalleryStudio.gridGap
    }
}
