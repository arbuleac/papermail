import Foundation

/// Reader mode's part in one render (spec §5.59), handed to `RenderPayloadBuilder` only while reader mode is on: every
/// message with words shows its text version (`ReaderText`) in place of its HTML, except the ones the user asked to see as
/// sent.
public struct ReaderModeRender: Sendable {
    /// Messages shown as sent for the rest of the session (Show original, window-local): their HTML renders as it would
    /// without reader mode, and their line offers Show text.
    public var originals: Set<MessageID>
    /// Bodies Keep mail on this Mac evicted, as the store kept them (`MailStoring.keptBody(for:)`): no source and no HTML,
    /// but their plain text, attachment list and design facts. Reader mode needs no HTML, so their text shows at once
    /// instead of waiting for the download that brings the rest back.
    public var kept: [MessageID: StoredBody]
    /// Text already set for the reader that renders (`ReaderTextCache`); nil sets every text afresh.
    public var cache: ReaderTextCache?

    public init(originals: Set<MessageID> = [], kept: [MessageID: StoredBody] = [:], cache: ReaderTextCache? = nil) {
        self.originals = originals
        self.kept = kept
        self.cache = cache
    }
}
