import Foundation
import SSCore
import WebKit

/// Serves the shell document at `ss-shell://local/`.
///
/// The shell is loaded with `loadHTMLString` under that base URL so body iframes share its origin, but WebKit
/// only completes such a load when the base scheme has a registered handler; an unregistered custom scheme
/// stalls at about:blank without reporting an error. Registering this handler is what makes the shell load at
/// all. It also answers a plain navigation to the base URL (a reload) with the same document; anything else
/// under the scheme is 404.
@MainActor
final class ShellSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The document every pooled view loaded, symbols included, so a reload gets the same one.
    private let document: String

    init(document: String) {
        self.document = document
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let isShellDocument = url.host == ConversationShellAssets.baseURL?.host && (url.path.isEmpty || url.path == "/")
        guard isShellDocument else {
            SchemeURLSupport.respondNotFound(urlSchemeTask, url: url)
            return
        }
        SchemeURLSupport.respond(
            urlSchemeTask,
            url: url,
            data: Data(document.utf8),
            mimeType: "text/html; charset=utf-8"
        )
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
