import AppKit
import SSDesign

/// The composer's content view (spec §3.2, §5.20). The window has a transparent system title bar over `paper`,
/// so this view runs under it: the band's height is read from the window, a hairline closes it, and the field
/// rows start directly below. From the top: the rows, the body (`sheet`), the attachment strip, the format row
/// and the bottom bar, laid out by hand to the token metrics.
///
/// Files dropped anywhere on the window become attachments; while a file drag hovers, the body shows the drop
/// outline. The composer's window-wide shortcuts (⌘↩, ⇧⌘A, ⇧⌘T, ⇧⌘C, ⇧⌘B) are answered here, before the
/// menus, so they work from every field.
@MainActor
final class ComposeContentView: NSView {
    enum Command {
        case send, attach, toggleFormatRow, addCc, addBcc
    }

    var onDropFiles: (([URL]) -> Void)?
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

    private let dropOutline = DropOutlineView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .qSheet
        dropOutline.isHidden = true
        for view in [scrollView, strip, formatRow, bottomBar, dropOutline] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeContentView is built in code")
    }

    override var isFlipped: Bool { true }

    /// The system title bar's height, measured: 28 pt on macOS 15, 32 pt from macOS 26 (§3.2).
    var titlebarHeight: CGFloat {
        guard let window else { return Quire.Layout.Window.composerTitlebar }
        return max(0, bounds.height - window.contentLayoutRect.height)
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
        guard !fileURLs(in: sender).isEmpty else { return [] }
        dropOutline.isHidden = false
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOutline.isHidden ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOutline.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropOutline.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOutline.isHidden = true
        let urls = fileURLs(in: sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    private func fileURLs(in info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { $0 as? URL }
    }

    /// Shows the drop outline without a drag, for snapshots of the state.
    func setDropOutlineVisible(_ visible: Bool) {
        dropOutline.isHidden = !visible
    }
}

/// The drop target over the body (§5.20, Dragging files over): a 2 pt dashed `focus` outline inset 8 pt, radius
/// `r.lg`, with “Drop to attach” in `label` `accent` centred in it. Transparent to clicks and drags.
@MainActor
private final class DropOutlineView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let c = Quire.Layout.Composer.self
        let width = c.dropOutline
        let outline = bounds.insetBy(dx: c.dropInset + width / 2, dy: c.dropInset + width / 2)
        let radius = Quire.Radius.lg
        let path = NSBezierPath(roundedRect: outline, xRadius: radius, yRadius: radius)
        path.lineWidth = width
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.qFocus.setStroke()
        path.stroke()
        let role = QuireFont.Role.label
        let label = QuireFont.attributedString("Drop to attach", role: role, color: .qAccent)
        let size = label.size()
        label.draw(with: NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - role.lineHeight / 2).rounded(),
                                width: ceil(size.width) + 1, height: role.lineHeight), options: QuireFont.drawingOptions, context: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
