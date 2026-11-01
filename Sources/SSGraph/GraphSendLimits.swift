import Foundation

/// Request-size limits of Graph's send paths, injectable so tests can exercise the large-file path with
/// a few bytes.
struct GraphSendLimits: Sendable {
    /// Largest file a single `POST /attachments` accepts; anything bigger needs an upload session.
    var inlineAttachmentBytes: Int
    /// Raw bytes of attachments that still fit one `/me/sendMail` JSON body (4 MB cap, base64 adds a third).
    var sendMailAttachmentBytes: Int
    /// Upload-session chunk size; Graph wants multiples of 320 KiB and at most 60 MiB per PUT.
    var uploadChunkBytes: Int

    static let graph = GraphSendLimits(
        inlineAttachmentBytes: 3 * 1000 * 1000,
        sendMailAttachmentBytes: 2_900_000,
        uploadChunkBytes: 10 * 320 * 1024
    )
}
