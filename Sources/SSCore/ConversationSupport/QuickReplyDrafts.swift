import Foundation

/// The quick-reply text typed under each conversation.
///
/// The box under the reader shows one conversation at a time. When the selection moves, its text is
/// parked here under the thread it was written for and comes back when that thread returns, so a draft
/// never sits under another thread's header where Cmd+Return would send it to the wrong people. Pure so
/// the rules are testable without AppKit.
public struct QuickReplyDrafts: Hashable, Sendable {
    private var byConversation: [ConversationID: String] = [:]

    public init() {}

    public var isEmpty: Bool { byConversation.isEmpty }

    /// Parks `text` under `id`; whitespace-only text forgets the draft.
    public mutating func park(_ text: String, under id: ConversationID) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    /// The selection moved: parks what the box holds under `from` and hands back what belongs under `to`.
    /// The draft for `to` leaves the store, so while a thread is shown the box is its only copy.
    public mutating func move(boxText: String, from: ConversationID?, to: ConversationID?) -> String {
        if let from { park(boxText, under: from) }
        guard let to else { return "" }
        let draft = self.draft(under: to)
        forget(to)
        return draft
    }

    /// A send was cancelled inside its undo window. True means the text goes back into the box because
    /// its own thread is shown; otherwise it is parked under that thread, never dropped into the one shown now.
    public mutating func restoreUnsent(_ text: String, under id: ConversationID, shown: ConversationID?) -> Bool {
        if shown == id { return true }
        park(text, under: id)
        return false
    }
}
