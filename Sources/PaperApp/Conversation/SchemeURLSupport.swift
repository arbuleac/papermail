import Foundation
import PaperCore
import WebKit

/// Shared pieces of the `ss-cid` and `ss-attachment` handlers: both address a message as
/// `scheme://<accountID>/<providerMessageID>/<key>` and answer with bytes or a 404.
enum SchemeURLSupport {
    struct Target: Equatable {
        let message: MessageID
        /// Content-ID for inline images, attachment id for attachments. Percent-decoded.
        let key: String
    }

    /// Provider ids are opaque and may contain slashes, so everything after the message id is the key.
    static func target(of url: URL) -> Target? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        let providerID = components[0]
        let key = components.dropFirst().joined(separator: "/")
        guard !providerID.isEmpty, !key.isEmpty else { return nil }
        return Target(message: MessageID(accountID: AccountID(host), providerID: providerID), key: key)
    }

    /// Content-IDs are compared without angle brackets, whitespace or case; providers disagree on all three.
    static func normalizedContentID(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }

    static func inlineAttachment(matching contentID: String, in attachments: [AttachmentInfo]) -> AttachmentInfo? {
        let wanted = normalizedContentID(contentID)
        if let byContentID = attachments.first(where: { $0.contentID.map(normalizedContentID) == wanted }) {
            return byContentID
        }
        return attachments.first { $0.id == contentID }
    }

    @MainActor
    static func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mimeType: String, filename: String? = nil) {
        var headers = [
            "Content-Type": mimeType.isEmpty ? "application/octet-stream" : mimeType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ]
        if let filename {
            headers["Content-Disposition"] = "inline; filename=\"" + filename.replacingOccurrences(of: "\"", with: "") + "\""
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    @MainActor
    static func respondNotFound(_ task: WKURLSchemeTask, url: URL) {
        guard let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"]) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(response)
        task.didFinish()
    }
}
