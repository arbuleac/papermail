import Foundation
import SSCore

extension GraphProvider {
    /// New messages go through `/me/sendMail` in one call when they fit its request limit, otherwise through
    /// a draft. Replies are created server side from the original so Outlook threads them, then patched with
    /// the composer's content and sent. Forwards are sent fresh: createReply would make them answers to the
    /// original, and createForward would attach the original's files a second time beside the ones the
    /// composer already carries.
    public func send(_ message: OutgoingMessage) async throws -> SendReceipt {
        if let original = message.inReplyTo, original.accountID == accountID, !message.isForward,
           let receipt = try await sendReply(message, to: original.providerID) {
            return receipt
        }
        return try await sendNew(message)
    }

    private func sendNew(_ message: OutgoingMessage) async throws -> SendReceipt {
        guard fitsSendMail(message) else { return try await sendThroughDraft(message) }
        let payload = GraphSendMailPayload(message: GraphMessagePayload(message, includeAttachments: true))
        let request = GraphRequest(method: .post, url: try GraphURL.make("/me/sendMail"), body: try GraphJSON.encode(payload))
        _ = try await client.send(request)
        // sendMail returns 202 with no body; the sent copy arrives through the next poll.
        return SendReceipt(providerMessageID: nil, providerConversationID: nil)
    }

    /// sendMail carries every attachment base64-encoded in one JSON body, which Graph caps at about 4 MB.
    func fitsSendMail(_ message: OutgoingMessage) -> Bool {
        let total = message.attachments.reduce(0) { $0 + $1.data.count }
        return total <= sendLimits.sendMailAttachmentBytes
            && message.attachments.allSatisfy { $0.data.count <= sendLimits.inlineAttachmentBytes }
    }

    /// Too large for sendMail: a draft is created, filled attachment by attachment and sent.
    private func sendThroughDraft(_ message: OutgoingMessage) async throws -> SendReceipt {
        let draft = try await client.json(GraphMessage.self, for: GraphRequest(
            method: .post,
            url: try GraphURL.make("/me/messages"),
            body: try GraphJSON.encode(GraphMessagePayload(message, includeAttachments: false))
        ))
        try await completeDraft(draft.id) {
            try await self.attach(message.attachments, to: draft.id)
        }
        return SendReceipt(providerMessageID: draft.id, providerConversationID: draft.conversationId)
    }

    /// Returns nil when the original no longer exists, in which case the message is sent fresh.
    private func sendReply(_ message: OutgoingMessage, to originalID: String) async throws -> SendReceipt? {
        let original: GraphMessage
        do {
            let url = try GraphURL.make("/me/messages/\(originalID)", query: [("$select", "id,conversationId,from,toRecipients,ccRecipients")])
            original = try await client.json(GraphMessage.self, for: GraphRequest(method: .get, url: url))
        } catch ProviderError.notFound {
            return nil
        }

        let action = Self.coversOriginalCC(message, original: original) ? "createReplyAll" : "createReply"
        let draft = try await client.json(GraphMessage.self, for: GraphRequest(
            method: .post,
            url: try GraphURL.make("/me/messages/\(originalID)/\(action)"),
            body: Data("{}".utf8)
        ))

        try await completeDraft(draft.id) {
            let patch = GraphRequest(
                method: .patch,
                url: try GraphURL.make("/me/messages/\(draft.id)"),
                body: try GraphJSON.encode(GraphMessagePayload(message, includeAttachments: false))
            )
            _ = try await self.client.send(patch)
            try await self.attach(message.attachments, to: draft.id)
        }
        return SendReceipt(providerMessageID: draft.id, providerConversationID: draft.conversationId ?? original.conversationId)
    }

    /// Runs `fill` and sends the draft. When anything fails before the send, the draft is deleted: the
    /// failure goes back to the outbox, which retries from scratch, and each attempt would otherwise leave
    /// one more half-built copy in the user's Drafts.
    private func completeDraft(_ draftID: String, fill: () async throws -> Void) async throws {
        do {
            try await fill()
            _ = try await client.send(GraphRequest(method: .post, url: try GraphURL.make("/me/messages/\(draftID)/send")))
        } catch {
            if let url = try? GraphURL.make("/me/messages/\(draftID)") {
                _ = try? await client.send(GraphRequest(method: .delete, url: url))
            }
            throw error
        }
    }

    /// Attachments are a navigation property, so they cannot ride along on a draft's create or PATCH. Files
    /// under the single-request limit are posted whole; larger ones go through an upload session.
    private func attach(_ attachments: [OutgoingAttachment], to draftID: String) async throws {
        for attachment in attachments {
            if attachment.data.count <= sendLimits.inlineAttachmentBytes {
                let request = GraphRequest(
                    method: .post,
                    url: try GraphURL.make("/me/messages/\(draftID)/attachments"),
                    body: try GraphJSON.encode(GraphFileAttachmentPayload(attachment))
                )
                _ = try await client.send(request)
            } else {
                try await upload(attachment, to: draftID)
            }
        }
    }

    private func upload(_ attachment: OutgoingAttachment, to draftID: String) async throws {
        let session = try await client.json(GraphUploadSession.self, for: GraphRequest(
            method: .post,
            url: try GraphURL.make("/me/messages/\(draftID)/attachments/createUploadSession"),
            body: try GraphJSON.encode(GraphUploadSessionRequest(attachment))
        ))
        let uploadURL = try GraphURL.absolute(session.uploadUrl)
        let data = attachment.data
        let total = data.count
        let chunk = Swift.max(1, sendLimits.uploadChunkBytes)
        var start = 0
        while start < total {
            let end = Swift.min(start + chunk, total)
            var request = GraphRequest(method: .put, url: uploadURL, body: data.subdata(in: start..<end))
            request.authenticated = false
            request.headers = [
                "Content-Type": "application/octet-stream",
                "Content-Range": "bytes \(start)-\(end - 1)/\(total)",
            ]
            _ = try await client.send(request)
            start = end
        }
    }

    /// Reply-all when the composer kept everyone the original had on cc; a plain reply otherwise.
    static func coversOriginalCC(_ message: OutgoingMessage, original: GraphMessage) -> Bool {
        let originalCC = GraphMessageMapper.addresses(original.ccRecipients).map { $0.address.lowercased() }
        guard !originalCC.isEmpty else { return false }
        let outgoing = Set((message.to + message.cc).map { $0.address.lowercased() })
        return originalCC.allSatisfy(outgoing.contains)
    }
}
