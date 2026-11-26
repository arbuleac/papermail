import Foundation

/// A composer's draft as kept on this Mac (spec §5.20: drafts are local and autosaved, so closing never asks).
/// Everything but the rich body and attachment bytes, which the app stores beside it: the body as an archived
/// attributed string (`bodyFile`), forwarded parts as files of their own (`Attachment.storedFile`), and the pictures in
/// the body as files of their own too (`Image.storedFile`): the archive keeps only each picture's place and content id.
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

    /// A picture in the body (spec §5.20, Images in the body). The archived body keeps its attachment character and
    /// content id (`ComposerInlineImage.attributeKey`); the bytes are the file `storedFile`, already in the format they
    /// are sent in, so reopening the draft reads them as they are.
    public struct Image: Codable, Hashable, Sendable {
        public var contentID: String
        public var filename: String
        public var mimeType: String
        public var sizeBytes: Int
        public var storedFile: String

        public init(contentID: String, filename: String, mimeType: String, sizeBytes: Int, storedFile: String) {
            self.contentID = contentID
            self.filename = filename
            self.mimeType = mimeType
            self.sizeBytes = sizeBytes
            self.storedFile = storedFile
        }

        /// The file a picture's bytes are kept in, named after its content id (which is ours, so unique and never
        /// reused): a picture's bytes never change, so a draft saved again need not write them again.
        public static func storedFile(for contentID: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            let safe = String(contentID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            return "image-" + safe
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
    /// The start of the body's text, so the Drafts view can list kept drafts from their records alone, without
    /// unarchiving every body. Nil in records written before it was kept.
    public var preview: String?
    /// The provider's draft (a Drafts row synced from Gmail or Outlook) this one continues: Continue Editing
    /// brings this draft back instead of starting another, and sending it discards the provider's copy.
    public var continuesDraft: MessageID?
    /// The pictures in the body, in order. Nil in records written before pictures could be pasted, and when there are none.
    public var images: [Image]?
    /// The body is the message's text as it would have been sent (a Send Later message whose kept draft was gone, rebuilt
    /// from the outbox): the user's words, the quoted original and the signature are one unmarked text there, so nothing
    /// can tell them apart. Nil in records written before it was kept, and for every draft written in a composer.
    public var bodyIsAsSent: Bool?
    /// The body was filled in by a mail link or a Service, which someone else may have written: the SHA-256, in hex, of
    /// the text it filled in (the body's typed text, without the signature), so Help me write can tell whether the body
    /// is still exactly that text and redact it as mail is. Only a digest, never a second copy of the body. Nil in
    /// records written before it was kept, and for every body the user began themselves.
    public var filledInBodyDigest: String?

    public static let bodyFile = "body.archive"
    public static let recordFile = "draft.json"

    public init(id: UUID, kind: Kind, originalMessageID: MessageID?, accountID: AccountID, to: [EmailAddress],
                cc: [EmailAddress], bcc: [EmailAddress], subject: String, attachments: [Attachment],
                quoted: QuotedReply.Rendering?, threading: ReplyThreading?, editedAt: Date, sendFailure: String? = nil,
                preview: String? = nil, continuesDraft: MessageID? = nil, images: [Image]? = nil, bodyIsAsSent: Bool? = nil,
                filledInBodyDigest: String? = nil) {
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
        self.preview = preview
        self.continuesDraft = continuesDraft
        self.images = images
        self.bodyIsAsSent = bodyIsAsSent
        self.filledInBodyDigest = filledInBodyDigest
    }

    /// How long `preview` is kept: more than a list row's snippet line can show.
    public static let previewLength = 200

    /// The preview kept for `bodyText`: whitespace runs folded to one space, cut to `previewLength`. A picture's
    /// attachment character is not words, so it is left out.
    public static func preview(of bodyText: String) -> String {
        let folded = bodyText.replacingOccurrences(of: "\u{FFFC}", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(folded.prefix(previewLength))
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
