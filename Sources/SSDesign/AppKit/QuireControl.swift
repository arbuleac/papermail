import AppKit

/// The base of every interactive Quire control: hover from a tracking area, press tracking, keyboard focus
/// with the Quire ring, window key state, the forced `displayState`, and redraws when the appearance or
/// `QuireEnvironment` changes (spec §5 conventions, §8.2).
///
/// Geometry: the frame is the control's visual rect grown by `QuireFocusRing.margin` on every side, reported
/// as `alignmentRectInsets`, so the ring is drawn inside the frame (AppKit clips a view's drawing to it) while
/// Auto Layout aligns, sizes and spaces the visual rect. `intrinsicContentSize` is therefore the token size.
/// Clicks count inside the visual rect grown to at least `button.minHit` (24 × 24, §4.14), never in the rest
/// of the margin.
///
/// Subclasses draw in `draw(_:)` from `interactionState`, `showsFocusRing` and `isWindowKey`, and put what a
/// click, Space or VoiceOver's press does in their override of `activate()`.
@MainActor
open class QuireControl: NSControl {
    // MARK: Forced states

    /// Forces the look of one state (rest, hover, pressed or focused) whatever the pointer and the first
    /// responder say, so a gallery or a specimen can show every state of a control at once. nil, the default,
    /// draws the live state. Only drawing changes; the control still works.
    public var displayState: QuireDisplayState? {
        didSet { if oldValue != displayState { stateDidChange() } }
    }

    /// Forces the window key state the control draws for (primary buttons draw as secondary, underlines turn
    /// `ink3` and rings disappear when the window is not key, §3.4). nil follows the window.
    public var windowKeyOverride: Bool? {
        didSet { if oldValue != windowKeyOverride { stateDidChange() } }
    }

    /// When true the control joins the key-view loop only while Full Keyboard Access is on, as the composer's
    /// Cc and Bcc buttons do (§5.20). Off by default: Quire puts its controls in the Tab order (§3.4).
    public var requiresFullKeyboardAccess = false

    // MARK: Live state

    /// The pointer is over the hit rect.
    public internal(set) var isHovered = false
    /// The mouse went down on the control and is still inside its hit rect.
    public internal(set) var isPressed = false
    private var isTrackingPress = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        focusRingType = .none
        NotificationCenter.default.addObserver(self, selector: #selector(quireEnvironmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    open override var isFlipped: Bool { true }

    open override var isEnabled: Bool {
        didSet {
            if oldValue != isEnabled {
                if !isEnabled { isPressed = false; isTrackingPress = false }
                stateDidChange()
            }
        }
    }

    // MARK: Geometry

    open override var alignmentRectInsets: NSEdgeInsets {
        let m = QuireFocusRing.margin
        return NSEdgeInsets(top: m, left: m, bottom: m, right: m)
    }

    /// The visual rect: the bounds without the ring margin.
    public var bodyRect: NSRect {
        let i = alignmentRectInsets
        return NSRect(x: bounds.minX + i.left, y: bounds.minY + i.top,
                      width: max(0, bounds.width - i.left - i.right), height: max(0, bounds.height - i.top - i.bottom))
    }

    /// The face the ring goes around and the hit rect grows from. The body by default; a button with a keycap
    /// beside it excludes the keycap.
    open var faceRect: NSRect { bodyRect }

    /// Where clicks and hover count: the face, grown to at least 24 × 24 around its centre and kept inside the
    /// bounds.
    open var hitRect: NSRect {
        let face = faceRect
        let minHit = Quire.Layout.Button.minHit
        let dx = max(0, (minHit - face.width) / 2)
        let dy = max(0, (minHit - face.height) / 2)
        return face.insetBy(dx: -dx, dy: -dy).intersection(bounds)
    }

    /// The frame that puts this control's visual rect at `rect` (in the superview's coordinates).
    public func frame(forVisualRect rect: NSRect) -> NSRect {
        frame(forAlignmentRect: rect)
    }

    /// Resizes the frame so the visual rect is the intrinsic size (keeping the current width or height where
    /// the control has no intrinsic one), for layouts that set frames by hand.
    open override func sizeToFit() {
        let intrinsic = intrinsicContentSize
        let current = alignmentRect(forFrame: frame).size
        let size = NSSize(width: intrinsic.width == NSView.noIntrinsicMetric ? current.width : intrinsic.width,
                          height: intrinsic.height == NSView.noIntrinsicMetric ? current.height : intrinsic.height)
        let origin = alignmentRect(forFrame: frame).origin
        frame = frame(forAlignmentRect: NSRect(origin: origin, size: size))
    }

    open override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        guard hitRect.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    // MARK: What to draw

    /// The window key state to draw for.
    public var isWindowKey: Bool { windowKeyOverride ?? window?.isKeyWindow ?? false }

    /// True while this control has keyboard focus. Subclasses that hand focus to a child (a text field's
    /// editor) override it.
    open var hasKeyboardFocus: Bool {
        guard let window else { return false }
        return window.firstResponder === self
    }

    /// Rest, hover or pressed (never `.focused`): the look of the face. Disabled controls are always at rest.
    public var interactionState: QuireDisplayState {
        if let forced = displayState { return forced == .focused ? .rest : forced }
        guard isEnabled else { return .rest }
        if isPressed { return .pressed }
        return isHovered ? .hover : .rest
    }

    /// Whether to draw the focus ring: a forced `.focused`, or keyboard focus in a key window (no first
    /// responder is shown in a window that is not key, §3.4).
    public var showsFocusRing: Bool {
        if let forced = displayState { return forced == .focused }
        return isEnabled && hasKeyboardFocus && isWindowKey
    }

    /// Redraws and lets layer-backed subclasses restyle. Called for every change of what the control shows.
    open func stateDidChange() {
        needsDisplay = true
    }

    // MARK: Hover

    private var hoverArea: NSTrackingArea?

    open override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: hitRect, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    open override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    open override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        hoverDidChange()
        stateDidChange()
    }

