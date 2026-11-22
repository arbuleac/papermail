import AppKit
import PaperDesign

/// The strip a quick-reply send leaves in the field (spec §5.18): the undo countdown with its contrail, then
/// the outcome. It fills the field's frame, so the bar keeps its height and nothing else moves.
@MainActor
final class QuickReplyStripView: NSView, QuirePointerTarget {
    enum State: Equatable {
        /// Inside the undo window: "Sending in 4 s" · "to Ben Carter", Undo with ⌘Z before it, the contrail. After Send
        /// and Archive the lead says the conversation went first, “Archived · sending in 4 s”, and Undo brings it back.
        case counting(endsAt: Date, duration: TimeInterval, recipient: String, archived: Bool = false)
        /// The window ran out and the send left: "Sent" for 1500 ms.
        case sent
        /// The window ran out while offline: the send waits for the connection.
        case queuedOffline
        /// Undo arrived after the message had gone.
        case alreadySent
        /// Undone after the selection moved on: the text waits under its own conversation.
        case notSent(subject: String)
    }

    var onUndo: (() -> Void)?
    var onShow: (() -> Void)?
    /// A click outside Undo during the countdown: the field comes back for a new reply.
    var onDismiss: (() -> Void)?

    var showsKeycaps = true {
        didSet { if oldValue != showsKeycaps { needsLayout = true; undo.keycap = showsKeycaps ? "⌘Z" : nil } }
    }

