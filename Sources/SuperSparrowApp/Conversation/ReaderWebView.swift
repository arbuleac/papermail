import AppKit
import SSDesign
import WebKit

/// The reader's web view. It tells its shell when the page may have focus again, by becoming first responder or by
/// its window becoming key: the shell stops watching which body holds focus while the page has none (so an idle
/// reader keeps no 300 ms interval), and focus returning to a body raises no event the shell can hear.
///
/// It also keeps the colour under its page, the desk shown while a render lands or the page overscrolls (spec §4.1).
/// WebKit keeps the colour it is given as a fixed one, so it is resolved here under this view's appearance, and again
/// whenever that changes or the theme does (`WebViewPool`); otherwise a theme's desk would flash as Study's.
@MainActor
final class ReaderWebView: WKWebView {
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
