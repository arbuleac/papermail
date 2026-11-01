import Foundation
import SSCore

extension GraphProvider {
    /// New messages go through `/me/sendMail` in one call. Replies are created server side from the original so
    /// Outlook threads them, then patched with the composer's content and sent.
    public func send(_ message: OutgoingMessage) async throws -> SendReceipt {
        if let original = message.inReplyTo, original.accountID == accountID,
           let receipt = try await sendReply(message, to: original.providerID) {
            return receipt
        }
        return try await sendNew(message)
    }

    private func sendNew(_ message: OutgoingMessage) async throws -> SendReceipt {
        let payload = GraphSendMailPayload(message: GraphMessagePayload(message, includeAttachments: true))
        let request = GraphRequest(method: .post, url: try GraphURL.make("/me/sendMail"), body: try GraphJSON.encode(payload))
        _ = try await client.send(request)
        // sendMail returns 202 with no body; the sent copy arrives through the next poll.
        return SendReceipt(providerMessageID: nil, providerConversationID: nil)
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

        let patch = GraphRequest(
            method: .patch,
            url: try GraphURL.make("/me/messages/\(draft.id)"),
            body: try GraphJSON.encode(GraphMessagePayload(message, includeAttachments: false))
        )
        _ = try await client.send(patch)

        // Attachments are a navigation property, so they cannot ride along on the PATCH.
        for attachment in message.attachments {
            let request = GraphRequest(
                method: .post,
                url: try GraphURL.make("/me/messages/\(draft.id)/attachments"),
                body: try GraphJSON.encode(GraphFileAttachmentPayload(attachment))
            )
            _ = try await client.send(request)
        }

        _ = try await client.send(GraphRequest(method: .post, url: try GraphURL.make("/me/messages/\(draft.id)/send")))
        return SendReceipt(providerMessageID: draft.id, providerConversationID: draft.conversationId ?? original.conversationId)
    }

    /// Reply-all when the composer kept everyone the original had on cc; a plain reply otherwise.
    static func coversOriginalCC(_ message: OutgoingMessage, original: GraphMessage) -> Bool {
        let originalCC = GraphMessageMapper.addresses(original.ccRecipients).map { $0.address.lowercased() }
        guard !originalCC.isEmpty else { return false }
        let outgoing = Set((message.to + message.cc).map { $0.address.lowercased() })
        return originalCC.allSatisfy(outgoing.contains)
    }
}
