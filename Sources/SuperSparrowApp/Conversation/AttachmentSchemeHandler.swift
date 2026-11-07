import Foundation
import SSCore
import WebKit

/// Serves `ss-attachment://<account>/<message>/<attachmentID>` so the shell can reference any part
/// by its provider id (non-cid inline images, previews). Bytes come from the client's attachment cache.
@MainActor
final class AttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let client: MailClient
    private var inFlight: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(client: MailClient) {
        self.client = client
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let target = SchemeURLSupport.target(of: url) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let stored = try? client.store.body(for: target.message)
        let info = stored?.body.attachments.first { $0.id == target.key }
        let key = ObjectIdentifier(urlSchemeTask)
        let client = self.client
        inFlight[key] = Task { [weak self] in
            let data = try? await client.attachmentData(for: target.message, attachmentID: target.key,
                                                        expectedSize: info?.sizeBytes ?? 0, progress: nil)
            guard let self, self.inFlight[key] != nil else { return }
            self.inFlight[key] = nil
            if let data {
                SchemeURLSupport.respond(
                    urlSchemeTask,
                    url: url,
                    data: data,
                    mimeType: info?.mimeType ?? "application/octet-stream",
                    filename: info?.filename
                )
            } else {
                SchemeURLSupport.respondNotFound(urlSchemeTask, url: url)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }
}
