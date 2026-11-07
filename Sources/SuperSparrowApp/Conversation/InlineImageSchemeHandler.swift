import Foundation
import SSCore
import WebKit

/// Serves `ss-cid://<account>/<message>/<contentID>` from the stored body's attachment list.
///
/// The sanitizer rewrote `cid:` references to this scheme at sync time; here the content id is resolved
/// against the stored `AttachmentInfo` and the bytes come from the client's attachment cache (which
/// fetches once when missing). Unknown ids answer 404 so the image shows as broken, never as a hang.
@MainActor
final class InlineImageSchemeHandler: NSObject, WKURLSchemeHandler {
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
        guard let attachment = SchemeURLSupport.inlineAttachment(matching: target.key, in: stored?.body.attachments ?? []) else {
            SchemeURLSupport.respondNotFound(urlSchemeTask, url: url)
            return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        let client = self.client
        inFlight[key] = Task { [weak self] in
            let data = try? await client.attachmentData(for: target.message, attachmentID: attachment.id,
                                                        expectedSize: attachment.sizeBytes, progress: nil)
            // WebKit raises if a task is touched after it was stopped, so the registry is the gate.
            guard let self, self.inFlight[key] != nil else { return }
            self.inFlight[key] = nil
            if let data {
                SchemeURLSupport.respond(urlSchemeTask, url: url, data: data, mimeType: attachment.mimeType)
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
