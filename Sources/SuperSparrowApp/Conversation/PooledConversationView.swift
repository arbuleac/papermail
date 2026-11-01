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
        let completion: (Bool) -> Void
    }

    private(set) var webView: WKWebView
    /// Conversation whose cards are in the DOM (set as soon as a render is requested).
    var renderedID: ConversationID?
    /// What was rendered, so a stale pre-render can be detected and refreshed on show.
    var renderedPayload: RenderPayload?
    var isReady = false
    var renderInFlight = false
    /// Monotonic tick from the pool; the smallest value among free slots is evicted first.
    var lastUsed: UInt64 = 0
    /// Bumped on every render request so a late completion for an older render is ignored.
    var generation: UInt64 = 0
    /// A render requested before the shell signalled readiness; replayed on `ssReady`.
    var pendingRender: PendingRender?

    init(webView: WKWebView) {
        self.webView = webView
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
        renderInFlight = false
        renderedID = nil
        renderedPayload = nil
        pendingRender = nil
        generation &+= 1
    }
}
