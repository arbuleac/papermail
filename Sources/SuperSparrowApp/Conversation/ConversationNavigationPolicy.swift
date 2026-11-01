import AppKit
import SSCore
import WebKit

/// Navigation and UI delegate shared by every pooled web view.
///
/// The shell is the only document a reader view ever shows: the initial `loadHTMLString` is allowed,
/// `srcdoc` body frames are allowed, link clicks go to the default browser, and everything else is cancelled.
@MainActor
final class ConversationNavigationPolicy: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum Decision: Equatable {
        case allow
        case openExternally
        case cancel
    }

    var onProcessTerminated: ((WKWebView) -> Void)?
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

    static func decision(for url: URL?, navigationType: WKNavigationType, isMainFrame: Bool) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if navigationType == .linkActivated {
            return isOpenableExternally(scheme) ? .openExternally : .cancel
        }
        // The shell document itself, loaded once per view.
        if scheme == "ss-shell", isMainFrame, navigationType == .other { return .allow }
        // Body iframes start as about:blank and then load their srcdoc.
        if scheme == "about", !isMainFrame { return .allow }
        return .cancel
    }

    static func isOpenableExternally(_ scheme: String) -> Bool {
        ["http", "https", "mailto"].contains(scheme)
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        switch Self.decision(for: url, navigationType: navigationAction.navigationType, isMainFrame: isMainFrame) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            if let url { openExternally(url) }
            decisionHandler(.cancel)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onProcessTerminated?(webView)
    }

    // MARK: WKUIDelegate

    /// `target="_blank"` links ask for a new web view; there is never one, so they go to the browser.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), Self.isOpenableExternally(scheme) {
            openExternally(url)
        }
        return nil
    }
}
