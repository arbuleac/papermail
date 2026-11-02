import Foundation

/// A composer's draft as kept on this Mac (spec §5.20: drafts are local and autosaved, so closing never asks).
/// Everything but the rich body and attachment bytes, which the app stores beside it: the body as an archived
/// attributed string (`bodyFile`), forwarded parts as files of their own (`Attachment.storedFile`).
public struct ComposeDraftRecord: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case new
        case reply
        case replyAll
        case forward
    }

    public struct Attachment: Codable, Hashable, Sendable {
        public var id: UUID
        public var filename: String
        public var mimeType: String
        public var sizeBytes: Int
        public var contentID: String?
        /// A file the user attached, still read from where it lives.
        public var fileURL: URL?
        /// Bytes that came with a forward, copied next to the record under this name.
        public var storedFile: String?

        public init(id: UUID, filename: String, mimeType: String, sizeBytes: Int, contentID: String?, fileURL: URL?,
                    storedFile: String?) {
            self.id = id
            self.filename = filename
            self.mimeType = mimeType
            self.sizeBytes = sizeBytes
            self.contentID = contentID
            self.fileURL = fileURL
            self.storedFile = storedFile
        }
    }

    public var id: UUID
    public var kind: Kind
    /// The message replied to or forwarded.
    public var originalMessageID: MessageID?
    public var accountID: AccountID
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var attachments: [Attachment]
    public var quoted: QuotedReply.Rendering?
    public var threading: ReplyThreading?
    public var editedAt: Date
    /// Set when the send failed after the undo window, with the provider's reason; the composer opens with
    /// the danger banner then.
    public var sendFailure: String?

    public static let bodyFile = "body.archive"
    public static let recordFile = "draft.json"

    public init(id: UUID, kind: Kind, originalMessageID: MessageID?, accountID: AccountID, to: [EmailAddress],
                cc: [EmailAddress], bcc: [EmailAddress], subject: String, attachments: [Attachment],
                quoted: QuotedReply.Rendering?, threading: ReplyThreading?, editedAt: Date, sendFailure: String? = nil) {
        self.id = id
        self.kind = kind
        self.originalMessageID = originalMessageID
        self.accountID = accountID
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.attachments = attachments
        self.quoted = quoted
        self.threading = threading
        self.editedAt = editedAt
        self.sendFailure = sendFailure
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ComposeDraftRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ComposeDraftRecord.self, from: data)
    }
}
