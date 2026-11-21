import AppKit
import SSDesign

/// The composer's content view (spec §3.2, §5.20). The window has a transparent system title bar over `paper`,
/// so this view runs under it: the band's height is read from the window, a hairline closes it, and the field
/// rows start directly below. From the top: the rows, the body (`sheet`), the attachment strip, the format row
/// and the bottom bar, laid out by hand to the token metrics.
///
/// Files dropped anywhere on the window become attachments, except pictures dropped on the body's text, which go into
/// it (`ComposeTextView`, §5.20 Images in the body); so do attachments dragged from a message in any reader (§5.17),
/// whatever their type. While a drag that will attach hovers, the body shows the drop outline. The composer's window-wide shortcuts (⌘↩, ⇧⌘↩, ⇧⌘A, ⇧⌘T, ⇧⌘C, ⇧⌘B) are answered here, before the
/// menus, so they work from every field.
@MainActor
final class ComposeContentView: NSView {
    enum Command {
        /// ⌘↩: what Send does (§5.23). ⇧⌘↩: send and archive, whatever Send does.
        case send, sendAndArchive, attach, toggleFormatRow, addCc, addBcc
    }

    /// Files, or the app's own attachments, dropped to attach.
    var onDrop: (([AttachmentDropItem]) -> Void)?
    /// False while a drop would be thrown away (the message is being handed over, the window is going): nothing lights up.
    var acceptsDrops: () -> Bool = { true }
    var onCommand: ((Command) -> Void)?

    var rows: [ComposeFieldRow] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            rows.forEach { addSubview($0, positioned: .below, relativeTo: dropOutline) }
            needsLayout = true
        }
    }

    let scrollView = NSScrollView()
    let strip = AttachmentStripView()
    let formatRow = ComposeFormatRow()
    let bottomBar = ComposeBottomBar()
    var showsFormatRow = false {
        didSet { if oldValue != showsFormatRow { needsLayout = true } }
    }

    /// The body's text stays, veiled, under the words, which keep clear of the dragged card.
    private let dropOutline = AttachmentDropOverlay(label: "Drop to attach", inset: Quire.Layout.Composer.dropInset, radius: Quire.Radius.lg,
                                                    fill: .qSheet, fillAlpha: Quire.Layout.Composer.dropVeil)

    /// The drop outline shows (the app's tests read it, and its renders set it).
    var showsDropOutline: Bool {
        get { !dropOutline.isHidden }
        set {
            if newValue { raiseDropOutline() }
            dropOutline.isHidden = !newValue
        }
    }

    /// The drop treatment shows above whatever was laid over the body after it: anything laid on the body goes under the
    /// veil with the text, and never covers the words.
    private func raiseDropOutline() {
        guard dropOutline.superview === self, subviews.last !== dropOutline else { return }
        addSubview(dropOutline, positioned: .above, relativeTo: nil)
    }

    /// The drop treatment, for the app's tests and renders: where its words are.
    var dropOverlay: AttachmentDropOverlay { dropOutline }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(AttachmentPasteboard.dropTypes)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .qSheet
        for view in [scrollView, strip, formatRow, bottomBar, dropOutline] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeContentView is built in code")
    }

    override var isFlipped: Bool { true }

    /// The system title bar's height as AppKit laid it out: 28 pt on macOS 15, 32 pt from macOS 26 (§3.2). The
    /// token is only the guess before the view is in a window.
    var titlebarHeight: CGFloat {
        guard let window else { return Quire.Layout.Window.composerTitlebar }
        return QuireWindowChrome.titlebarHeight(of: window)
    }

    /// Where the body (and the drop outline) sits.
    private(set) var bodyRect: NSRect = .zero

    override func layout() {
        super.layout()
        let c = Quire.Layout.Composer.self
        var y = titlebarHeight
        for row in rows where !row.isHidden {
            let height = row.preferredHeight
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
        var bottom = bounds.height - c.bottomBar
        bottomBar.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: c.bottomBar)
        formatRow.isHidden = !showsFormatRow
        if showsFormatRow {
            bottom -= c.formatRow
            formatRow.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: c.formatRow)
        }
        strip.isHidden = !strip.hasChips
        if strip.hasChips {
            bottom -= c.strip
            strip.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: c.strip)
        }
        bodyRect = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bottom - y))
        scrollView.frame = bodyRect
        dropOutline.frame = bodyRect
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        // Views no longer clip to their bounds (macOS 14), and the dirty rect can reach past them.
        dirtyRect.intersection(bounds).fill()
        // The hairline that closes the title band (§3.2).
        let band = titlebarHeight
        QuireHairline.fill(along: NSRect(x: 0, y: 0, width: bounds.width, height: band), orientation: .horizontal,
                           width: QuireHairline.width(for: self), color: .qRule)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        scrollView.backgroundColor = .qSheet
    }

    // MARK: Shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command], key == "\r" || key == "\u{3}" {
            onCommand?(.send)
            return true
        }
        if flags == [.command, .shift] {
            switch key {
            case "\r", "\u{3}": onCommand?(.sendAndArchive); return true
            case "a": onCommand?(.attach); return true
            case "t": onCommand?(.toggleFormatRow); return true
            case "c": onCommand?(.addCc); return true
            case "b": onCommand?(.addBcc); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops(), !AttachmentPasteboard.dropItems(for: sender).isEmpty else { return [] }
        raiseDropOutline()
        dropOutline.show(for: sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !dropOutline.isHidden else { return [] }
        dropOutline.show(for: sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOutline.show(for: nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropOutline.show(for: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOutline.show(for: nil)
        let items = AttachmentPasteboard.dropItems(for: sender)
        guard acceptsDrops(), !items.isEmpty else { return false }
        onDrop?(items)
        return true
    }
}
