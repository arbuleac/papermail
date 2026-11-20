import AppKit
import ObjectiveC
import SSDesign
import WebKit

/// The reader's web view. It tells its shell when the page may have focus again, by becoming first responder or by
/// its window becoming key: the shell stops watching which body holds focus while the page has none (so an idle
/// reader keeps no 300 ms interval), and focus returning to a body raises no event the shell can hear.
///
/// It also keeps the colour under its page, the desk shown while a render lands or the page overscrolls (spec §4.1).
/// WebKit keeps the colour it is given as a fixed one, so it is resolved here under this view's appearance, and again
/// whenever that changes or the theme does (`WebViewPool`); otherwise a theme's desk would flash as Study's.
///
/// While keyboard focus in its page is on an address in a sheet header (spec §5.14), Edit › Copy and ⌘C copy that address
/// through the app, whatever text the page has selected, since keyboard focus is the user's latest choice; otherwise both
/// are WebKit's. This is answered natively rather than through the page's `copy` event: cancelling that event lets WebKit
/// write its own, empty, data to the pasteboard, which can land after the app's write and erase it.
///
/// An attachment chip, or Download all, is dragged out natively (spec §5.17): the shell reports a press on one
/// (`ConversationScriptMessage.AttachmentPress`), and the first drag of the pointer past the threshold is not WebKit's but
/// starts the app's own session, in that very event. A drag of the app's attachments is refused over the page.
@MainActor
final class ReaderWebView: WKWebView {
    /// How far the pointer moves, pressed, before a press on a chip becomes a drag (`dragCard.threshold`): WebKit's own
    /// threshold for a drag that is not a link's or an image's, and the composer's for a token.
    static let dragThreshold: CGFloat = Quire.Layout.DragCard.threshold

    /// Starts a drag of the pressed files with the event that crossed the threshold; true when one started.
    var onAttachmentDrag: ((ConversationScriptMessage.AttachmentPress, NSEvent) -> Bool)?

    /// The primary press under way, where it is in this view: set on mouse-down, gone on mouse-up or once a drag starts.
    private var press: (event: NSEvent, location: NSPoint)?
    /// The files the shell said the press is on, accepted only for the press under way.
    private var armedPress: ConversationScriptMessage.AttachmentPress?

    /// Page points to view points: the pinch magnification, 1 unless the user zoomed.
    var pageScale: CGFloat { magnification }
    /// Called when this view, inside a window, takes a new appearance: the pool gives it to its views outside any window,
    /// which AppKit does not tell.
    var onWindowAppearanceChange: ((NSAppearance) -> Void)?
    /// Whether the shell last said keyboard focus is on an address in a sheet header.
    var hasFocusedAddress: () -> Bool = { false }
    /// Copies that address. The reader beeps when it cannot, once: a beep here as well would make two for one refusal.
    var copyFocusedAddress: () -> Void = {}

    @objc func copy(_ sender: Any?) {
        if hasFocusedAddress() {
            copyFocusedAddress()
            return
        }
        copyAsWebKitDoes(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), hasFocusedAddress() { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// WebKit's own Edit › Copy, as `super` would call it: WKWebView implements the standard `copy:` action without
    /// declaring it in its headers, so Swift cannot name it through `super`.
    private func copyAsWebKitDoes(_ sender: Any?) {
        typealias Action = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let selector = #selector(copy(_:))
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        unsafeBitCast(method_getImplementation(method), to: Action.self)(self, selector, sender as AnyObject?)
    }

    // MARK: Dragging attachments out

    override func mouseDown(with event: NSEvent) {
        press = (event, convert(event.locationInWindow, from: nil))
        armedPress = nil
        super.mouseDown(with: event)
    }

    /// The shell's word that the press under way is on `attachmentPress`'s chips (or on Download all). A word that comes
    /// late, after the press it was about ended, or names another place, is dropped: only the press under way, at the point
    /// it was made, may drag.
    func armAttachmentDrag(_ attachmentPress: ConversationScriptMessage.AttachmentPress) {
        guard let press else { return }
        let scale = pageScale
        let point = NSPoint(x: attachmentPress.point.x * scale, y: attachmentPress.point.y * scale)
        guard hypot(point.x - press.location.x, point.y - press.location.y) <= 2 else { return }
        armedPress = attachmentPress
    }

    /// True while a press the shell placed on attachments waits for the pointer to move (tests read it).
    var isAttachmentDragArmed: Bool { armedPress != nil }

    override func mouseDragged(with event: NSEvent) {
        if let armed = armedPress, let press {
            let location = convert(event.locationInWindow, from: nil)
            if hypot(location.x - press.location.x, location.y - press.location.y) >= Self.dragThreshold {
                armedPress = nil
                if onAttachmentDrag?(armed, event) == true {
                    self.press = nil
                    releasePress(press.event)
                    return
                }
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        press = nil
        armedPress = nil
        super.mouseUp(with: event)
    }

    /// The drag session takes the pointer from here, and its release with it: WebKit would hold the press forever. So it
    /// is handed a mouse-up where the press began, as WebKit does after a drag of its own; the shell, told first that a
    /// drag started, swallows the click that mouse-up makes.
    private func releasePress(_ down: NSEvent) {
        guard let window, let up = NSEvent.mouseEvent(with: .leftMouseUp, location: down.locationInWindow, modifierFlags: down.modifierFlags,
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: down.eventNumber, clickCount: down.clickCount,
                                                      pressure: 0) else { return }
        super.mouseUp(with: up)
    }

    // The page takes no attachment of the app's own: dropping a chip back on a message does nothing, and shows nothing.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if AttachmentPasteboard.carriesReference(sender.draggingPasteboard) { return [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if AttachmentPasteboard.carriesReference(sender.draggingPasteboard) { return [] }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, AttachmentPasteboard.carriesReference(sender.draggingPasteboard) { return }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if AttachmentPasteboard.carriesReference(sender.draggingPasteboard) { return false }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if AttachmentPasteboard.carriesReference(sender.draggingPasteboard) { return false }
        return super.performDragOperation(sender)
    }

    func updateUnderPageColour() {
        var colour = NSColor.qCanvas
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colour = NSColor.qCanvas.usingColorSpace(.sRGB) ?? NSColor.qCanvas
        }
        underPageBackgroundColor = colour
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateUnderPageColour()
        // WebKit may turn `prefers-color-scheme` for the page before it delivers the media `change` event the shell
        // listens for, and a shell that reads it in between keeps the old half of the theme; told here, it never does.
        // The next turn, so WebKit has the appearance first; the shell acts once per change, whoever tells it.
        DispatchQueue.main.async { [weak self] in
            self?.evaluateJavaScript("window.ss && window.ss.appearanceChanged && window.ss.appearanceChanged()") { _, _ in }
        }
        if window != nil { onWindowAppearanceChange?(effectiveAppearance) }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { tellShellFocusChanged() }
        return became
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: newWindow)
        }
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        tellShellFocusChanged()
    }

    private func tellShellFocusChanged() {
        evaluateJavaScript("window.ss && window.ss.focusChanged && window.ss.focusChanged()") { _, _ in }
    }
}
