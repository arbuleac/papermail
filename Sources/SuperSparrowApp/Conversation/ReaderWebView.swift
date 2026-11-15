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
@MainActor
final class ReaderWebView: WKWebView {
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
