import AppKit

/// The one verb on a slip (spec §5.30, §5.31): “Undo” in `bodyStrong` `onSlip`, then its keycap 6 pt after it,
/// inside the action (a slip action has no face for a keycap to sit beside). 26 pt high, padding 8, radius 5.
///
/// At rest it has no fill (the toast's divider marks it as a control) or, with `showsRestingOutline`, a 1 pt
/// `onSlipEdge` outline (the undo panel, which has no divider). Hover and press take `slipHover` /
/// `slipPressed` and switch the keycap legend from `onSlip2` to `onSlip`; focus is the ring in `onSlip`.
@MainActor
public final class QuireSlipActionButton: QuireControl {
    public var title: String {
        didSet { if oldValue != title { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    /// The keycap legend (“Z”, “⌘Z”); nil hides it (an error toast's action, or when a newer toast owns ⌘Z).
    public var keycap: String? {
        didSet { if oldValue != keycap { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    public var showsRestingOutline = false {
        didSet { needsDisplay = true }
    }

    public init(title: String, keycap: String? = nil, target: AnyObject? = nil, action: Selector? = nil) {
        self.title = title
        self.keycap = keycap
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireSlipActionButton is built in code") }

    private var titleString: NSAttributedString { QuireDraw.line(title, .bodyStrong, .qOnSlip) }

    public override var intrinsicContentSize: NSSize {
        let t = Quire.Layout.Toast.self
        var width = 2 * t.actionPadX + QuireDraw.width(titleString)
        if let keycap { width += t.actionKeycapGap + QuireKeycap.size(for: keycap, style: .onSlip).width }
        return NSSize(width: width, height: t.action)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let t = Quire.Layout.Toast.self
        let face = faceRect
        let radius = t.actionRadius
        let state = interactionState
        switch state {
        case .pressed: QuireDraw.fill(face, radius: radius, .qSlipPressed)
        case .hover: QuireDraw.fill(face, radius: radius, .qSlipHover)
        case .rest, .focused:
            if showsRestingOutline { QuireDraw.strokeInside(face, radius: radius, width: 1, .qOnSlipEdge) }
        }
        let lineHeight = QuireFont.Role.bodyStrong.lineHeight
        let title = QuireDraw.line(self.title, .bodyStrong, isEnabled ? .qOnSlip : .qOnSlip2)
        let titleWidth = QuireDraw.width(title)
        QuireDraw.draw(title, x: face.minX + t.actionPadX, top: (face.midY - lineHeight / 2).rounded(),
                       maxWidth: titleWidth + 1, lineHeight: lineHeight)
        if let keycap {
            let size = QuireKeycap.size(for: keycap, style: .onSlip)
            let rect = NSRect(x: face.minX + t.actionPadX + titleWidth + t.actionKeycapGap,
                              y: (face.midY - size.height / 2).rounded(), width: size.width, height: size.height)
            QuireKeycap.draw(keycap, style: .onSlip, highlighted: state != .rest && isEnabled, in: rect)
        }
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: radius, gap: QuireFocusRing.gap, color: .qOnSlip)
        }
    }

    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? title }
}
