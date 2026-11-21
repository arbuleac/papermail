import AppKit

/// A split button (spec §5.23): one face in a `QuireButton` size, cut by a divider into the action segment (a glyph, the
/// label and its keycap inside the face) and the menu segment (a chevron that opens the action's options). Send is one,
/// in the composer's bar and the quick reply's tool row.
///
/// The face is primary: `accentFill` with `onAccent` ink, hover and press per segment. It draws as a secondary button while
/// its window is not key (§3.4), and quiet (`fill`) while the action cannot act, though the menu may still open: the
/// options are the user's to choose while Send waits for a recipient. The keycap is the §5.36 On a fill cap, in the
/// label's ink. Each segment is a `QuireControl` of its own (`actionSegment`, `menuSegment`), so the Tab loop, VoiceOver
/// and the pointer meet two buttons; this view lays them out and draws the focus ring of the one that has the keyboard,
/// around that segment and across the divider, its gap painted in `surfaceColor` where it crosses the other half.
///
/// Geometry follows `QuireControl`: the frame is the face grown by `QuireFocusRing.margin` on every side, reported as
/// `alignmentRectInsets`, so `intrinsicContentSize` is the face's size and `frame(forVisualRect:)` places the face.
@MainActor
public final class QuireSplitButton: NSView {
    public let actionSegment: QuireSplitSegment
    public let menuSegment: QuireSplitSegment

    public var size: QuireButton.Size {
        didSet {
            guard oldValue != size else { return }
            for segment in [actionSegment, menuSegment] {
                segment.invalidateIntrinsicContentSize()
                segment.needsDisplay = true
            }
            segmentContentDidChange()
        }
    }

    /// The surface the button sits on (`paper` in the composer's bar, `sheet` in the quick reply's field): the focus
    /// ring's gap is painted in it where the ring crosses the other segment, so the focused half stands apart.
    public var surfaceColor: NSColor = .qPaper {
        didSet { ring.needsDisplay = true }
    }

    /// Forces the window key state both segments draw for (a gallery, a render); nil follows the window.
    public var windowKeyOverride: Bool? {
        get { actionSegment.windowKeyOverride }
        set {
            actionSegment.windowKeyOverride = newValue
            menuSegment.windowKeyOverride = newValue
        }
    }

    private let ring = RingView()

    public init(title: String, symbolName: String? = nil, size: QuireButton.Size = .regular, keycap: String? = nil,
                menuAccessibilityLabel: String) {
        self.size = size
        actionSegment = QuireSplitSegment(kind: .action, title: title, symbolName: symbolName)
        menuSegment = QuireSplitSegment(kind: .menu)
        super.init(frame: .zero)
        actionSegment.keycap = keycap
        menuSegment.setAccessibilityLabel(menuAccessibilityLabel)
        for segment in [actionSegment, menuSegment] {
            segment.split = self
            addSubview(segment)
        }
        ring.split = self
        addSubview(ring)
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireSplitButton is built in code") }

    public override var isFlipped: Bool { true }

    // MARK: Geometry

    public override var alignmentRectInsets: NSEdgeInsets {
        let m = QuireFocusRing.margin
        return NSEdgeInsets(top: m, left: m, bottom: m, right: m)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: actionSegment.intrinsicContentSize.width + menuSegment.intrinsicContentSize.width, height: size.height)
    }

    /// The face: the bounds without the ring margin.
    public var faceRect: NSRect {
        let m = QuireFocusRing.margin
        return bounds.insetBy(dx: m, dy: m)
    }

    /// The frame that puts the face at `rect` (in the superview's coordinates).
    public func frame(forVisualRect rect: NSRect) -> NSRect {
        frame(forAlignmentRect: rect)
    }