    private(set) var state: State?
    private let glyph = NSImageView()
    private let lead = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let undo = QuireButton(title: "Undo", variant: .secondary, size: .small)
    private let show = QuireButton(title: "Show", variant: .link, size: .small)
    private let contrail = QuireContrailView(mode: .determinate(0))
    private var ticker: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [lead, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.imageScaling = .scaleNone
        // A glyph, not a well: an image view registers for files and pictures even when it cannot be edited.
        glyph.unregisterDraggedTypes()
        addSubview(glyph)
        undo.keycap = "⌘Z"
        undo.keycapLeads = true
        undo.keycapGap = Quire.Layout.QuickReply.stripKeycapGap
        undo.target = self
        undo.action = #selector(undoPressed)
        addSubview(undo)
        show.target = self
        show.action = #selector(showPressed)
        addSubview(show)
        addSubview(contrail)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    deinit {
        ticker?.invalidate()
    }

    func apply(_ state: State?) {
        self.state = state
        ticker?.invalidate()
        ticker = nil
        undo.isHidden = true
        show.isHidden = true
        contrail.isHidden = true
        detail.stringValue = ""
        guard let state else { return }
        switch state {
        case let .counting(endsAt, duration, recipient, archived):
            setGlyph(Quire.Icon.sendPanel)
            detail.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString("to " + recipient, role: .snippet, color: .qInk3))
            undo.isHidden = false
            contrail.isHidden = false
            contrail.mode = .countdown(duration: duration, remaining: max(0, endsAt.timeIntervalSinceNow))
            updateSeconds(endsAt: endsAt, archived: archived)
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSeconds(endsAt: endsAt, archived: archived) }
            }
        case .sent:
            setGlyph(Quire.Icon.upToDate)
            setLead("Sent")
        case .queuedOffline:
            setGlyph(Quire.Icon.offline)
            setLead("Will send when you\u{2019}re back online")
        case .alreadySent:
            setGlyph(Quire.Icon.upToDate)
            setLead("Already sent")
            detail.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString("Undo came after the message left.", role: .snippet, color: .qInk3))
        case .notSent(let subject):
            setGlyph(Quire.Icon.undone)
            let title = subject.isEmpty ? "Not sent \u{00b7} draft kept" : "Not sent \u{00b7} draft kept in \u{201c}\(subject)\u{201d}"
            setLead(title)
            show.isHidden = false
        }
        needsLayout = true
        pointerRegionsDidChange()
    }

    /// Seconds left, as text beside the contrail, always (spec §4.10).
    private func updateSeconds(endsAt: Date, archived: Bool) {
        setLead(Self.countdown(secondsLeft: max(0, Int(ceil(endsAt.timeIntervalSinceNow))), archived: archived))
    }

    /// “Sending in 4 s”, or after Send and Archive “Archived · sending in 4 s”: the archive happened when the send was
    /// queued, and it leads, since the lead never truncates (the recipient after it does, §5.18).
    static func countdown(secondsLeft: Int, archived: Bool) -> String {
        archived ? "Archived \u{00b7} sending in \(secondsLeft) s" : "Sending in \(secondsLeft) s"
    }

    /// The lead as shown now (tests).
    var leadText: String { lead.stringValue }

    /// The lead has the room to show whole as laid out now (tests: it never truncates; the recipient after it does).
    var showsLeadWhole: Bool { lead.frame.width >= ceil(lead.attributedStringValue.size().width) }

    private func setLead(_ text: String) {
        var attributes = QuireFont.attributes(.body, color: .qInk)
        attributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: QuireFont.Role.body.size, weight: .regular)
        let changed = lead.stringValue != text
        lead.attributedStringValue = ReaderFonts.fieldString(NSAttributedString(string: text, attributes: attributes))
        if changed { needsLayout = true }
    }

    private func setGlyph(_ name: String) {
        let image = QuireSymbol.image(name, size: .custom(Quire.Layout.QuickReply.stripGlyph))
        glyph.image = image
        glyph.contentTintColor = .qInk2
    }

    override func layout() {
        super.layout()
        let metrics = Quire.Layout.QuickReply.self
        let gap = metrics.stripGap
        let glyphSide = metrics.stripGlyph + 4
        var x = metrics.faceX
        let mid = (min(bounds.height, metrics.field) / 2).rounded()
        glyph.frame = NSRect(x: x - 2, y: mid - glyphSide / 2, width: glyphSide, height: glyphSide)
        x += metrics.stripGlyph + gap
        var trailing = bounds.width - metrics.sendInset
        if !undo.isHidden {
            undo.sizeToFit()
            let size = undo.alignmentRect(forFrame: undo.frame).size
            undo.frame = undo.frame(forVisualRect: NSRect(x: trailing - size.width, y: mid - size.height / 2, width: size.width, height: size.height))
            trailing -= size.width + gap
        }
        let leadWidth = ceil(lead.attributedStringValue.size().width) + 4
        let leadHeight = ReaderFonts.fieldHeight(lead)
        lead.frame = NSRect(x: x, y: (mid - leadHeight / 2).rounded(), width: min(leadWidth, max(0, trailing - x)), height: leadHeight)
        x = lead.frame.maxX + gap - 4
        if !show.isHidden {
            show.sizeToFit()
            let size = show.alignmentRect(forFrame: show.frame).size
            show.frame = show.frame(forVisualRect: NSRect(x: x, y: mid - size.height / 2, width: size.width, height: size.height))
            x += size.width + gap
        }
        let detailHeight = ReaderFonts.fieldHeight(detail)
        detail.frame = NSRect(x: x, y: (mid - detailHeight / 2).rounded(), width: max(0, trailing - x), height: detailHeight)
        let head = Quire.Layout.Progress.contrailHead
        contrail.frame = NSRect(x: 0, y: bounds.height - 1 - head / 2 - 1, width: bounds.width, height: head)
        pointerRegionsDidChange()
    }

    // MARK: Pointer

    /// During the countdown a click anywhere outside Undo brings the field back for a new reply: the hand. An outcome
    /// only reports, so the arrow, around its Show link. Its buttons keep their own (§4.17).
    var pointerRegions: [QuirePointerRegion] {
        let counting: Bool
        if case .counting = state { counting = true } else { counting = false }
        return QuirePointerRegion.regions(bounds, cursor: counting ? .pointingHand : .arrow, cutting: childPointerAreas())
    }

    override func resetCursorRects() {
        addPointerRects()
    }

    override func viewDidHide() {
        super.viewDidHide()
        pointerRegionsDidChange()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        pointerRegionsDidChange()
    }

    override func mouseDown(with event: NSEvent) {
        if case .counting = state {
            onDismiss?()
            return
        }
        super.mouseDown(with: event)
    }

    @objc private func undoPressed() { onUndo?() }
    @objc private func showPressed() { onShow?() }
}
