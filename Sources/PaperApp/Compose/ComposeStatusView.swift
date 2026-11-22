import AppKit
import PaperCore
import PaperDesign

/// The composer's status, trailing in the bottom bar (spec §5.20): `meta`, the glyph 6 pt before the words, a
/// 12 pt spinner in the glyph's place while the original loads (after 150 ms). Quiet statuses are `ink3`;
/// info and warnings set their words in `ink2`, warnings with the `warning` triangle.
@MainActor
final class ComposeStatusView: NSView {
    var status: ComposeStatus? {
        didSet {
            guard oldValue != status else { return }
            toolTip = status?.tooltip
            updateSpinner()
            invalidateIntrinsicContentSize()
            needsDisplay = true
            if let status { NSAccessibility.post(element: self, notification: .valueChanged); setAccessibilityValue(status.text) }
        }
    }

    private let spinner = QuireSpinnerView(size: .small, color: .qInk3)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.isHidden = true
        addSubview(spinner)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeStatusView is built in code")
    }

    override var isFlipped: Bool { true }

    private var glyphSize: CGFloat { QuireSpinnerView.Size.small.diameter }

    private var textString: NSAttributedString? {
        guard let status else { return nil }
        let color: NSColor = status.tone == .quiet ? .qInk3 : .qInk2
        return QuireFont.attributedString(status.text, role: .meta, color: color)
    }

    private var leadWidth: CGFloat {
        guard let status else { return 0 }
        if status.showsSpinner { return glyphSize + Quire.Layout.Composer.statusGlyphGap }
        guard let name = status.symbolName,
              let image = QuireSymbol.cachedImage(name, size: .custom(QuireFont.Role.meta.spec.size)) else { return 0 }
        return image.size.width + Quire.Layout.Composer.statusGlyphGap
    }

    override var intrinsicContentSize: NSSize {
        guard let text = textString else { return NSSize(width: 0, height: QuireFont.Role.meta.lineHeight) }
        return NSSize(width: ceil(leadWidth + text.size().width) + 1, height: QuireFont.Role.meta.lineHeight)
    }

    private func updateSpinner() {
        if status?.showsSpinner == true {
            spinner.isHidden = false
            spinner.startAnimation()
        } else {
            spinner.stopAnimation()
            spinner.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        let d = glyphSize
        spinner.frame = NSRect(x: max(0, bounds.width - intrinsicContentSize.width), y: ((bounds.height - d) / 2).rounded(),
                               width: d, height: d)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let status, let text = textString else { return }
        let role = QuireFont.Role.meta
        // Trailing-aligned: a narrower bar truncates the words, never the glyph.
        let start = max(0, bounds.width - intrinsicContentSize.width)
        var x = start
        if !status.showsSpinner, let name = status.symbolName {
            let color: NSColor = status.tone == .warning ? .qWarning : .qInk3
            let size = QuireSymbol.cachedImage(name, size: .custom(role.spec.size))?.size ?? .zero
            QuireSymbol.draw(name, size: .custom(role.spec.size), color: color,
                             centredIn: NSRect(x: x, y: 0, width: size.width, height: bounds.height))
        }
        x += leadWidth
        text.draw(with: NSRect(x: x, y: ((bounds.height - role.lineHeight) / 2).rounded(), width: max(0, bounds.width - x),
                               height: role.lineHeight), options: QuireFont.drawingOptions, context: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func accessibilityLabel() -> String? { status?.text }
}
