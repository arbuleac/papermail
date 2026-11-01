import Foundation

// Decodable shapes of the Graph resources this module reads. Every property except `id` is optional because
// `$select` and delta responses return partial objects.

struct GraphListResponse<Item: Decodable>: Decodable {
    var value: [Item]
    var nextLink: String?
    var deltaLink: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
        case deltaLink = "@odata.deltaLink"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent([Item].self, forKey: .value) ?? []
        nextLink = try container.decodeIfPresent(String.self, forKey: .nextLink)
        deltaLink = try container.decodeIfPresent(String.self, forKey: .deltaLink)
    }
}

struct GraphEmailAddress: Decodable, Sendable {
    var name: String?
    var address: String?
}

struct GraphRecipient: Decodable, Sendable {
    var emailAddress: GraphEmailAddress?
}

struct GraphFlag: Decodable, Sendable {
    var flagStatus: String?
}

struct GraphItemBody: Decodable, Sendable {
    var contentType: String?
    var content: String?
}

struct GraphInternetHeader: Decodable, Sendable {
    var name: String?
    var value: String?
}

struct GraphRemoved: Decodable, Sendable {
    var reason: String?
}

struct GraphMessage: Decodable, Sendable {
    var id: String
    var conversationId: String?
    var internetMessageId: String?
    var subject: String?
    var bodyPreview: String?
    var from: GraphRecipient?
    var toRecipients: [GraphRecipient]?
    var ccRecipients: [GraphRecipient]?
    var bccRecipients: [GraphRecipient]?
    var replyTo: [GraphRecipient]?
    var receivedDateTime: String?
    var isRead: Bool?
    var flag: GraphFlag?
    var inferenceClassification: String?
    var parentFolderId: String?
    var hasAttachments: Bool?
    var changeKey: String?
    var isDraft: Bool?
    var body: GraphItemBody?
    var uniqueBody: GraphItemBody?
    var internetMessageHeaders: [GraphInternetHeader]?
    /// Present on delta items that left the folder (deleted or moved).
    var removed: GraphRemoved?

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, internetMessageId, subject, bodyPreview, from
        case toRecipients, ccRecipients, bccRecipients, replyTo, receivedDateTime, isRead, flag
        case inferenceClassification, parentFolderId, hasAttachments, changeKey, isDraft
        case body, uniqueBody, internetMessageHeaders
        case removed = "@removed"
    }
}

struct GraphFolder: Decodable, Sendable {
    var id: String
    var displayName: String?
    var childFolderCount: Int?
}

struct GraphAttachment: Decodable, Sendable {
    var id: String
    var name: String?
    var contentType: String?
    var size: Int?
    var isInline: Bool?
    var contentId: String?
    var contentBytes: String?
    var odataType: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, contentType, size, isInline, contentId, contentBytes
        case odataType = "@odata.type"
    }
}

struct GraphUser: Decodable, Sendable {
    var displayName: String?
    var mail: String?
    var userPrincipalName: String?
}

struct GraphErrorEnvelope: Decodable, Sendable {
    struct Body: Decodable, Sendable {
        var code: String?
        var message: String?
    }
    var error: Body?
}
