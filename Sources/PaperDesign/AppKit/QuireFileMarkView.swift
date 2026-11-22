import AppKit

/// A file mark as a view (spec §5.57), its side the design grid unless given another: for the Design Gallery and for
/// surfaces that lay the mark out as a subview. Chips that draw their own content call `QuireFileMark.draw(in:)` instead.
/// Decorative: the name and kind beside it are what VoiceOver reads.
@MainActor
public final class QuireFileMarkView: NSView {
    public var mark: QuireFileMark? {
        didSet { if mark != oldValue { needsDisplay = true } }
    }

    private let side: CGFloat

    public init(_ mark: QuireFileMark?, side: CGFloat = Quire.Layout.FileMark.grid) {
        self.mark = mark
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("QuireFileMarkView is built in code") }

    override public var isFlipped: Bool { true }
    override public var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override public func isAccessibilityElement() -> Bool { false }

    override public func draw(_ dirtyRect: NSRect) {
        let length = min(bounds.width, bounds.height)
        mark?.draw(in: NSRect(x: bounds.midX - length / 2, y: bounds.midY - length / 2, width: length, height: length))
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
