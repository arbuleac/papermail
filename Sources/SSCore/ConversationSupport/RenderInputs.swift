import Foundation

/// What a rendered conversation depends on, minus the body bytes.
///
/// A slot keeps the inputs it rendered; comparing them with fresh ones decides whether it is stale from
/// metadata alone, so a store change never inflates a stored body just to learn that nothing changed.
/// Only the fields `RenderPayloadBuilder` reads are here: sync bookkeeping such as `providerVersion`
/// changes on every poll without moving a pixel.
public struct RenderInputs: Hashable, Sendable {
    public struct Message: Hashable, Sendable {
        public var id: MessageID
        public var from: EmailAddress?
        public var to: [EmailAddress]
        public var cc: [EmailAddress]
        public var subject: String
        public var snippet: String
        public var date: Date
        public var isRead: Bool
        public var isStarred: Bool
        /// False when the card was rendered with the snippet fallback.
        public var hasBody: Bool

        public init(_ metadata: MessageMetadata, hasBody: Bool) {
            id = metadata.id
            from = metadata.from
            to = metadata.to
            cc = metadata.cc
            subject = metadata.subject
            snippet = metadata.snippet
            date = metadata.date
            isRead = metadata.isRead
            isStarred = metadata.isStarred
            self.hasBody = hasBody
        }
    }

    /// In card order, the one `RenderPayloadBuilder.visibleMessages` decides.
    public private(set) var messages: [Message]
    private var bodyIDs: Set<MessageID>

    public static let empty = RenderInputs(messages: []) { _ in false }

    /// - Parameter hasBody: asked once per visible message, in order.
    public init(messages: [MessageMetadata], hasBody: (MessageID) -> Bool) {
        var entries: [Message] = []
        var bodyIDs: Set<MessageID> = []
        for metadata in RenderPayloadBuilder.visibleMessages(messages) {
            let present = hasBody(metadata.id)
            entries.append(Message(metadata, hasBody: present))
            if present { bodyIDs.insert(metadata.id) }
        }
        self.messages = entries
        self.bodyIDs = bodyIDs
    }

    public func hasBody(_ id: MessageID) -> Bool {
        bodyIDs.contains(id)
    }

    /// Inputs for a refresh of the slot that rendered `self`. Bodies are written once at sync time and
    /// stay for the life of their message, so one this slot already rendered is taken as read; `probe`
    /// runs only for messages that had none, which keeps the staleness check away from body bytes.
    public func refreshed(with messages: [MessageMetadata], probe: (MessageID) -> Bool) -> RenderInputs {
        RenderInputs(messages: messages) { id in bodyIDs.contains(id) || probe(id) }
    }

    /// The patches that bring a slot rendered from `self` up to `fresh` when only read or star flags
    /// moved; nil when anything else changed and the slot needs a payload.
    public func flagPatches(to fresh: RenderInputs) -> [RenderPayload.FlagPatch]? {
        guard messages.count == fresh.messages.count, bodyIDs == fresh.bodyIDs else { return nil }
        var patches: [RenderPayload.FlagPatch] = []
        for (old, new) in zip(messages, fresh.messages) {
            var comparable = new
            comparable.isRead = old.isRead
            comparable.isStarred = old.isStarred
            guard comparable == old else { return nil }
            if old.isRead != new.isRead || old.isStarred != new.isStarred {
                patches.append(RenderPayload.FlagPatch(id: RenderPayload.messageKey(for: new.id), isUnread: !new.isRead, isStarred: new.isStarred))
            }
        }
        return patches
    }
}
