import Foundation

/// The quick-reply text typed under each conversation.
///
/// The box under the reader shows one conversation at a time. When the selection moves, its text is
/// parked here under the thread it was written for and comes back when that thread returns, so a draft
/// never sits under another thread's header where Cmd+Return would send it to the wrong people. Pure so
/// the rules are testable without AppKit.
///
/// The main window's reader and every reader window share one set (spec §5.49), so text typed in a window
/// that closes waits here for the next box to show its thread. Two boxes can show the same thread at once;
/// a box letting go of a thread (`leave`) therefore never drops what the other parked meanwhile.
public struct QuickReplyDrafts: Hashable, Sendable {
    private var byConversation: [ConversationID: String] = [:]

    public init() {}

    public var isEmpty: Bool { byConversation.isEmpty }

    /// Parks `text` under `id`; whitespace-only text forgets the draft.
    public mutating func park(_ text: String, under id: ConversationID) {
        if Self.isBlank(text) {
            byConversation[id] = nil
        } else {
            byConversation[id] = text
        }
    }

    /// What the box should hold for `id`: the parked draft, or nothing.
    public func draft(under id: ConversationID) -> String {
        byConversation[id] ?? ""
    }

    public mutating func forget(_ id: ConversationID) {
        byConversation[id] = nil
    }

    /// A box lets go of `id` holding `text`. While it showed `id` the box was the thread's only copy, unless
    /// another box showing the same thread parked text under it meanwhile (a reader window closing, §5.49):
    /// blank text then leaves that text alone, and other text is kept below it, so neither box's words are lost.
    public mutating func leave(_ text: String, under id: ConversationID) {
        guard !Self.isBlank(text) else { return }
        let parked = draft(under: id)
        byConversation[id] = Self.isBlank(parked) || parked == text ? text : parked + "\n\n" + text
    }

    /// The selection moved: parks what the box holds under `from` and hands back what belongs under `to`.
    /// The draft for `to` leaves the store, so while a thread is shown the box is its only copy.
    public mutating func move(boxText: String, from: ConversationID?, to: ConversationID?) -> String {
        if let from { leave(boxText, under: from) }
        guard let to else { return "" }
        let draft = self.draft(under: to)
        forget(to)
        return draft
    }

    /// A send was cancelled inside its undo window. True means the text goes back into the box because
    /// its own thread is shown; otherwise it is parked under that thread, never dropped into the one shown now,
    /// with anything parked there since kept below it, as the box keeps what was typed since below it.
    public mutating func restoreUnsent(_ text: String, under id: ConversationID, shown: ConversationID?) -> Bool {
        if shown == id { return true }
        let parked = draft(under: id)
        if Self.isBlank(parked) || parked == text {
            park(text, under: id)
        } else if !Self.isBlank(text) {
            byConversation[id] = text + "\n\n" + parked
        }
        return false
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
