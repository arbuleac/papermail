import Foundation
import SSCore

// Encodable shapes for `/me/sendMail`, draft PATCHes and attachment POSTs.

struct GraphEmailAddressPayload: Encodable, Sendable {
    var name: String?
    var address: String
}

struct GraphRecipientPayload: Encodable, Sendable {
    var emailAddress: GraphEmailAddressPayload

    init(_ address: EmailAddress) {
        emailAddress = GraphEmailAddressPayload(name: address.name, address: address.address)
    }
}

struct GraphBodyPayload: Encodable, Sendable {
    var contentType = "html"
    var content: String
}

struct GraphFileAttachmentPayload: Encodable, Sendable {
    var odataType = "#microsoft.graph.fileAttachment"
    var name: String
    var contentType: String
    var contentBytes: String
    var isInline: Bool
    var contentId: String?

    private enum CodingKeys: String, CodingKey {
        case odataType = "@odata.type"
        case name, contentType, contentBytes, isInline, contentId
    }

    init(_ attachment: OutgoingAttachment) {
        name = attachment.filename
        contentType = attachment.mimeType
        contentBytes = attachment.data.base64EncodedString()
        isInline = attachment.contentID != nil
        contentId = attachment.contentID
    }
}

struct GraphMessagePayload: Encodable, Sendable {
    var subject: String
    var body: GraphBodyPayload
    var toRecipients: [GraphRecipientPayload]
    var ccRecipients: [GraphRecipientPayload]
    var bccRecipients: [GraphRecipientPayload]
    var attachments: [GraphFileAttachmentPayload]?

    /// Graph sends one body only, so the composer's plain-text alternative is not transmitted.
    init(_ message: OutgoingMessage, includeAttachments: Bool) {
        subject = message.subject
        body = GraphBodyPayload(content: message.html)
        toRecipients = message.to.map(GraphRecipientPayload.init)
        ccRecipients = message.cc.map(GraphRecipientPayload.init)
        bccRecipients = message.bcc.map(GraphRecipientPayload.init)
        attachments = includeAttachments ? message.attachments.map(GraphFileAttachmentPayload.init) : nil
    }
}

struct GraphSendMailPayload: Encodable, Sendable {
    var message: GraphMessagePayload
    var saveToSentItems = true
}

/// Body of `POST /attachments/createUploadSession`.
struct GraphUploadSessionRequest: Encodable, Sendable {
    struct Item: Encodable, Sendable {
        var attachmentType = "file"
        var name: String
        var size: Int
        var contentType: String
        var isInline: Bool
        var contentId: String?
    }

    var AttachmentItem: Item

    init(_ attachment: OutgoingAttachment) {
        AttachmentItem = Item(
            name: attachment.filename,
            size: attachment.data.count,
            contentType: attachment.mimeType,
            isInline: attachment.contentID != nil,
            contentId: attachment.contentID
        )
    }
}

struct GraphUploadSession: Decodable, Sendable {
    var uploadUrl: String
}
