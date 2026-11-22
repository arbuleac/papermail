import Foundation

/// What a rendered conversation's invitation cards say they overlap (spec §5.14), and what that was read from: which
/// cards can say it, and over what time. The reader keeps it with the render (`RenderInputs`), so a change to the
/// calendar is checked against the cards without reading a body again, and the conversation is rendered again only when
/// a line's words change.
public struct InvitationOverlaps: Hashable, Sendable {
    /// A card that can carry the overlap line (`RenderPayloadBuilder.overlapCards`).
    public struct Card: Hashable, Sendable {
        public var message: MessageID
        /// The invitation's iCalendar UID: the calendar's copy of the invitation is never an overlap.
        public var uid: String
        /// When the invitation is, as instants: a time written without a zone is read on this Mac's clock.
        public var span: DateInterval

        public init(message: MessageID, uid: String, span: DateInterval) {
            self.message = message
            self.uid = uid
            self.span = span
        }
    }

    /// In card order.
    public var cards: [Card]
    /// Each card's line, “Overlaps 1:1 with Sam, 13:30 - 14:00”; a card that overlaps nothing has none.
    public var lines: [MessageID: String]

    public init(cards: [Card] = [], lines: [MessageID: String] = [:]) {
        self.cards = cards
        self.lines = lines
    }

    public static let none = InvitationOverlaps()

    /// The time the calendar is read over, and watched over while the conversation is on screen: every card's span
    /// joined. Nil when no card can carry a line, so a conversation without one reads no calendar at all.
    public var interval: DateInterval? {
        guard let start = cards.map(\.span.start).min(), let end = cards.map(\.span.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }
}