    /// Hook for subclasses that show something on hover beyond the face (a reveal button).
    open func hoverDidChange() {}

    // MARK: Press

    open override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTrackingPress = true
        isPressed = true
        pressDidBegin()
        stateDidChange()
    }

    open override func mouseDragged(with event: NSEvent) {
        guard isTrackingPress else { return }
        let inside = hitRect.contains(convert(event.locationInWindow, from: nil))
        if inside != isPressed {
            isPressed = inside
            stateDidChange()
        }
    }

    open override func mouseUp(with event: NSEvent) {
        guard isTrackingPress else { return }
        let inside = hitRect.contains(convert(event.locationInWindow, from: nil))
        isTrackingPress = false
        isPressed = false
        pressDidEnd(activated: inside)
        stateDidChange()
        if inside { activate() }
    }

    /// The mouse went down on the control.
    open func pressDidBegin() {}

    /// The press ended; `activated` is true when it ended inside and `activate()` follows.
    open func pressDidEnd(activated: Bool) {}

    /// What a click, Space, `performClick(_:)` or VoiceOver's press does. Sends the action by default.
    open func activate() {
        sendAction(action, to: target)
    }

    open override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        activate()
    }

    // MARK: Keyboard

    /// Keyboard focus comes from the keyboard. A click never moves it (the window asks while handling the
    /// mouse-down), as with native buttons, so clicking Bold or Send leaves the caret where it was.
    open override var acceptsFirstResponder: Bool {
        guard isEnabled, !refusesFirstResponder else { return false }
        if let event = NSApp?.currentEvent, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            return false
        }
        return true
    }

    open override var canBecomeKeyView: Bool {
        guard super.canBecomeKeyView else { return false }
        return !requiresFullKeyboardAccess || (NSApp?.isFullKeyboardAccessEnabled ?? false)
    }

    open override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { stateDidChange() }
        return accepted
    }

    open override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { stateDidChange() }
        return resigned
    }

    /// Space activates the focused control, as it does a native button.
    open override func keyDown(with event: NSEvent) {
        if isEnabled, !event.isARepeat, event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            activate()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Window and environment

    private weak var observedWindow: NSWindow?

    open override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyDidChange(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: newWindow)
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyDidChange(_:)),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        observedWindow = newWindow
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowKeyDidChange(_ note: Notification) {
        stateDidChange()
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange()
    }

    @objc private func quireEnvironmentDidChange(_ note: Notification) {
        appearanceDidChange()
    }

    /// The appearance, Increase Contrast or Graphite changed: redraw, and re-resolve any layer colours.
    open func appearanceDidChange() {
        needsDisplay = true
    }

    // MARK: Accessibility

    open override func isAccessibilityElement() -> Bool { true }
    open override func isAccessibilityEnabled() -> Bool { isEnabled }

    open override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }

    open override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(faceRect, to: nil))
    }
}
