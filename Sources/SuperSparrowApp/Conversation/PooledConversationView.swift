import SSCore
import WebKit

/// One slot of the `WebViewPool`: a warm web view plus what it currently shows.
///
/// The web view is replaced (not reloaded) after a content-process crash, so callers hold the slot,
/// never the `WKWebView` itself.
@MainActor
final class PooledConversationView {
    struct PendingRender {
        let id: ConversationID
        let payload: RenderPayload
        let inputs: RenderInputs
        let completion: (Bool) -> Void
    }

    private(set) var webView: WKWebView
    /// Conversation whose cards are in the DOM (set as soon as a render is requested).
    var renderedID: ConversationID?
    /// What was rendered, minus body bytes, so a stale slot is detected without reading bodies back.
    var renderedInputs: RenderInputs?
    var isReady = false
    /// Generations and waiters for the slot's renders; see `SlotRenderTracker`.
    var tracker = SlotRenderTracker()
    /// Monotonic tick from the pool; the smallest value among free slots is evicted first.
    var lastUsed: UInt64 = 0
    /// A render requested before the shell signalled readiness; replayed on `ssReady`.
    var pendingRender: PendingRender?
    /// The page's keyboard focus is on an elision mark or a Download control, as its shell last said. Kept per slot, on
    /// screen or not, because a slot swapped back in still has its page's focus.
    var markFocused = false
    /// The page's keyboard focus is on an attachment chip or its Download button, where ← → move along the files.
    var arrowsFocused = false
    /// The messages this page shows in the sender's colours, as its shell last said, for View › Original Colors'
    /// checkmark. Kept per slot, since each shell remembers its own switches and a slot swapped in shows what it holds.
    var originalColorsShown: Set<MessageID> = []

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// True from a render request until it lands, whoever requested it.
    var renderInFlight: Bool { tracker.isInFlight }

    /// Completion of the render `generation`: `completion` learns whether it landed and, when it was the
    /// latest render, so does every waiter. The tracker hands the waiters back instead of running them,
    /// so a waiter that starts the next render never overlaps this bookkeeping.
    func renderDidFinish(generation: UInt64, succeeded: Bool, completion: (Bool) -> Void) {
        switch tracker.finish(generation) {
        case .superseded:
            completion(false)
        case .landed(let waiters):
            completion(succeeded)
            for waiter in waiters { waiter(succeeded) }
        }
    }

    /// Swaps in a fresh web view at the same place in the view hierarchy and forgets everything rendered.
    func replaceWebView(with replacement: WKWebView) {
        if let superview = webView.superview {
            replacement.frame = webView.frame
            replacement.autoresizingMask = webView.autoresizingMask
            superview.addSubview(replacement, positioned: .above, relativeTo: webView)
            webView.removeFromSuperview()
        }
        webView = replacement
        isReady = false
        renderedID = nil
        renderedInputs = nil
        pendingRender = nil
        markFocused = false
        arrowsFocused = false
        originalColorsShown = []
        let waiters = tracker.reset()
        for waiter in waiters { waiter(false) }
    }
}
