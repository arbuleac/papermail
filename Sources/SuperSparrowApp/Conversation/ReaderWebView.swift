import AppKit
import WebKit

/// The reader's web view. It tells its shell when the page may have focus again, by becoming first responder or by
/// its window becoming key: the shell stops watching which body holds focus while the page has none (so an idle
/// reader keeps no 300 ms interval), and focus returning to a body raises no event the shell can hear.
@MainActor
final class ReaderWebView: WKWebView {
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
