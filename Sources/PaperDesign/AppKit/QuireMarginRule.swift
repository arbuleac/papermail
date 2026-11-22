import AppKit

/// The margin rule (spec §2, §4.7): a 3 pt rule flush with the leading edge that marks the selection, with
/// square leading corners and 2 pt trailing ones (`border.marginRule`). It is always drawn: `selRule` while its
/// window is key, `selRuleIdle` when it is not (§3.4).
///
/// Rows and tiles that draw by hand call the static `draw(in:isWindowKey:)`; the view wraps it for layouts.
@MainActor
public final class QuireMarginRule: NSView {
    /// Forces the key state drawn; nil follows the window.
    public var windowKeyOverride: Bool? {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    public convenience init(height: CGFloat = Quire.Layout.Row.marginRuleHeight) {
        self.init(frame: NSRect(x: 0, y: 0, width: Quire.Border.MarginRule.width, height: height))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireMarginRule is built in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Quire.Border.MarginRule.width, height: NSView.noIntrinsicMetric)
    }

    private var isWindowKey: Bool { windowKeyOverride ?? window?.isKeyWindow ?? false }

    /// The rule's colour for a window key state.
    public static func color(isWindowKey: Bool) -> NSColor {
        isWindowKey ? .qSelRule : .qSelRuleIdle
    }

    /// Draws the rule filling `rect` (3 pt wide). Corners are square on the leading side and 2 pt on the
    /// trailing side, mirrored in a right-to-left layout.
    public static func draw(in rect: NSRect, isWindowKey: Bool, rightToLeft: Bool = false) {
        let r = min(Quire.Border.MarginRule.radius.max() ?? 2, rect.width / 2, rect.height / 2)
        let path = NSBezierPath()
        let (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        if rightToLeft {
            path.move(to: NSPoint(x: maxX, y: minY))
            path.line(to: NSPoint(x: maxX, y: maxY))
            path.line(to: NSPoint(x: minX + r, y: maxY))
            path.curve(to: NSPoint(x: minX, y: maxY - r), controlPoint1: NSPoint(x: minX, y: maxY), controlPoint2: NSPoint(x: minX, y: maxY))
            path.line(to: NSPoint(x: minX, y: minY + r))
            path.curve(to: NSPoint(x: minX + r, y: minY), controlPoint1: NSPoint(x: minX, y: minY), controlPoint2: NSPoint(x: minX, y: minY))
        } else {
            path.move(to: NSPoint(x: minX, y: minY))
            path.line(to: NSPoint(x: maxX - r, y: minY))
            path.curve(to: NSPoint(x: maxX, y: minY + r), controlPoint1: NSPoint(x: maxX, y: minY), controlPoint2: NSPoint(x: maxX, y: minY))
            path.line(to: NSPoint(x: maxX, y: maxY - r))
            path.curve(to: NSPoint(x: maxX - r, y: maxY), controlPoint1: NSPoint(x: maxX, y: maxY), controlPoint2: NSPoint(x: maxX, y: maxY))
            path.line(to: NSPoint(x: minX, y: maxY))
        }
        path.close()
        color(isWindowKey: isWindowKey).setFill()
        path.fill()
    }

    public override func draw(_ dirtyRect: NSRect) {
        let width = Quire.Border.MarginRule.width
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        let x = rtl ? bounds.maxX - width : bounds.minX
        QuireMarginRule.draw(in: NSRect(x: x, y: bounds.minY, width: width, height: bounds.height),
                             isWindowKey: isWindowKey, rightToLeft: rtl)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(stateDidChange(_:)),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func stateDidChange(_ note: Notification) {
        needsDisplay = true
    }

    public override func isAccessibilityElement() -> Bool { false }
}