    /// Only the segments take clicks: the ring margin around the face is the neighbours' as much as this button's.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    public override func layout() {
        super.layout()
        let face = faceRect
        let actionWidth = min(face.width, actionSegment.intrinsicContentSize.width)
        actionSegment.frame = actionSegment.frame(forVisualRect: NSRect(x: face.minX, y: face.minY, width: actionWidth, height: face.height))
        menuSegment.frame = menuSegment.frame(forVisualRect: NSRect(x: face.minX + actionWidth, y: face.minY,
                                                                    width: max(0, face.width - actionWidth), height: face.height))
        ring.frame = bounds
    }

    // MARK: Look

    /// The face both segments share (§5.23 States).
    enum Look {
        /// `accentFill`, `onAccent` ink: the primary face.
        case accent
        /// `raised` with a `ruleStrong` edge: the secondary look of a primary in a window that is not key (§3.4).
        case raised
        /// `fill`: the action cannot act (no recipient, a reply still streaming in); the menu keeps its own state.
        case quiet
    }

    var look: Look {
        guard actionSegment.isEnabled else { return .quiet }
        return actionSegment.isWindowKey ? .accent : .raised
    }

    // MARK: Segment changes

    func segmentStateDidChange(_ segment: QuireSplitSegment) {
        // The action's enabled state and the window's key state set the face the other half draws too.
        (segment === actionSegment ? menuSegment : actionSegment).needsDisplay = true
        ring.needsDisplay = true
    }

    func segmentContentDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        // Hosts lay their bars out by hand: a wider label or a keycap that comes or goes moves what follows Send.
        superview?.needsLayout = true
        ring.needsDisplay = true
    }

    /// The segment whose ring shows now, if any.
    var focusedSegment: QuireSplitSegment? {
        [actionSegment, menuSegment].first { !$0.isHidden && $0.showsFocusRing }
    }

    /// The ring around `segment`'s face in this view's coordinates: round on the button's outer side, square at the divider,
    /// as the face is. Internal for the tests.
    func ringPath(around segment: QuireSplitSegment, gap: CGFloat, width: CGFloat) -> NSBezierPath {
        let face = convert(segment.faceRect, from: segment)
        let grow = gap + width / 2
        let rect = face.insetBy(dx: -grow, dy: -grow)
        let outer = min(size.cornerRadius + grow, rect.height / 2)
        let joined = grow
        let leading = segment.kind == .action ? outer : joined
        let trailing = segment.kind == .action ? joined : outer
        return Self.roundedRect(rect, leading: leading, trailing: trailing)
    }

    /// A rect with the given corner radius on its leading (minX) and trailing (maxX) corners, in a flipped view.
    private static func roundedRect(_ r: NSRect, leading: CGFloat, trailing: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX + leading, y: r.minY))
        path.line(to: NSPoint(x: r.maxX - trailing, y: r.minY))
        path.appendArc(withCenter: NSPoint(x: r.maxX - trailing, y: r.minY + trailing), radius: trailing, startAngle: 270, endAngle: 0)
        path.line(to: NSPoint(x: r.maxX, y: r.maxY - trailing))
        path.appendArc(withCenter: NSPoint(x: r.maxX - trailing, y: r.maxY - trailing), radius: trailing, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: r.minX + leading, y: r.maxY))
        path.appendArc(withCenter: NSPoint(x: r.minX + leading, y: r.maxY - leading), radius: leading, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: r.minX, y: r.minY + leading))
        path.appendArc(withCenter: NSPoint(x: r.minX + leading, y: r.minY + leading), radius: leading, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }

    /// Draws the focused segment's ring: its gap first, in the surface colour where it lies over the other half, then the
    /// ring itself (§4.1: 2 pt, 3 pt in Increase Contrast; the gap 2 pt around the accent, 1 pt otherwise).
    fileprivate func drawRing() {
        guard let segment = focusedSegment else { return }
        let width = QuireFocusRing.currentWidth
        let gap = look == .accent ? QuireFocusRing.gapOnFill : QuireFocusRing.gap
        let other = segment === actionSegment ? menuSegment : actionSegment
        if gap > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: convert(other.faceRect, from: other)).addClip()
            let channel = ringPath(around: segment, gap: 0, width: gap)
            channel.lineWidth = gap
            surfaceColor.setStroke()
            channel.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        let path = ringPath(around: segment, gap: gap, width: width)
        path.lineWidth = width
        NSColor.qFocus.setStroke()
        path.stroke()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ring.needsDisplay = true
    }

    // MARK: Accessibility

    /// A container: VoiceOver meets its two segments.
    public override func isAccessibilityElement() -> Bool { false }
}

/// Draws the split button's focus ring over both segments; clicks pass through it.
@MainActor
private final class RingView: NSView {
    weak var split: QuireSplitButton?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        split?.drawRing()
    }
}
