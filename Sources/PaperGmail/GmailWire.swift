import Foundation

// Decoded shapes of the Gmail REST API. Only the fields the provider reads are declared so that new
// fields Google adds never break decoding, and everything is optional except what Gmail guarantees.

struct GmailProfile: Decodable, Sendable {
    var emailAddress: String
    var historyId: String
    /// Every message in the mailbox, spam and trash included: an upper estimate of what the bootstrap lists.
    var messagesTotal: Int?
}

struct GmailMessageRef: Decodable, Sendable {
    var id: String
    var threadId: String?
    var labelIds: [String]?
}

struct GmailMessageList: Decodable, Sendable {
    var messages: [GmailMessageRef]?
    var nextPageToken: String?
}

struct GmailHeader: Decodable, Sendable {
    var name: String
    var value: String
}

struct GmailBody: Decodable, Sendable {
    var attachmentId: String?
    var size: Int?
    var data: String?
}

struct GmailPart: Decodable, Sendable {
    var partId: String?
    var mimeType: String?
    var filename: String?
    var headers: [GmailHeader]?
    var body: GmailBody?
    var parts: [GmailPart]?

    /// First value of a header, matched case-insensitively as RFC 5322 requires.
    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// True when any part below this one carries a filename, which is how Gmail marks real attachments.
    var containsNamedPart: Bool {
        if let filename, !filename.isEmpty { return true }
        return parts?.contains { $0.containsNamedPart } ?? false
    }
}

struct GmailMessage: Decodable, Sendable {
    var id: String
    var threadId: String
    var labelIds: [String]?
    var snippet: String?
    var historyId: String?
    var internalDate: String?
    var payload: GmailPart?
    var sizeEstimate: Int?
}

struct GmailHistoryEntry: Decodable, Sendable {
    var message: GmailMessageRef
    var labelIds: [String]?
}

struct GmailHistoryRecord: Decodable, Sendable {
    var id: String
    var messages: [GmailMessageRef]?
    var messagesAdded: [GmailHistoryEntry]?
    var messagesDeleted: [GmailHistoryEntry]?
    var labelsAdded: [GmailHistoryEntry]?
    var labelsRemoved: [GmailHistoryEntry]?
}

struct GmailHistoryList: Decodable, Sendable {
    var history: [GmailHistoryRecord]?
    var nextPageToken: String?
    var historyId: String?
}

struct GmailAttachment: Decodable, Sendable {
    var attachmentId: String?
    var size: Int?
    var data: String?
}

struct GmailSendResponse: Decodable, Sendable {
    var id: String
    var threadId: String?
}

struct GmailErrorEnvelope: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        var reason: String?
        var message: String?
    }
    struct Body: Decodable, Sendable {
        var code: Int?
        var message: String?
        var status: String?
        var errors: [Detail]?
    }
    var error: Body
}

struct GmailBatchModifyRequest: Encodable, Sendable {
    var ids: [String]
    var addLabelIds: [String]?
    var removeLabelIds: [String]?
}

struct GmailSendRequest: Encodable, Sendable {
    var raw: String
    var threadId: String?
}

/// Metadata part of a multipart upload to `messages.send`; the message itself travels as the media part.
struct GmailUploadSendMetadata: Encodable, Sendable {
    var threadId: String?
}
