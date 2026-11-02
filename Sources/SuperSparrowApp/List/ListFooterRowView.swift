import AppKit
import SSDesign

/// The list tail (spec §5.10): a fixed 28 pt row that ends the list while older pages exist. It stays empty
/// `paper` until a page load has run for 150 ms, so fast pages never flash; then a 12 pt `ink3` spinner and
/// “Loading older mail…”. A failed load shows the danger triangle, “Couldn't load older mail” and a Retry link.
/// It is the same height in both densities, never selectable, and j/k never land on it.
final class ListFooterRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ListFooterRow")

    enum Phase: Equatable {
        case idle
        case loading
        case failed
    }

    var phase = Phase.idle {
        didSet { if oldValue != phase { phaseDidChange() } }
    }

    var onRetry: (() -> Void)? {
        didSet { retryButton.onPress = onRetry }
    }

    private typealias Footer = Quire.Layout.ListFooter
    /// Every pointer target is at least 24 pt tall (spec §4.14), the link included.
    private static let minimumHitHeight = Quire.Layout.Button.minHit

    private let spinner = QuireSpinnerView(size: .small, color: .qInk3)
    private let retryButton = RetryButton()
    /// The words show with the spinner, after its delay, never before it.
    private var showsLoadingText = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = ListFooterRowView.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        spinner.onReveal = { [weak self] in
            self?.showsLoadingText = true
            self?.needsLayout = true
            self?.needsDisplay = true
        }
        addSubview(spinner)
        retryButton.isHidden = true
        addSubview(retryButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func phaseDidChange() {
        switch phase {
        case .loading:
            showsLoadingText = false
            spinner.startAnimation()
        case .idle, .failed:
            spinner.stopAnimation()
            showsLoadingText = false
        }
        retryButton.isHidden = phase != .failed
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Content

    private static let loadingText = QuireFont.attributedString("Loading older mail…", role: .meta, color: .qInk3)
    private static let failedText = QuireFont.attributedString("Couldn't load older mail · ", role: .meta, color: .qInk3)

    /// The centred cluster's pieces for the current phase: the leading mark (spinner or glyph) and the words.
    private var words: NSAttributedString? {
        switch phase {
        case .idle: return nil
        case .loading: return showsLoadingText ? ListFooterRowView.loadingText : nil
        case .failed: return ListFooterRowView.failedText
        }
    }

    private var clusterWidth: CGFloat {
        guard let words else { return Footer.spinner }
        var width = Footer.spinner + Footer.gap + ceil(words.size().width)
        if phase == .failed { width += retryButton.labelWidth }
        return width
    }

    private var clusterX: CGFloat { ((bounds.width - clusterWidth) / 2).rounded() }

    override func layout() {
        super.layout()
        let size = Footer.spinner
        spinner.frame = NSRect(x: clusterX, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
        if phase == .failed, let words {
            let x = clusterX + size + Footer.gap + ceil(words.size().width)
            let hit = ListFooterRowView.minimumHitHeight
            let pad = Quire.Layout.Button.linkPadX
            retryButton.frame = NSRect(x: x - pad, y: ((bounds.height - hit) / 2).rounded(), width: retryButton.labelWidth + 2 * pad, height: hit)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        bounds.fill()
        guard let words else { return }
        let size = Footer.spinner
        let x = clusterX
        if phase == .failed {
            QuireSymbol.draw(Quire.Icon.failed, size: .row, color: .qDanger,
                             centredIn: NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size))
        }
        let lineHeight = QuireFont.Role.meta.lineHeight
        words.draw(with: NSRect(x: x + size + Footer.gap, y: ((bounds.height - lineHeight) / 2).rounded(),
                                width: ceil(words.size().width) + 1, height: lineHeight),
                   options: QuireFont.drawingOptions, context: nil)
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { phase != .idle }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? {
        switch phase {
        case .idle: return nil
        case .loading: return "Loading older mail"
        case .failed: return "Couldn't load older mail"
        }
    }

    /// “Retry”: a link in `metaStrong` `accent` (spec §5.10). Link buttons never take a wash, because the
    /// accent label must keep 4.5:1; hover and press show as the underline. The hit area is 24 pt tall.
    private final class RetryButton: NSControl {
        var onPress: (() -> Void)?
        private var isHovered = false { didSet { needsDisplay = true } }
        private var isPressedDown = false { didSet { needsDisplay = true } }
        private var trackingArea: NSTrackingArea?

        private static let label = QuireFont.attributedString("Retry", role: .metaStrong, color: .qAccent)
        var labelWidth: CGFloat { ceil(RetryButton.label.size().width) }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        /// A retry the user can act on joins the Tab order whether or not Full Keyboard Access is on, as the
        /// sync line's actions do (spec §5.11).
        override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

        private var labelRect: NSRect {
            let height = QuireFont.Role.metaStrong.lineHeight
            return NSRect(x: (bounds.width - labelWidth) / 2, y: ((bounds.height - height) / 2).rounded(), width: labelWidth, height: height)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            focusRingType = .none
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }

        override func mouseDown(with event: NSEvent) {
            isPressedDown = true
            guard let window else { return }
            // Track until the button comes up, so a press dragged off the link does nothing, as buttons behave.
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                let inside = bounds.contains(convert(next.locationInWindow, from: nil))
                isPressedDown = inside
                if next.type == .leftMouseUp {
                    isPressedDown = false
                    if inside { onPress?() }
                    return
                }
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
                onPress?()
            } else {
                super.keyDown(with: event)
            }
        }

        override func becomeFirstResponder() -> Bool {
            needsDisplay = true
            return super.becomeFirstResponder()
        }

        override func resignFirstResponder() -> Bool {
            needsDisplay = true
            return super.resignFirstResponder()
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = labelRect
            RetryButton.label.draw(with: rect, options: QuireFont.drawingOptions, context: nil)
            if isHovered || isPressedDown {
                NSColor.qAccent.setFill()
                NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 1).fill()
            }
            if window?.firstResponder === self, window?.isKeyWindow == true {
                QuireFocusRing.draw(around: rect.insetBy(dx: -2, dy: 0), cornerRadius: Quire.Radius.sm)
            }
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { "Retry" }
        override func accessibilityPerformPress() -> Bool {
            onPress?()
            return true
        }
    }
}
