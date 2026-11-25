import AppKit
import PaperCore
import WebKit

/// Navigation and UI delegate shared by every pooled web view.
///
/// The shell is the only document a reader view ever shows: the initial `loadHTMLString` is allowed,
/// `srcdoc` body frames are allowed, link clicks go to the app that opens them (the browser, the composer, FaceTime for a
/// phone number), an in-message anchor scrolls the page to its place, and everything else is cancelled. A link a click does
/// nothing with (`#`, an inline picture's `ss-cid:`) shows no pointing hand (`ConversationShellAssets.bodyCSS`).
///
/// A click on a link with a `target` (`_blank`, a name, `_top`, `_parent`) in a body arrives as a request for a new window,
/// with no target frame, since the body frames allow popups and nothing else (`ConversationShellAssets.bodyFrameSandbox`);
/// it is decided as a body's own link, so it opens or scrolls and is cancelled before WebKit would ask for a web view.
@MainActor
final class ConversationNavigationPolicy: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum Decision: Equatable {
        case allow
        case openExternally
        /// Cancelled, and the shell scrolls to the place in a message this names (`ss.anchor`).
        case moveToAnchor(String)
        case cancel
    }

    var onProcessTerminated: ((WKWebView) -> Void)?
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Block trackers is on (spec §5.60): a link opened from a message goes without its tracking parameters.
    var stripsTrackingParameters = false

    /// What a link opened from a message hands the app that opens it.
    func outgoing(_ url: URL) -> URL {
        guard stripsTrackingParameters else { return url }
        let cleaned = TrackingParameters.stripped(url)
        if cleaned != url { Analytics.send(.linkCleaned) }
        return cleaned
    }

    static func decision(for url: URL?, navigationType: WKNavigationType, isMainFrame: Bool) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if navigationType == .linkActivated {
            if isOpenableExternally(scheme) { return .openExternally }
            return inMessageAnchor(url, isMainFrame: isMainFrame).map { .moveToAnchor($0) } ?? .cancel
        }
        // The shell document itself, loaded once per view.
        if scheme == "ss-shell", isMainFrame, navigationType == .other { return .allow }
        // Body iframes start as about:blank and then load their srcdoc.
        if scheme == "about", !isMainFrame { return .allow }
        return .cancel
    }

    /// The schemes the sanitizer keeps on a link (`URLPolicy`) that another app opens: the links a body's pointing hand
    /// promises a click for (§4.17).
    static func isOpenableExternally(_ scheme: String) -> Bool {
        ["http", "https", "mailto", "tel"].contains(scheme)
    }

    /// The place a link in a body names in its own message, `#ss-…` once the sanitizer has prefixed the ids, or nil. A
    /// body's `srcdoc` document takes the shell's base address, so WebKit asks to load the shell's address with the
    /// fragment into the frame, which would replace the body; the shell scrolls to the place instead. A bare `#` names
    /// no place.
    static func inMessageAnchor(_ url: URL, isMainFrame: Bool) -> String? {
        guard !isMainFrame, let fragment = url.fragment, fragment.hasPrefix("ss-"), fragment.count > 3,
              let hash = url.absoluteString.firstIndex(of: "#") else { return nil }
        let document = String(url.absoluteString[..<hash])
        return [ConversationShellAssets.baseURLString, "about:srcdoc"].contains(document) ? fragment : nil
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        // No target frame: a body's link with a target, asking for a new window. It is a body's link like any other,
        // never the shell's own navigation.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        switch Self.decision(for: url, navigationType: navigationAction.navigationType, isMainFrame: isMainFrame) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            if let url { openExternally(outgoing(url)) }
            decisionHandler(.cancel)
        case .moveToAnchor(let name):
            decisionHandler(.cancel)
            webView.evaluateJavaScript("window.ss && window.ss.anchor(" + ConversationShellAssets.jsStringLiteral(name) + ")")
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onProcessTerminated?(webView)
    }

    // MARK: WKUIDelegate

    /// A click on a body's link with a target never comes here: `decidePolicyFor` opens it and cancels the request for a
    /// new window. Anything else that asks for a web view gets none, and its link goes where a click would send it.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), Self.isOpenableExternally(scheme) {
            openExternally(outgoing(url))
        }
        return nil
    }
}
