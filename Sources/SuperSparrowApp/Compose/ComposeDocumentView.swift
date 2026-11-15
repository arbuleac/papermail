import AppKit
import SSDesign

/// The body's scroll document: the `sheet` the editor and the quoted original sit on, and, after a failed send,
/// the danger banner above the text (spec §5.20: inset 16 pt from the sides, 8 pt below the last row's hairline
/// and above the body text). Clicking the empty space under the text puts the caret at the end, so the whole
/// page feels like one editor rather than a short box.
@MainActor
final class ComposeDocumentView: NSView, QuirePointerTarget {
    weak var editor: ComposeTextView?

    private(set) var banner: QuireBannerView?

    override var isFlipped: Bool { true }

    /// Shows the send-failed banner with `message`, or removes it.
    func setFailureBanner(_ message: String?) {
        banner?.removeFromSuperview()
        banner = nil
        if let message {
            let view = QuireBannerView(kind: .danger, message: message)
            view.allowsMultipleLines = true
            addSubview(view)
            banner = view
        }
        needsLayout = true
        layoutBanner()
    }

    override func layout() {
        super.layout()
        layoutBanner()
        // The editor grows and the quote moves in layout, and their areas shape this view's; the banner's shapes the
        // editor's.
        pointerRegionsDidChange()
        if let editor { window?.invalidateCursorRects(for: editor) }
    }

    private func layoutBanner() {
        let c = Quire.Layout.Composer.self
        guard let banner else {
            editor?.topInset = c.bodyPadTop
            return
        }
        let width = max(0, bounds.width - 2 * c.bannerInsetX)
        let height = banner.height(forWidth: width)
        banner.frame = NSRect(x: c.bannerInsetX, y: c.bannerInsetY, width: width, height: height)
        editor?.topInset = c.bannerInsetY + height + c.bannerInsetY
    }

    // MARK: Pointer

    /// The I-beam over the page around the editor, which sets its own, since a click there puts the caret in the text
    /// (§4.17); the quote's chip and attribution keep their hand. The failed-send banner is a surface on the page: the
    /// arrow around its controls.
    var pointerRegions: [QuirePointerRegion] {
        let controls = childPointerAreas()
        var page = controls
        if let editor, editor.superview === self { page.append(editor.frame) }
        var regions: [QuirePointerRegion] = []
        if let banner {
            page.append(banner.frame)
            regions += QuirePointerRegion.regions(banner.frame, cursor: .arrow, cutting: controls)
        }
        return regions + QuirePointerRegion.regions(bounds, cursor: .iBeam, cutting: page)
    }

    override func resetCursorRects() {
        addPointerRects()
    }

    override func mouseDown(with event: NSEvent) {
        guard let editor, let window else {
            super.mouseDown(with: event)
            return
        }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qSheet.setFill()
        // Views no longer clip to their bounds (macOS 14), and the dirty rect can reach past them.
        dirtyRect.intersection(bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
