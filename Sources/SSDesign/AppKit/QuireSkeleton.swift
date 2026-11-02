import AppKit

/// Skeleton bars (spec §5.10): static `fill` shapes, radius 3, standing in for content on an account's first
/// sync or a body being fetched. They never shimmer, and skeleton to content is an instant swap.
///
/// They appear only after `dur.skeletonDelay` (300 ms): `reveal()` shows the view after the delay unless
/// `conceal()` comes first. List rows that draw by hand use the static `draw(_:in:)`.
@MainActor
public final class QuireSkeleton: NSView {
    public var layout: Layout {
        didSet { if oldValue != layout { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    private var revealTimer: Timer?

    public init(_ layout: Layout) {
        self.layout = layout
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: QuireSkeleton.height(of: layout) ?? 10))
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireSkeleton is built in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: QuireSkeleton.height(of: layout) ?? NSView.noIntrinsicMetric)
    }

    /// The fixed height a layout needs, when it has one.
    public static func height(of layout: Layout) -> CGFloat? {
        let s = Quire.Layout.Skeleton.self
        switch layout {
        case .bar, .circle: return nil
        case .row: return Quire.Layout.Row.height
        case .compactRow: return Quire.Layout.RowCompact.height
        case .body: return CGFloat(s.bodyBars.count) * s.bodyBarHeight + CGFloat(s.bodyBars.count - 1) * s.bodyBarGap
        }
    }

    // MARK: Reveal

    /// Shows the skeleton after `delay` unless `conceal()` comes first.
    public func reveal(after delay: TimeInterval = Quire.Motion.skeletonDelay) {
        revealTimer?.invalidate()
        isHidden = true
        guard delay > 0 else { isHidden = false; return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.revealTimer = nil
                self?.isHidden = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// Hides the skeleton at once (content arrived), or keeps it from appearing.
    public func conceal() {
        revealTimer?.invalidate()
        revealTimer = nil
        isHidden = true
    }

    // MARK: Geometry

    /// Fixed jitter, as multiples of `skeleton.widthJitter` (±0.3): rows vary in width without randomness, so
    /// a redraw never changes them.
    static let jitter: [CGFloat] = [0, -0.8, -0.6, 0.4, -0.25, 0.65, -1, 0.15, 0.9, -0.4]

    static func jittered(_ width: CGFloat, index: Int) -> CGFloat {
        let n = jitter.count
        return width * (1 + Quire.Layout.Skeleton.widthJitter * jitter[((index % n) + n) % n])
    }

    /// The shapes a layout draws inside `rect`: bars (radius 3) and circles.
    public static func shapes(_ layout: Layout, in rect: NSRect) -> [(rect: NSRect, isCircle: Bool)] {
        let s = Quire.Layout.Skeleton.self
        func bar(_ v: [CGFloat], index: Int?) -> NSRect {
            let width = index.map { jittered(v[2], index: $0) } ?? v[2]
            return NSRect(x: rect.minX + v[0], y: rect.minY + v[1], width: min(width, rect.width - v[0] - Quire.Layout.Row.trailing), height: v[3])
        }
        func time(_ v: [CGFloat], top: CGFloat) -> NSRect {
            NSRect(x: rect.maxX - Quire.Layout.Row.trailing - v[0], y: rect.minY + top, width: v[0], height: v[1])
        }
        switch layout {
        case .bar:
            return [(rect, false)]
        case .circle:
            let d = min(rect.width, rect.height)
            return [(NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d), true)]
        case .row(let index):
            return [
                (NSRect(x: rect.minX + s.circleX, y: rect.minY + s.circleY, width: s.circle, height: s.circle), true),
                (bar(s.senderBar, index: index * 3), false),
                (time(s.timeBar, top: s.senderBar[1]), false),
                (bar(s.subjectBar, index: index * 3 + 1), false),
                (bar(s.snippetBar, index: index * 3 + 2), false),
            ]
        case .compactRow(let index):
            let c = Quire.Layout.RowCompact.self
            return [
                (bar(c.skeletonSenderBar, index: index * 2), false),
                (time(c.skeletonTimeBar, top: c.skeletonSenderBar[1]), false),
                (bar(c.skeletonLine2Bar, index: index * 2 + 1), false),
            ]
        case .body:
            return s.bodyBars.enumerated().map { i, share in
                (NSRect(x: rect.minX, y: rect.minY + CGFloat(i) * (s.bodyBarHeight + s.bodyBarGap),
                        width: (rect.width * share).rounded(), height: s.bodyBarHeight), false)
            }
        }
    }

    /// Draws a layout's shapes in `fill` in the current context.
    public static func draw(_ layout: Layout, in rect: NSRect) {
        for shape in shapes(layout, in: rect) {
            if shape.isCircle {
                QuireDraw.fillCircle(shape.rect, .qFill)
            } else {
                QuireDraw.fill(shape.rect, radius: Quire.Layout.Skeleton.barRadius, .qFill)
            }
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        QuireSkeleton.draw(layout, in: bounds)
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .busyIndicator }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? "Loading" }
}
